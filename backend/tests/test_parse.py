from app.fridge.parse import build_description, has_items, parse_description
from app.fridge.shelf_life import lookup


def test_valid_description():
    r = parse_description("DIGIFRIDGEY_ITEMS v1 | milk_whole_1gal x1 3.49 | spinach_5oz x2 5.98")
    assert [(i.sku, i.qty, i.total) for i in r.items] == [("milk_whole_1gal", 1, 3.49), ("spinach_5oz", 2, 5.98)]
    assert r.items[1].unit_price == 2.99
    assert r.errors == []


def test_malformed_lines_are_skipped_not_guessed():
    r = parse_description("DIGIFRIDGEY_ITEMS v1 | milk_whole_1gal x1 3.49 | spinach 2.99 | eggs_dozen x0 2.79 | "
                          "Bread x1 2.99 | yogurt_greek_32oz x1 abc")
    assert [i.sku for i in r.items] == ["milk_whole_1gal"]
    assert len(r.errors) == 4


def test_unknown_sku_defaults_to_other_seven_days():
    r = parse_description("DIGIFRIDGEY_ITEMS v1 | dragonfruit_1ct x1 4.00")
    info = lookup(r.items[0].sku)
    assert info.category == "other" and info.shelf_life_days == 7
    assert info.display_name == "dragonfruit 1ct"


def test_non_grocery_descriptions_have_no_items():
    for desc in ("Unleaded fuel", "", None, "digifridgey_items v1 | milk_whole_1gal x1 3.49",
                 "DIGIFRIDGEY_ITEMS v2 | milk_whole_1gal x1 3.49"):
        assert parse_description(desc).items == []
    assert not has_items("Unleaded fuel")


def test_build_round_trip():
    desc = build_description([("eggs_dozen", 1, 2.79), ("bananas_bunch", 2, 3.0)])
    assert desc == "DIGIFRIDGEY_ITEMS v1 | eggs_dozen x1 2.79 | bananas_bunch x2 3.00"
    assert len(parse_description(desc).items) == 2
