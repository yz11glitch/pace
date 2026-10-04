import pytest

from bench.asr.normalize import recover_amount


@pytest.mark.parametrize(
    ("text", "minor", "tier", "rung"),
    [
        ("one hundred and twenty", 12000, "A", None),
        ("sixteen fifty", 1650, "B", 1),
        ("twelve ninety", 1290, "B", 1),
        ("seventy-eight forty", 7840, "B", 1),
        ("sixteen point five zero", 1650, "A", None),
        ("twenty-three ringgit", 2300, "A", None),
        ("20 ringgit", 2000, "A", None),
        ("23 ringgit", 2300, "A", None),
        ("120 ringgit", 12000, "A", None),
        ("3500 ringgit", 350000, "A", None),
        ("120 ringgit 50 sen", 12050, "A", None),
        ("sixteen ringgit fifty sen", 1650, "A", None),
        ("RM20", 2000, "A", None),
        ("RM240", 24000, "A", None),
        ("RM3500", 350000, "A", None),
        ("RM2.40", 240, "A", None),
        ("RM12.90", 1290, "A", None),
        ("RM16.50", 1650, "A", None),
        ("RM 16.50", 1650, "A", None),
        ("rm16.50", 1650, "A", None),
        ("three thousand five hundred", 350000, "A", None),
        ("3,500", 350000, "A", None),
        ("16 50", 1650, "B", 1),
        ("16,50", 1650, "B", 1),
    ],
)
def test_required_rules(text, minor, tier, rung):
    result = recover_amount(text)
    assert result.amount_minor == minor
    assert result.provisional_tier == tier
    assert result.rung == rung


def test_bare_integer_uses_merchant_prior():
    priors = {"merchants": [{
        "name": "McDonald's", "aliases": ["mcdonalds"], "amount_count": 20,
        "amount_min_minor": 600, "amount_max_minor": 4500, "amount_median_minor": 1800,
    }]}
    result = recover_amount("Spent 1650 at McDonalds", priors)
    assert result.amount_minor == 1650
    assert result.provisional_tier == "B"
    assert result.rung == 2


def test_bare_integer_without_prior_defers():
    result = recover_amount("Spent 1650 at a new stall", {"merchants": []})
    assert result.amount_minor is None
    assert result.provisional_tier == "B'"
    assert result.alternatives_minor == (1650, 165000)


def test_rm_prefixed_integer_is_not_reinterpreted_by_context():
    result = recover_amount("Spent RM1650 at a new stall", {"merchants": []})
    assert result.amount_minor == 165000
    assert result.provisional_tier == "A"
    assert result.surface_class == "currency_prefixed"
    assert result.alternatives_minor == ()


def test_global_prior_is_rung_three():
    result = recover_amount("Spent 1650 somewhere new", {
        "merchants": [], "global": {"amount_count": 100, "amount_p99_minor": 100_000},
    })
    assert result.amount_minor == 1650
    assert result.rung == 3


def test_category_prior_is_rung_four():
    result = recover_amount("Spent 1650 on coffee", {
        "merchants": [], "global": {"amount_count": 0, "amount_p99_minor": None},
        "categories": [{"name": "food_drink", "keywords": ["coffee"], "amount_max_minor": 20_000}],
    })
    assert result.amount_minor == 1650
    assert result.rung == 4


def test_self_correction_prefers_last_amount():
    result = recover_amount("sixteen fifty no wait eighteen fifty")
    assert result.amount_minor == 1850
