"""Sen, cent and ¢ components are minor units, never whole ringgit.

Each case below was a silent wrong amount before the Phase 1 oracle fix (for
example "fifty sen" resolved to RM50). The native port copies these rules, so
the oracle must be right first.
"""

from __future__ import annotations

import pytest

from noted.normalize import recover_amount


@pytest.mark.parametrize(("text", "minor"), [
    # Sen-only amounts, as words and as digits.
    ("fifty sen", 50),
    ("seventy five sen", 75),
    ("seventy-five sen", 75),
    ("five sen", 5),
    ("50 sen", 50),
    ("5 sen", 5),
    ("paid 90 sen for parking", 90),
    # Apple Speech renders cents with the ¢ sign; ASR may also say "cents".
    ("¢50", 50),
    ("50¢", 50),
    ("50 cents", 50),
    ("fifty cents", 50),
    ("one cent", 1),
    # A ringgit amount with a minor-unit component in any of those forms.
    ("16 ringgit ¢50", 1650),
    ("16 ringgit 50¢", 1650),
    ("16 ringgit fifty sen", 1650),
    ("16 ringgit and fifty sen", 1650),
    ("16 ringgit 50 cents", 1650),
    ("RM16 50 sen", 1650),
    ("RM16 ¢50", 1650),
    ("rm 16 and 5 sen", 1605),
])
def test_minor_unit_components_are_never_whole_ringgit(text: str, minor: int):
    result = recover_amount(text)
    assert result.amount_minor == minor
    assert result.provisional_tier == "A"


@pytest.mark.parametrize(("text", "minor"), [
    # Existing behaviour that must survive the fix.
    ("120 ringgit 50 sen", 12050),
    ("sixteen ringgit fifty sen", 1650),
    ("twenty ringgit and fifty sen", 2050),
    ("20 ringgit and 50 sen", 2050),
    ("sixteen fifty sen", 1650),
    ("RM16.50", 1650),
    ("RM16", 1600),
    ("16 ringgit", 1600),
    ("spent 18 at grab", 1800),
])
def test_existing_ringgit_forms_are_unchanged(text: str, minor: int):
    assert recover_amount(text).amount_minor == minor


@pytest.mark.parametrize("text", [
    "150 sen",           # more than 99 sen is not a sen component
    "one hundred sen",
    "RM16 150 sen",
])
def test_out_of_range_minor_units_never_become_a_different_amount(text: str):
    result = recover_amount(text)
    assert result.amount_minor not in {15000, 10000, 1600, 150, 100}
    assert result.amount_minor is None
