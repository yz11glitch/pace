"""Fixed Qwen outputs for API tests that exercise deterministic capture behavior."""

from __future__ import annotations

import json
from pathlib import Path

from noted.llm import RawProposal


CORPUS = Path(__file__).parent / "data" / "capture_utterances.jsonl"
PROPOSALS = {row["text"]: row["proposal"] for row in
             (json.loads(line) for line in CORPUS.read_text(encoding="utf-8").splitlines())}
PROPOSALS.update({
    "Spent sixteen fifty at ZUS Coffee.": {"intent": "create_transaction", "amount_expr": "sixteen fifty", "direction": "expense", "merchant_expr": "ZUS Coffee", "category_hint": "Food & Drink"},
    "Spent 1650 at a new stall.": {"intent": "create_transaction", "amount_expr": "1650", "direction": "expense", "merchant_expr": "new stall"},
    "Spent 1650 at a new stall": {"intent": "create_transaction", "amount_expr": "1650", "direction": "expense", "merchant_expr": "new stall"},
    "Spent money on lunch": {"intent": "create_transaction", "amount_expr": "money", "direction": "expense", "item_expr": "lunch", "category_hint": "Food & Drink"},
    "Spent RM20 at McDonald's": {"intent": "create_transaction", "amount_expr": "RM20", "direction": "expense", "merchant_expr": "McDonald's"},
    "Spent RM30 at McDonald's": {"intent": "create_transaction", "amount_expr": "RM30", "direction": "expense", "merchant_expr": "McDonald's"},
    "Spent RM12 on lunch": {"intent": "create_transaction", "amount_expr": "RM12", "direction": "expense", "item_expr": "lunch", "category_hint": "Food & Drink"},
    "Spent twenty ringgit at McDonald's": {"intent": "create_transaction", "amount_expr": "twenty ringgit", "direction": "expense", "merchant_expr": "McDonald's"},
    "Spent RM12.90 on coffee yesterday.": {"intent": "create_transaction", "amount_expr": "RM12.90", "direction": "expense", "item_expr": "coffee", "category_hint": "Food & Drink", "date_expr": "yesterday"},
    "Got a RM40 refund from Shopee": {"intent": "create_transaction", "amount_expr": "RM40", "direction": "refund", "merchant_expr": "Shopee"},
    "Spent RM240 on groceries.": {"intent": "create_transaction", "amount_expr": "RM240", "direction": "expense", "item_expr": "groceries", "category_hint": "Groceries"},
    "Spent RM12.90 on coffee.": {"intent": "create_transaction", "amount_expr": "RM12.90", "direction": "expense", "item_expr": "coffee", "category_hint": "Food & Drink"},
    "Oh and I spent 30 on Grab earlier.": {"intent": "create_transaction", "amount_expr": "30", "direction": "expense", "merchant_expr": "Grab", "date_expr": "earlier"},
    "Spent RM30 on Grab food earlier.": {"intent": "create_transaction", "amount_expr": "RM30", "direction": "expense", "merchant_expr": "Grab", "item_expr": "food", "category_hint": "Food & Drink", "date_expr": "earlier"},
    "Spent RM18 on chicken rice.": {"intent": "create_transaction", "amount_expr": "RM18", "direction": "expense", "item_expr": "chicken rice", "category_hint": "Food & Drink"},
    "Delete the last one": {"intent": "delete_transaction", "target": {"reference": "last_created"}},
})


class FixtureUnderstanding:
    model_id = "fixed-capture-fixture"
    contract = "v2"

    def __init__(self):
        self.calls = []

    def load(self): pass
    def close(self): pass

    def understand(self, transcript, frame):
        self.calls.append(transcript)
        return RawProposal(json.dumps(PROPOSALS[transcript]), self.model_id, 0)


def fixture_understanding():
    return FixtureUnderstanding()
