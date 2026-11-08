"""Read a product barcode from a photo, without an LLM.

zxing-cpp decodes the code on this server, Open Food Facts names the product (the same lookup the
iOS app uses), and the name is matched to the shelf-life catalog. Every step is optional: if the
libraries are missing or nothing decodes, the caller falls back to the other photo readers.
"""
from __future__ import annotations

import asyncio
import io
import logging
import re

import httpx

from ..fridge.matching import clean
from ..fridge.shelf_life import ShelfInfo, table

log = logging.getLogger("barcode")

OFF_URL = "https://world.openfoodfacts.org/api/v2/product/{code}.json"
OFF_FIELDS = "product_name,product_name_en,generic_name,generic_name_en,brands,categories_tags_en"
MAX_SIDE = 2000

try:
    import zxingcpp
    from PIL import Image, ImageOps
except ImportError:  # barcode reading is off; photos still go to the LLM reader if one is set up
    zxingcpp = None

try:  # iPhone photos are often HEIC
    from pillow_heif import register_heif_opener
    register_heif_opener()
except ImportError:
    pass


def available() -> bool:
    return zxingcpp is not None


def _decode_sync(data: bytes) -> list[str]:
    img = ImageOps.exif_transpose(Image.open(io.BytesIO(data)))
    img = img.convert("L")
    if max(img.size) > MAX_SIDE:
        img.thumbnail((MAX_SIDE, MAX_SIDE))
    results = zxingcpp.read_barcodes(img, formats=zxingcpp.BarcodeFormat.EANUPC)
    codes: list[str] = []
    for r in results:
        code = r.text.strip()
        if code.isdigit() and code not in codes:
            codes.append(code)
    return codes


async def decode(data: bytes) -> list[str]:
    """Product codes (EAN/UPC digits) found in an image, or [] if none or the image can't be read."""
    if not available():
        return []
    try:
        return await asyncio.to_thread(_decode_sync, data)
    except Exception as exc:
        log.info("no barcode read: %s", exc)
        return []


async def lookup_product(code: str) -> dict | None:
    """Open Food Facts product fields for a barcode, or None if unknown or unreachable."""
    try:
        async with httpx.AsyncClient(timeout=6.0, headers={"User-Agent": "DigiFridgey/1.0"}) as http:
            r = await http.get(OFF_URL.format(code=code), params={"fields": OFF_FIELDS})
            r.raise_for_status()
            body = r.json()
    except Exception as exc:
        log.warning("open food facts lookup failed for %s: %s", code, exc)
        return None
    if body.get("status") != 1 or not isinstance(body.get("product"), dict):
        return None
    return body["product"]


def product_label(product: dict) -> str:
    name = (product.get("product_name_en") or product.get("product_name") or "").strip()
    brand = (product.get("brands") or "").split(",")[0].strip()
    if brand and name and brand.lower() not in name.lower():
        return f"{brand} {name}"[:60]
    return (name or brand)[:60]


# A word before the catalog name that makes it a different food ("peanut butter" is not butter).
NOT_THE_SAME = {
    "butter": {"peanut", "almond", "cashew", "apple", "cocoa", "sunflower", "nut", "seed", "shea"},
    "cheese": {"cream", "cottage", "macaroni", "mac"},
    "milk": {"almond", "soy", "coconut", "rice", "cashew", "condensed", "evaporated", "powdered"},
    "sauce": {"soy", "hot", "bbq", "barbecue", "chili", "fish", "worcestershire", "sriracha", "buffalo",
              "teriyaki", "hoisin", "oyster", "apple", "cranberry", "cheese"},
    "juice": {"apple", "grape", "cranberry", "lemon", "lime", "tomato", "vegetable"},
}
_COMBO = re.compile(r"\s(&|and|with|n)\s")
_LINKS = {"from", "made", "of", "with", "in", "for"}  # "snacks made from potato" is not potatoes
# When a generic word fits several items, the everyday one.
PREFERRED = {"yogurt": "yogurt_cups_6pk"}


def _singular(word: str) -> str:
    for end in ("ies", "es", "s"):
        if word.endswith(end) and len(word) > len(end) + 2:
            return word[: -len(end)] + ("y" if end == "ies" else "")
    return word


def _words(text: str) -> list[str]:
    return [_singular(w) for w in clean(text).split()]


def _tail_match(query: str) -> ShelfInfo | None:
    """The catalog item whose name is the last words of `query` (its head noun), longest name first.
    "Organic Whole Milk" is whole milk; "Classic Potato Chips" is not potatoes."""
    raw = query.lower()
    q = _words(query)
    best, best_len = None, 0
    for info in table().values():
        for name in {info.display_name, *info.synonyms}:
            n = _words(name)
            if not n or len(n) > len(q) or q[-len(n):] != n or len(n) < best_len:
                continue
            if len(n) == best_len and PREFERRED.get(" ".join(n)) != info.sku:
                continue
            before = q[-len(n) - 1] if len(q) > len(n) else ""
            if before in _LINKS or before in NOT_THE_SAME.get(n[-1], ()):
                continue
            if _COMBO.search(raw) and len(n) < len(q):  # "mac & cheese" is a dish, not cheese
                continue
            best, best_len = info, len(n)
    return best


def catalog_match(product: dict) -> ShelfInfo | None:
    """The most specific categories first ("whole milks" before "dairies"), then the product's names.
    Only the last few categories count: crowd-sourced tags get noisy further up."""
    tags = [str(t).split(":")[-1].replace("-", " ") for t in (product.get("categories_tags_en") or [])]
    tries = list(reversed(tags[-3:]))
    tries += [product.get(k) for k in ("generic_name_en", "generic_name", "product_name_en", "product_name")]
    for q in tries:
        if isinstance(q, str) and q.strip():
            info = _tail_match(q)
            if info is not None:
                return info
    return None
