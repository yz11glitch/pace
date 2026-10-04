"""Deterministic amount normalizer with an opt-in whole-RM rule for clear flows.

This module does not look at benchmark truth. It returns the amount chosen by the
Revision 2 ladder, or the two choices that must reach confirmation rung 5.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import asdict, dataclass
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Any


ONES = {
    "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
    "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19,
}
TENS = {
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}
NUMBER_WORDS = set(ONES) | set(TENS) | {"and", "hundred", "thousand", "point"}
MINOR_WORDS = {"sen", "cent", "cents"}
CURRENCY_WORDS = {"ringgit", "dollar", "dollars"} | MINOR_WORDS

# A minor-unit component that follows a whole-ringgit amount: "¢50", "50¢",
# "50 sen", "fifty cents", optionally joined by "and".
_NUMBER_WORD = "(?:" + "|".join(sorted(NUMBER_WORDS - {"point", "and"}, key=len, reverse=True)) + ")"
_MINOR_SUFFIX = re.compile(
    r"\s+(?:and\s+)?(?:([0-9]+)\s*(?:sen|cents?)\b|¢\s*([0-9]+)\b|([0-9]+)\s*¢"
    rf"|((?:{_NUMBER_WORD}\s+)*{_NUMBER_WORD})\s+(?:sen|cents?)\b)"
)
_MINOR_ONLY = re.compile(r"(?<![\w.])([0-9]+)\s*(?:sen|cents?)\b|¢\s*([0-9]+)\b|(?<![\w.])([0-9]+)\s*¢")
_OUT_OF_RANGE = object()


@dataclass(frozen=True)
class AmountResolution:
    amount_minor: int | None
    currency: str
    provisional_tier: str
    rung: int | None
    surface_form: str
    surface_class: str
    alternatives_minor: tuple[int, ...] = ()
    reason: str = ""

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["alternatives_minor"] = list(self.alternatives_minor)
        return value


def canonical_text(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    text = re.sub(r"(?<=\w)-(?=\w)", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _minor(value: Decimal) -> int:
    return int((value * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def _parse_cardinal(tokens: list[str]) -> int | None:
    if not tokens or any(token not in NUMBER_WORDS - {"point"} for token in tokens):
        return None
    current = total = 0
    saw_number = False
    for token in tokens:
        if token == "and":
            continue
        saw_number = True
        if token in ONES:
            current += ONES[token]
        elif token in TENS:
            current += TENS[token]
        elif token == "hundred":
            current = max(1, current) * 100
        elif token == "thousand":
            total += max(1, current) * 1000
            current = 0
    return total + current if saw_number else None


def _two_part(tokens: list[str]) -> tuple[int, int] | None:
    for split in range(1, len(tokens)):
        left = _parse_cardinal(tokens[:split])
        right = _parse_cardinal(tokens[split:])
        if left is not None and 0 <= left <= 99 and right is not None and 0 <= right <= 99:
            if tokens[split] in TENS and right >= 10:
                return left, right
    return None


def _minor_value(digits: str | None, words: str | None) -> int | None:
    if digits is not None:
        return int(digits)
    return _parse_cardinal(words.split()) if words else None


def _minor_suffix(normalized: str, end: int) -> int | object | None:
    """Return the sen component directly after ``end``; ``_OUT_OF_RANGE`` if it is not 0-99."""
    match = _MINOR_SUFFIX.match(normalized, end)
    if not match:
        return None
    value = _minor_value(match.group(1) or match.group(2) or match.group(3), match.group(4))
    return value if value is not None and 0 <= value <= 99 else _OUT_OF_RANGE


def _out_of_range(text: str, currency: str) -> AmountResolution:
    return AmountResolution(None, currency, "C", None, text, "other",
                            reason="minor-unit component outside 0-99 requires confirmation")


def _merchant_prior(text: str, priors: dict[str, Any] | None) -> dict[str, Any] | None:
    normalized = re.sub(r"[^\w\s]", "", canonical_text(text))
    for merchant in (priors or {}).get("merchants", []):
        aliases = [merchant.get("name", ""), *(merchant.get("aliases") or [])]
        if any(re.sub(r"[^\w\s]", "", canonical_text(alias)) in normalized for alias in aliases if alias):
            if int(merchant.get("amount_count", 0)) >= 5:
                return merchant
    return None


def _choose_with_prior(integer_minor: int, decimal_minor: int, prior: dict[str, Any] | None) -> int | None:
    if not prior:
        return None
    low = int(prior["amount_min_minor"])
    high = int(prior["amount_max_minor"])
    median = int(prior.get("amount_median_minor", (low + high) // 2))
    candidates = [integer_minor, decimal_minor]
    in_range = [value for value in candidates if low <= value <= high]
    if len(in_range) == 1:
        return in_range[0]
    if len(in_range) == 2:
        return min(in_range, key=lambda value: abs(value - median))
    return None


def _context_choice(text: str, integer_minor: int, decimal_minor: int, priors: dict[str, Any] | None) -> tuple[int | None, int | None, str]:
    priors = priors or {}
    chosen = _choose_with_prior(integer_minor, decimal_minor, _merchant_prior(text, priors))
    if chosen is not None:
        return chosen, 2, "merchant magnitude prior"
    global_prior = priors.get("global") or {}
    if int(global_prior.get("amount_count", 0)) >= 50:
        p99 = int(global_prior["amount_p99_minor"])
        below = [value for value in (integer_minor, decimal_minor) if value <= p99]
        above = [value for value in (integer_minor, decimal_minor) if value > p99]
        if len(below) == 1 and len(above) == 1:
            return below[0], 3, "global personal p99 prior"
    normalized = canonical_text(text)
    for category in priors.get("categories", []):
        if any(re.search(rf"\b{re.escape(canonical_text(keyword))}\b", normalized) for keyword in category.get("keywords", [])):
            chosen = _choose_with_prior(integer_minor, decimal_minor, {
                "amount_min_minor": category.get("amount_min_minor", 0),
                "amount_max_minor": category["amount_max_minor"],
                "amount_median_minor": category.get("amount_median_minor", category["amount_max_minor"] // 2),
            })
            if chosen is not None:
                return chosen, 4, f"category prior: {category.get('name', 'unnamed')}"
    return None, None, ""


def recover_amount(text: str, priors: dict[str, Any] | None = None, *,
                   whole_bare: bool = False) -> AmountResolution:
    normalized = canonical_text(text)
    currency = "MYR" if re.search(r"\brm\b|\bringgit\b|\bsen\b", normalized) else "MYR"

    # An extracted amount expression with two or more monetary alternatives is
    # not one value. A qualifier such as "20 or so" still has just one value.
    parts = re.split(r"\b(?:or|versus)\b", normalized)
    if len(parts) > 1 and sum(
        recover_amount(part, priors, whole_bare=whole_bare).amount_minor is not None
        for part in parts
    ) >= 2:
        return AmountResolution(None, currency, "C", None, text, "other",
                                reason="multiple possible amounts require confirmation")

    match = re.search(r"\b([0-9]{1,3}(?:,[0-9]{3})+)\b", normalized)
    if match:
        value = Decimal(match.group(1).replace(",", ""))
        return AmountResolution(_minor(value), currency, "A", None, match.group(0), "bare_integer", reason="thousands separator")

    # RM-prefixed digit forms are explicit major-unit amounts. Unlike bare ITN
    # integers, they must never gain an inferred decimal point.
    match = re.search(r"\brm\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)\b", normalized)
    if match:
        digits = match.group(1)
        value = _minor(Decimal(digits.replace(",", "")))
        if "." not in digits:
            fraction = _minor_suffix(normalized, match.end())
            if fraction is _OUT_OF_RANGE:
                return _out_of_range(text, currency)
            if fraction is not None:
                surface = normalized[match.start():_MINOR_SUFFIX.match(normalized, match.end()).end()]
                return AmountResolution(value + fraction, currency, "A", None, surface, "currency_prefixed",
                                        reason="RM-prefixed digits with a minor-unit component")
        return AmountResolution(value, currency, "A", None, match.group(0), "currency_prefixed", reason="unambiguous RM-prefixed digits")

    match = re.search(r"\b([0-9]+)\.([0-9]{1,2})\b", normalized)
    if match:
        value = Decimal(f"{match.group(1)}.{match.group(2)}")
        return AmountResolution(_minor(value), currency, "A", None, match.group(0), "decimal_digits", reason="explicit decimal digits")

    # A digit integer directly qualified by "ringgit" is a literal MYR major-unit
    # amount. Do not send 3/4 digit forms such as "120 ringgit" or
    # "3500 ringgit" through the bare-integer compound-decimal ladder. An
    # explicit sen component remains a genuine decimal construction.
    match = re.search(r"(?<![\w.])([0-9]+)\s+ringgit\b", normalized)
    if match:
        whole = int(match.group(1))
        fraction = _minor_suffix(normalized, match.end())
        if fraction is _OUT_OF_RANGE:
            return _out_of_range(text, currency)
        end = _MINOR_SUFFIX.match(normalized, match.end()).end() if fraction is not None else match.end()
        return AmountResolution(
            whole * 100 + (fraction or 0),
            currency,
            "A",
            None,
            normalized[match.start():end],
            "currency_suffixed",
            reason="explicit digit integer qualified by ringgit",
        )

    # Comma followed by exactly two digits and spaced two-part digits are documented
    # as decimal separators, but count as rung-1 recovery because ITN chose a format.
    match = re.search(r"\b([0-9]{1,3})[, ]([0-9]{2})\b", normalized)
    if match and not (match.group(0).count(",") and len(match.group(1)) == 1 and len(match.group(2)) == 3):
        value = int(match.group(1)) * 100 + int(match.group(2))
        surface = "spaced" if " " in match.group(0) else "other"
        return AmountResolution(value, currency, "B", 1, match.group(0), surface, reason="two-digit separator rule")

    # Digits qualified as minor units ("50 sen", "¢50", "50¢", "50 cents") are
    # sen, never whole ringgit.
    match = _MINOR_ONLY.search(normalized)
    if match:
        value = int(match.group(1) or match.group(2) or match.group(3))
        if not 0 < value <= 99:
            return _out_of_range(text, currency)
        return AmountResolution(value, currency, "A", None, match.group(0), "minor_units", reason="explicit minor-unit digits")

    words = re.findall(r"[a-z]+", normalized)
    number_runs: list[list[str]] = []
    run: list[str] = []
    for word in words:
        if word in NUMBER_WORDS or word in CURRENCY_WORDS:
            run.append(word)
        elif run:
            number_runs.append(run)
            run = []
    if run:
        number_runs.append(run)

    for original_run in reversed(number_runs):  # self-corrections naturally prefer the last amount
        run = [word for word in original_run if word not in CURRENCY_WORDS]
        if "point" in run:
            point = run.index("point")
            whole = _parse_cardinal(run[:point])
            decimals = [ONES[token] for token in run[point + 1:] if token in ONES and ONES[token] < 10]
            if whole is not None and decimals:
                fraction = (decimals + [0, 0])[:2]
                return AmountResolution(whole * 100 + fraction[0] * 10 + fraction[1], currency, "A", None, " ".join(original_run), "word_form", reason="explicit point form")
        if "ringgit" in original_run:
            split = original_run.index("ringgit")
            whole = _parse_cardinal([w for w in original_run[:split] if w not in CURRENCY_WORDS])
            fraction = _parse_cardinal([w for w in original_run[split + 1:] if w not in CURRENCY_WORDS])
            if whole is not None:
                if fraction is not None and fraction > 99:
                    return _out_of_range(text, currency)
                return AmountResolution(whole * 100 + (fraction or 0), currency, "A", None, " ".join(original_run), "word_form", reason="currency word split")
        minor_index = next((index for index, word in enumerate(original_run) if word in MINOR_WORDS), None)
        if minor_index is not None:
            tokens = [word for word in original_run[:minor_index] if word not in CURRENCY_WORDS]
            value = _parse_cardinal(tokens)
            if value is not None and value > 0 and not _two_part(tokens):
                if value > 99:
                    return _out_of_range(text, currency)
                return AmountResolution(value, currency, "A", None, " ".join(original_run), "word_form", reason="minor-unit word form")
        cardinal = _parse_cardinal(run)
        if cardinal is not None and ("hundred" in run or "thousand" in run):
            return AmountResolution(cardinal * 100, currency, "A", None, " ".join(original_run), "word_form", reason="magnitude word")
        compound = _two_part(run)
        if compound:
            major, minor = compound
            return AmountResolution(major * 100 + minor, currency, "B", 1, " ".join(original_run), "word_form", reason="compound word form without magnitude")
        # Conversational filler such as "oh and I spent 30" can form a zero-valued
        # word run ("oh and"). It is not a monetary amount; continue to the digit
        # ladder instead of returning an invalid RM0 proposal.
        if cardinal is not None and cardinal > 0:
            return AmountResolution(cardinal * 100, currency, "A", None, " ".join(original_run), "word_form", reason="cardinal words")

    # Bare 3/4 digit ITN output could be whole currency or an inserted decimal.
    digit_matches = list(re.finditer(r"(?<![\w.])([0-9]{3,4})(?![\w.])", normalized))
    if digit_matches:
        match = digit_matches[-1]
        digits = match.group(1)
        integer_minor = int(digits) * 100
        decimal_minor = int(digits[:-2]) * 100 + int(digits[-2:])
        if whole_bare:
            return AmountResolution(integer_minor, currency, "A", None, digits, "bare_integer",
                                    reason="clear income or contribution whole-RM amount")
        chosen, rung, reason = _context_choice(normalized, integer_minor, decimal_minor, priors)
        if chosen is not None:
            return AmountResolution(chosen, currency, "B", rung, digits, "bare_integer", (integer_minor, decimal_minor), reason)
        return AmountResolution(None, currency, "B'", 5, digits, "bare_integer", (decimal_minor, integer_minor), "ambiguous bare integer requires confirmation")

    match = re.search(r"(?<![\w.])([0-9]{1,2})(?![\w.])", normalized)
    if match:
        return AmountResolution(int(match.group(1)) * 100, currency, "A", None, match.group(1), "bare_integer", reason="unambiguous one/two-digit integer")

    return AmountResolution(None, currency, "C", None, "", "other", reason="no recoverable amount")


def normalize_transcript(text: str) -> str:
    """Conservative transcript normalization for result inspection, not WER."""
    return canonical_text(text)
