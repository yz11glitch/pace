from __future__ import annotations

import re
import unicodedata
import uuid
from dataclasses import dataclass

from noted.db import Database


@dataclass(frozen=True)
class MerchantMatch:
    merchant_id: str
    display_name: str
    category: str | None
    subcategory: str | None
    confidence: float
    method: str
    alias_id: int


def merchant_key(value: str) -> str:
    value = unicodedata.normalize("NFKD", value.casefold().replace("’", "'"))
    value = "".join(character for character in value if not unicodedata.combining(character))
    value = re.sub(r"['&]", " ", value)
    value = re.sub(r"\b(?:sdn\s*bhd|s\s*/\s*b)\b", " ", value)
    return re.sub(r"[^a-z0-9]+", " ", value).strip()


def resolve_merchant_alias(name: str | None, database: Database, *, context: str = "") -> MerchantMatch | None:
    """Resolve an extracted merchant by its entire normalized alias, never by similarity."""
    key = merchant_key(name or "")
    if not key:
        return None
    row = database.merchant_alias(key)
    if row is None:
        return None
    return _with_context(row, merchant_key(context), database, 1.0, "exact_alias")


def learn_merchant_correction(connection, *, source_name: str | None, corrected_name: str,
                              category: str | None, learn_alias: bool,
                              learn_category: bool, record: dict | None = None) -> str:
    """Persist an explicit edit inside the caller's transaction and return its merchant ID.

    When ``record`` is given it receives exactly what was learned and what it
    replaced, so undo can revert this correction's learning (decision O5).
    """
    corrected_key = merchant_key(corrected_name)
    if not corrected_key:
        raise ValueError("corrected merchant must have a normalized name")
    row = connection.execute(
        "SELECT id FROM merchants WHERE canonical_key = ?", (corrected_key,),
    ).fetchone()
    if row is None:
        row = connection.execute(
            """SELECT m.id FROM merchants m
               JOIN merchant_aliases a ON a.merchant_id = m.id
               WHERE a.alias_key = ? AND a.source IN ('user', 'seed')""",
            (corrected_key,),
        ).fetchone()
    if row is None:
        merchant_id = str(uuid.uuid4())
        connection.execute(
            """INSERT INTO merchants (id, canonical_key, display_name, category, is_user_taught)
               VALUES (?, ?, ?, ?, 1)""",
            (merchant_id, corrected_key, corrected_name.strip(), category if learn_category else ""),
        )
        merchant_before = None
    else:
        merchant_id = row["id"]
        merchant_before = dict(connection.execute(
            "SELECT category, subcategory, is_user_taught FROM merchants WHERE id = ?", (merchant_id,),
        ).fetchone())
        if learn_category:
            connection.execute(
                """UPDATE merchants SET category = ?,
                   subcategory = CASE WHEN category = ? THEN subcategory ELSE NULL END,
                   is_user_taught = 1 WHERE id = ?""",
                (category, category, merchant_id),
            )
        elif learn_alias:
            connection.execute("UPDATE merchants SET is_user_taught = 1 WHERE id = ?", (merchant_id,))

    keys = {corrected_key}
    if learn_alias and source_name:
        source_key = merchant_key(source_name)
        if source_key:
            keys.add(source_key)
    aliases = []
    for key in sorted(keys):
        previous = connection.execute(
            "SELECT merchant_id, source FROM merchant_aliases WHERE alias_key = ?", (key,),
        ).fetchone()
        connection.execute(
            """INSERT INTO merchant_aliases (merchant_id, alias_key, source)
               VALUES (?, ?, 'user')
               ON CONFLICT(alias_key) DO UPDATE SET
                   merchant_id = excluded.merchant_id, source = 'user'""",
            (merchant_id, key),
        )
        aliases.append({"alias_key": key, "before": dict(previous) if previous else None})
    if record is not None:
        merchant_after = dict(connection.execute(
            "SELECT category, subcategory, is_user_taught FROM merchants WHERE id = ?", (merchant_id,),
        ).fetchone())
        record.update({
            "merchant_id": merchant_id, "merchant_created": merchant_before is None,
            "merchant_before": merchant_before, "merchant_after": merchant_after,
            "aliases": aliases,
        })
    return merchant_id


def revert_merchant_learning(connection, record: dict, *, reinforced_aliases: set[str],
                             merchant_reinforced: bool) -> None:
    """Undo one correction's learning, leaving anything a later correction owns.

    A mapping is reverted only while it is still exactly what this correction
    set and no later, still-active correction taught the same mapping.
    """
    merchant_id = record["merchant_id"]
    for alias in record["aliases"]:
        key = alias["alias_key"]
        current = connection.execute(
            "SELECT merchant_id, source FROM merchant_aliases WHERE alias_key = ?", (key,),
        ).fetchone()
        if key in reinforced_aliases or current is None:
            continue
        if (current["merchant_id"], current["source"]) != (merchant_id, "user"):
            continue
        before = alias["before"]
        if before is None:
            connection.execute("DELETE FROM merchant_aliases WHERE alias_key = ?", (key,))
        else:
            connection.execute(
                "UPDATE merchant_aliases SET merchant_id = ?, source = ? WHERE alias_key = ?",
                (before["merchant_id"], before["source"], key),
            )
    if merchant_reinforced:
        return
    current = connection.execute(
        "SELECT category, subcategory, is_user_taught FROM merchants WHERE id = ?", (merchant_id,),
    ).fetchone()
    if current is None or dict(current) != record["merchant_after"]:
        return
    if record["merchant_created"]:
        in_use = connection.execute(
            """SELECT (SELECT count(*) FROM transactions WHERE merchant_id = ?)
                    + (SELECT count(*) FROM merchant_aliases WHERE merchant_id = ?)""",
            (merchant_id, merchant_id),
        ).fetchone()[0]
        if not in_use:
            connection.execute("DELETE FROM merchant_context_rules WHERE merchant_id = ?", (merchant_id,))
            connection.execute("DELETE FROM merchants WHERE id = ?", (merchant_id,))
        return
    before = record["merchant_before"]
    connection.execute(
        "UPDATE merchants SET category = ?, subcategory = ?, is_user_taught = ? WHERE id = ?",
        (before["category"], before["subcategory"], before["is_user_taught"], merchant_id),
    )


def _contains_phrase(text: str, phrase: str) -> bool:
    return bool(re.search(rf"(?:^|\s){re.escape(phrase)}(?:$|\s)", text))


def resolve_merchant(transcript: str, database: Database) -> MerchantMatch | None:
    normalized = merchant_key(transcript)
    rows = database.merchant_rows()
    exact = [row for row in rows if row["source"] in ("user", "seed")
             and _contains_phrase(normalized, row["alias_key"])]
    if exact:
        row = max(exact, key=lambda candidate: len(candidate["alias_key"]))
        return _with_context(row, normalized, database, 1.0, "exact_alias")
    return None


def _with_context(row, normalized: str, database: Database, confidence: float, method: str) -> MerchantMatch:
    category = row["category"] or None
    subcategory = row["subcategory"]
    for rule in database.context_rules(row["merchant_id"]):
        if _contains_phrase(normalized, rule["keyword"]):
            category = rule["category"]
            subcategory = rule["subcategory"]
            method = f"context:{rule['keyword']}"
            break
    return MerchantMatch(
        merchant_id=row["id"], display_name=row["display_name"], category=category,
        subcategory=subcategory, confidence=confidence, method=method, alias_id=row["alias_id"],
    )
