"""Households and members. Provisioning creates the synthetic Nessie customer
and its two accounts (Everyday Checking + Grocery Fund)."""
from __future__ import annotations

from sqlmodel import Session, select

from .context import Ctx
from .models import Household, Member, NessieObject

CHECKING_NAME = "Everyday Checking"
FUND_NAME = "Grocery Fund"

DEMO_ADDRESS = {"street_number": "800", "street_name": "W Campbell Rd", "city": "Richardson",
                "state": "TX", "zip": "75080"}


def get_obj(s: Session, key: str) -> str | None:
    row = s.get(NessieObject, key)
    return row.nessie_id if row else None


def put_obj(s: Session, key: str, nessie_id: str) -> None:
    row = s.get(NessieObject, key) or NessieObject(key=key, nessie_id=nessie_id)
    row.nessie_id = nessie_id
    s.add(row)


async def provision_household(ctx: Ctx, name: str, first: str, last: str, *, is_demo: bool,
                              checking_balance: float = 1850.0, fund_balance: float = 120.0,
                              key: str | None = None, lookup_by_name: bool = True) -> Household:
    """Idempotent by `key`: reuses the stored Nessie customer/accounts when present,
    else looks them up by name before creating new ones.

    The household is found through the customer stored under `key`, never by display name:
    names aren't unique (two people whose numbers end in the same 4 digits, two Alexes)."""
    key = key or f"household:{first.lower()}_{last.lower()}"
    with Session(ctx.engine) as s:
        customer_id = get_obj(s, f"{key}:customer")
        existing = _by_customer(s, customer_id)
        if existing and existing.checking_account_id and existing.grocery_fund_account_id:
            return existing

    nessie = ctx.nessie
    if not customer_id and lookup_by_name:
        for c in await nessie.get_customers():
            if c.get("first_name") == first and c.get("last_name") == last:
                customer_id = c["_id"]
                break
    if not customer_id:
        customer_id = await nessie.create_customer(first, last, DEMO_ADDRESS)

    accounts = await nessie.get_customer_accounts(customer_id)
    by_nick = {a.get("nickname"): a["_id"] for a in accounts}
    checking = by_nick.get(CHECKING_NAME) or await nessie.create_account(
        customer_id, "Checking", CHECKING_NAME, checking_balance)
    fund = by_nick.get(FUND_NAME) or await nessie.create_account(
        customer_id, "Savings", FUND_NAME, fund_balance)

    with Session(ctx.engine) as s:
        put_obj(s, f"{key}:customer", customer_id)
        put_obj(s, f"{key}:checking", checking)
        put_obj(s, f"{key}:fund", fund)
        hh = _by_customer(s, customer_id) or Household(name=name, created_at=ctx.clock.now(), is_demo=is_demo)
        hh.nessie_customer_id = customer_id
        hh.checking_account_id = checking
        hh.grocery_fund_account_id = fund
        s.add(hh)
        s.commit()
        s.refresh(hh)
        return hh


def _by_customer(s: Session, customer_id: str | None) -> Household | None:
    if not customer_id:
        return None
    return s.exec(select(Household).where(Household.nessie_customer_id == customer_id)
                  .order_by(Household.id)).first()


def demo_household(s: Session) -> Household | None:
    return s.exec(select(Household).where(Household.is_demo == True).order_by(Household.id)).first()  # noqa: E712


def member_by_handle(s: Session, handle: str) -> Member | None:
    return s.exec(select(Member).where(Member.photon_handle == handle)).first()


async def household_for_new_member(ctx: Ctx, handle: str) -> Household:
    """DEMO_MODE: everyone joins the seeded demo household (one shared fridge).
    Otherwise each new person gets their own synthetic Nessie customer."""
    if ctx.settings.demo_mode:
        with Session(ctx.engine) as s:
            hh = demo_household(s)
        if hh:
            return hh
        from .demo.seed import seed
        await seed(ctx, with_history=True)
        with Session(ctx.engine) as s:
            return demo_household(s)
    digits = "".join(ch for ch in handle if ch.isalnum())[-4:] or "0000"
    # Keyed by the full handle (like web sign-up), so it's this person's own household.
    return await provision_household(ctx, f"Household {digits}", "Fridge", f"Owner{digits}",
                                     is_demo=False, key=f"household:{handle}", lookup_by_name=False)
