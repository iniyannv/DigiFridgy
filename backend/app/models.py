"""SQLite tables (SQLModel). All datetimes are naive UTC (NaiveDatetime)."""
from __future__ import annotations

from datetime import date
from typing import Optional

from pydantic import NaiveDatetime
from sqlmodel import Field, SQLModel


class Household(SQLModel, table=True):
    __tablename__ = "households"
    id: Optional[int] = Field(default=None, primary_key=True)
    name: str
    nessie_customer_id: Optional[str] = None
    checking_account_id: Optional[str] = Field(default=None, index=True)
    grocery_fund_account_id: Optional[str] = None
    weekly_budget: float = 75.0
    is_demo: bool = False
    created_at: NaiveDatetime


class Member(SQLModel, table=True):
    """One person texting the agent. A household can have several (shared fridge)."""
    __tablename__ = "household_members"
    id: Optional[int] = Field(default=None, primary_key=True)
    household_id: int = Field(index=True)
    photon_handle: str = Field(index=True, unique=True)
    photon_space_id: Optional[str] = None   # the direct conversation
    agent_user_id: Optional[str] = None     # receivedBy.id: who we send as
    status: str = "active"                  # active | stopped
    display_name: Optional[str] = None
    assigned_line: Optional[str] = None     # Photon shared line assigned at sign-up (the number they text)
    welcomed: bool = False
    created_at: NaiveDatetime


class Item(SQLModel, table=True):
    __tablename__ = "items"
    id: Optional[int] = Field(default=None, primary_key=True)
    household_id: int = Field(index=True)
    sku: str
    name: str
    category: str
    location: str  # fridge | freezer | pantry
    emoji: str = ""
    price: float = 0.0  # per unit
    purchased_at: NaiveDatetime
    expires_at: NaiveDatetime
    status: str = Field(default="fresh", index=True)  # fresh | used | expired | tossed
    status_at: Optional[NaiveDatetime] = None
    source_purchase_id: Optional[str] = None


class ShoppingListItem(SQLModel, table=True):
    __tablename__ = "shopping_list"
    id: Optional[int] = Field(default=None, primary_key=True)
    household_id: int = Field(index=True)
    name: str
    sku: Optional[str] = None
    source: str = "manual"     # manual | auto
    confirmed: bool = True     # auto suggestions start unconfirmed until ADD ALL
    added_at: NaiveDatetime
    done: bool = False


class WasteEntry(SQLModel, table=True):
    __tablename__ = "waste_ledger"
    id: Optional[int] = Field(default=None, primary_key=True)
    household_id: int = Field(index=True)
    item_id: int = Field(unique=True)
    item_name: str = ""
    amount: float
    reason: str = "expired"  # expired | tossed
    recorded_at: NaiveDatetime


class PendingAction(SQLModel, table=True):
    __tablename__ = "pending_actions"
    id: Optional[int] = Field(default=None, primary_key=True)
    household_id: int = Field(index=True)
    kind: str  # transfer | bulk_used | nudge | disambiguate | add_suggestions
    payload_json: str = "{}"
    created_at: NaiveDatetime
    expires_at: NaiveDatetime
    status: str = "open"  # open | executing | done | declined | expired | superseded


class ProcessedPurchase(SQLModel, table=True):
    __tablename__ = "processed_purchases"
    nessie_purchase_id: str = Field(primary_key=True)
    household_id: int = Field(index=True)
    merchant_name: str = ""
    amount: float = 0.0
    purchase_date: date
    is_grocery: bool = False
    item_count: int = 0
    processed_at: NaiveDatetime


class ProcessedMessage(SQLModel, table=True):
    __tablename__ = "processed_messages"
    photon_message_id: str = Field(primary_key=True)
    processed_at: NaiveDatetime


class SentMessage(SQLModel, table=True):
    """Outbox log; the unique key makes proactive sends idempotent across restarts."""
    __tablename__ = "sent_messages"
    idempotency_key: str = Field(primary_key=True)
    member_id: Optional[int] = None
    text: str
    sent_at: NaiveDatetime


class JobRun(SQLModel, table=True):
    """Marks a scheduled job as done (e.g. sweep:<household>:<week>)."""
    __tablename__ = "job_runs"
    key: str = Field(primary_key=True)
    ran_at: NaiveDatetime


class PhotonCursor(SQLModel, table=True):
    __tablename__ = "photon_cursor"
    id: int = Field(default=1, primary_key=True)
    created_since: NaiveDatetime


class ClockOffset(SQLModel, table=True):
    __tablename__ = "clock_offset"
    id: int = Field(default=1, primary_key=True)
    offset_seconds: int = 0


class NessieObject(SQLModel, table=True):
    """IDs of seeded Nessie objects so seeding is idempotent (e.g. merchant:avon_fresh)."""
    __tablename__ = "nessie_objects"
    key: str = Field(primary_key=True)
    nessie_id: str


# ---------- SpacetimeDB bridge (shared fridge with the iOS app) ----------

class SpacetimeLink(SQLModel, table=True):
    """The SpacetimeDB identity this household acts as, and the app household it belongs to."""
    __tablename__ = "spacetime_links"
    household_id: int = Field(primary_key=True)
    identity: str
    token: str
    app_household_id: str = ""
    invite_code: str = ""
    linked_at: NaiveDatetime


class SpaceItemLink(SQLModel, table=True):
    """Which app item (FridgeItem id in SpacetimeDB) a backend unit row belongs to."""
    __tablename__ = "spacetime_item_links"
    item_id: int = Field(primary_key=True)
    household_id: int = Field(index=True)
    external_id: str = Field(index=True)


class SpaceSyncState(SQLModel, table=True):
    """Last agreed unit counts per app item, the base for the three-way merge.
    `count` = backend units after the last sync; `app_count` = app count we last saw or set."""
    __tablename__ = "spacetime_sync_state"
    external_id: str = Field(primary_key=True)
    household_id: int = Field(index=True)
    count: int = 0
    app_count: int = 0


class CardPurchaseLine(SQLModel, table=True):
    """One product line of a card purchase. Recent purchases wait here until the
    person adds them (text YES, or pick lines in the app's Add from card)."""
    __tablename__ = "card_purchase_lines"
    id: Optional[int] = Field(default=None, primary_key=True)
    nessie_purchase_id: str = Field(index=True)
    household_id: int = Field(index=True)
    line_index: int
    sku: str
    qty: int
    total: float
    status: str = "pending"  # pending | stocked | skipped
    status_at: Optional[NaiveDatetime] = None
