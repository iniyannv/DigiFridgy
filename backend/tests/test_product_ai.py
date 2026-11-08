"""AI naming and categorizing for scanned products (fake LLM; no key needed)."""
import pytest
from fastapi.testclient import TestClient

from app.brain import product_ai
from app.main import create_app

from .conftest import run

CATS = ["milk", "chicken", "pantry", "snacks", "yogurt"]


class FakeLLM:
    def __init__(self, answer):
        self.answer, self.calls = answer, 0

    async def describe_product(self, name, brand, categories):
        self.calls += 1
        assert "other" in categories  # always offered as the way out
        return self.answer


@pytest.fixture(autouse=True)
def fresh_cache():
    product_ai._CACHE.clear()


def test_flavor_is_not_the_ingredient(ctx):
    ctx.llm = FakeLLM({"name": "cup noodles chicken", "category": "pantry", "storage": "pantry"})
    g = run(product_ai.describe(ctx, "Cup Noodles Chicken Flavor 2.25oz", "Nissin", CATS))
    assert g == product_ai.Guess(name="Cup noodles chicken", category="pantry", storage="pantry")


def test_answers_outside_the_list_or_junk_are_dropped(ctx):
    for bad in ({"name": "x", "category": "ramen", "storage": "pantry"}, None, "nope", {"name": "Milk"}):
        product_ai._CACHE.clear()
        ctx.llm = FakeLLM(bad)
        assert run(product_ai.describe(ctx, "Some product", None, CATS)) is None


def test_bad_name_or_storage_falls_back(ctx):
    ctx.llm = FakeLLM({"name": "1234 ### " + "x" * 50, "category": "milk", "storage": "basement"})
    g = run(product_ai.describe(ctx, "Organic Whole Milk Half Gallon", None, CATS))
    assert g.name == "Organic Whole Milk Half Gallon" and g.category == "milk" and g.storage == "fridge"


def test_no_llm_means_no_guess(ctx):
    ctx.llm = None
    assert run(product_ai.describe(ctx, "Cup Noodles", None, CATS)) is None


def test_same_product_is_asked_once(ctx):
    ctx.llm = FakeLLM({"name": "Greek yogurt", "category": "yogurt", "storage": "fridge"})
    for _ in range(3):
        run(product_ai.describe(ctx, "Chobani Greek Yogurt Plain", "Chobani", CATS))
    assert ctx.llm.calls == 1


def test_llm_error_is_not_fatal(ctx):
    class Broken:
        async def describe_product(self, *a):
            raise RuntimeError("quota")
    ctx.llm = Broken()
    assert run(product_ai.describe(ctx, "Cup Noodles", None, CATS)) is None


def test_endpoint(ctx):
    ctx.llm = FakeLLM({"name": "Cup Noodles chicken", "category": "pantry", "storage": "pantry"})
    c = TestClient(create_app(ctx))  # TestClient is local, so it counts as the operator
    r = c.post("/demo/product/describe", json={"name": "Cup Noodles Chicken Flavor", "brand": "Nissin",
                                               "categories": CATS}).json()
    assert r == {"ok": True, "name": "Cup Noodles chicken", "category": "pantry", "storage": "pantry"}
    ctx.llm = None
    product_ai._CACHE.clear()
    assert c.post("/demo/product/describe", json={"name": "x", "categories": CATS}).json() == {"ok": False}


def test_app_category_beats_a_word_match_when_syncing(seeded):
    # An app-scanned "Cup Noodles Chicken Flavor" (app category pantry) must not become chicken breast here.
    from app.spacetime.bridge import _new_unit, app_category
    from .conftest import household
    ctx = seeded
    hh = household(ctx)
    now = ctx.clock.now()
    noodles = _new_unit(ctx, hh.id, None, {"name": "Cup Noodles Chicken Flavor", "category": "pantry"}, now)
    assert noodles.category != "meat" and noodles.emoji == "🥫" and noodles.location == "pantry"
    # Agreeing categories keep the catalog item (and its shelf life and emoji).
    breast = _new_unit(ctx, hh.id, None, {"name": "chicken breast", "category": "chicken"}, now)
    assert breast.category == "meat" and breast.emoji == "🍗"
    # No category from the app: the word match as before.
    assert _new_unit(ctx, hh.id, None, {"name": "whole milk"}, now).category == "dairy"
    assert app_category("Cup Noodles Chicken Flavor") == "pantry"
