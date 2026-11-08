//! DigiFridgy SpacetimeDB module.
//!
//! All tables are private. Clients read only through per-caller views (`my_*`), which expose
//! the caller's own profile and the household they belong to, and write only through reducers,
//! which check household membership against `ctx.sender()`.
//!
//! Item / profile / shopping payloads are stored as the iOS app's JSON (`data` columns) so the
//! app's models can evolve without schema migrations. Columns the server needs to reason about
//! (ids, household, count) are real columns.

use spacetimedb::rand::Rng;
use spacetimedb::{reducer, table, view, Identity, ReducerContext, SpacetimeType, Table, Timestamp, ViewContext};

const MAX_DATA_LEN: usize = 32 * 1024;
const INVITE_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";

// MARK: - Tables (private)

#[table(accessor = user_profile)]
pub struct UserProfile {
    #[primary_key]
    pub identity: Identity,
    /// Empty when the user hasn't joined a household.
    pub household_id: String,
    /// App-side UserProfile JSON (allergens, radius, watchlist, …).
    pub data: String,
}

#[table(accessor = household)]
pub struct Household {
    #[primary_key]
    pub id: String,
    pub name: String,
    #[unique]
    pub invite_code: String,
    pub created_at: Timestamp,
}

#[table(accessor = household_member)]
pub struct HouseholdMember {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub household_id: String,
    #[index(btree)]
    pub member: Identity,
}

#[table(accessor = fridge_item)]
pub struct FridgeItem {
    #[primary_key]
    pub id: String,
    #[index(btree)]
    pub household_id: String,
    pub count: i32,
    /// App-side FridgeItem JSON. `count` above is authoritative.
    pub data: String,
    pub updated_at: Timestamp,
}

#[table(accessor = shopping_item)]
pub struct ShoppingItem {
    #[primary_key]
    pub id: String,
    #[index(btree)]
    pub household_id: String,
    pub data: String,
}

#[table(accessor = price_history)]
pub struct PriceHistory {
    /// "<household_id>|<upc>"
    #[primary_key]
    pub key: String,
    #[index(btree)]
    pub household_id: String,
    pub upc: String,
    pub last_price: f64,
    pub last_store_id: String,
    pub checked_at: Timestamp,
}

/// Who used what: one row each time a member uses up part of an item (app −1, or USED over iMessage).
/// It's the household's shared record for splitting grocery costs between roommates.
#[table(accessor = item_use)]
pub struct ItemUse {
    #[primary_key]
    #[auto_inc]
    pub id: u64,
    #[index(btree)]
    pub household_id: String,
    pub item_id: String,
    pub name: String,
    pub qty: i32,
    pub used_by: Identity,
    pub used_at: Timestamp,
}

/// A question waiting on a person: "Add these 6 items?", "Move $32 to Grocery Fund?". The iMessage
/// backend posts one for each YES/NO it asks; any member can answer it in the app, or by text.
/// `money` ones only count when the account holder answers (the backend checks `decided_by`).
#[table(accessor = approval)]
pub struct Approval {
    #[primary_key]
    pub id: String,
    #[index(btree)]
    pub household_id: String,
    pub kind: String,
    pub title: String,
    pub detail: String,
    pub money: bool,
    /// open | approved | declined
    pub status: String,
    pub decided_by: Option<Identity>,
    pub created_at: Timestamp,
}

// MARK: - View rows (plain types so HTTP SQL results are simple JSON)

#[derive(SpacetimeType)]
pub struct ProfileRow {
    pub identity_hex: String,
    pub household_id: String,
    pub data: String,
}

#[derive(SpacetimeType)]
pub struct HouseholdRow {
    pub id: String,
    pub name: String,
    pub invite_code: String,
    pub created_at_ms: i64,
    pub members: Vec<String>,
}

#[derive(SpacetimeType)]
pub struct ItemRow {
    pub id: String,
    pub count: i32,
    pub data: String,
    pub updated_at_ms: i64,
}

#[derive(SpacetimeType)]
pub struct ShoppingRow {
    pub id: String,
    pub data: String,
}

#[derive(SpacetimeType)]
pub struct PriceRow {
    pub upc: String,
    pub last_price: f64,
    pub last_store_id: String,
    pub checked_at_ms: i64,
}

#[derive(SpacetimeType)]
pub struct ItemUseRow {
    pub id: u64,
    pub item_id: String,
    pub name: String,
    pub qty: i32,
    pub used_by_hex: String,
    pub used_at_ms: i64,
}

#[derive(SpacetimeType)]
pub struct ApprovalRow {
    pub id: String,
    pub kind: String,
    pub title: String,
    pub detail: String,
    pub money: bool,
    pub status: String,
    pub decided_by_hex: String,
    pub created_at_ms: i64,
}

fn millis(t: Timestamp) -> i64 {
    t.to_micros_since_unix_epoch() / 1000
}

// MARK: - Per-caller views

/// The caller's household id, but only if they are still a member of it.
fn view_household_id(ctx: &ViewContext) -> Option<String> {
    let sender = ctx.sender();
    let profile = ctx.db.user_profile().identity().find(sender)?;
    if profile.household_id.is_empty() {
        return None;
    }
    let is_member = ctx
        .db
        .household_member()
        .member()
        .filter(&sender)
        .any(|m| m.household_id == profile.household_id);
    is_member.then_some(profile.household_id)
}

#[view(accessor = my_profile, public)]
fn my_profile(ctx: &ViewContext) -> Option<ProfileRow> {
    let profile = ctx.db.user_profile().identity().find(ctx.sender())?;
    Some(ProfileRow {
        identity_hex: ctx.sender().to_hex().to_string(),
        household_id: profile.household_id,
        data: profile.data,
    })
}

#[view(accessor = my_household, public)]
fn my_household(ctx: &ViewContext) -> Option<HouseholdRow> {
    let hid = view_household_id(ctx)?;
    let household = ctx.db.household().id().find(&hid)?;
    let members = ctx
        .db
        .household_member()
        .household_id()
        .filter(&hid)
        .map(|m| m.member.to_hex().to_string())
        .collect();
    Some(HouseholdRow {
        id: household.id,
        name: household.name,
        invite_code: household.invite_code,
        created_at_ms: millis(household.created_at),
        members,
    })
}

#[view(accessor = my_items, public)]
fn my_items(ctx: &ViewContext) -> Vec<ItemRow> {
    let Some(hid) = view_household_id(ctx) else { return vec![] };
    ctx.db
        .fridge_item()
        .household_id()
        .filter(&hid)
        .map(|i| ItemRow { id: i.id, count: i.count, data: i.data, updated_at_ms: millis(i.updated_at) })
        .collect()
}

#[view(accessor = my_shopping, public)]
fn my_shopping(ctx: &ViewContext) -> Vec<ShoppingRow> {
    let Some(hid) = view_household_id(ctx) else { return vec![] };
    ctx.db
        .shopping_item()
        .household_id()
        .filter(&hid)
        .map(|s| ShoppingRow { id: s.id, data: s.data })
        .collect()
}

#[view(accessor = my_prices, public)]
fn my_prices(ctx: &ViewContext) -> Vec<PriceRow> {
    let Some(hid) = view_household_id(ctx) else { return vec![] };
    ctx.db
        .price_history()
        .household_id()
        .filter(&hid)
        .map(|p| PriceRow {
            upc: p.upc,
            last_price: p.last_price,
            last_store_id: p.last_store_id,
            checked_at_ms: millis(p.checked_at),
        })
        .collect()
}

#[view(accessor = my_item_uses, public)]
fn my_item_uses(ctx: &ViewContext) -> Vec<ItemUseRow> {
    let Some(hid) = view_household_id(ctx) else { return vec![] };
    ctx.db
        .item_use()
        .household_id()
        .filter(&hid)
        .map(|u| ItemUseRow {
            id: u.id,
            item_id: u.item_id,
            name: u.name,
            qty: u.qty,
            used_by_hex: u.used_by.to_hex().to_string(),
            used_at_ms: millis(u.used_at),
        })
        .collect()
}

#[view(accessor = my_approvals, public)]
fn my_approvals(ctx: &ViewContext) -> Vec<ApprovalRow> {
    let Some(hid) = view_household_id(ctx) else { return vec![] };
    ctx.db
        .approval()
        .household_id()
        .filter(&hid)
        .map(|a| ApprovalRow {
            id: a.id,
            kind: a.kind,
            title: a.title,
            detail: a.detail,
            money: a.money,
            status: a.status,
            decided_by_hex: a.decided_by.map(|i| i.to_hex().to_string()).unwrap_or_default(),
            created_at_ms: millis(a.created_at),
        })
        .collect()
}

// MARK: - Helpers

fn check_len(field: &str, value: &str) -> Result<(), String> {
    if value.len() > MAX_DATA_LEN {
        return Err(format!("{field} is too large"));
    }
    Ok(())
}

fn check_id(id: &str) -> Result<(), String> {
    if id.is_empty() || id.len() > 64 {
        return Err("Invalid id".into());
    }
    Ok(())
}

/// The caller's current household, verified against the membership table.
fn require_household(ctx: &ReducerContext) -> Result<String, String> {
    let sender = ctx.sender();
    let profile = ctx
        .db
        .user_profile()
        .identity()
        .find(sender)
        .ok_or("Join or create a household first.")?;
    if profile.household_id.is_empty() {
        return Err("Join or create a household first.".into());
    }
    let is_member = ctx
        .db
        .household_member()
        .member()
        .filter(&sender)
        .any(|m| m.household_id == profile.household_id);
    if !is_member {
        return Err("You're not a member of this household.".into());
    }
    Ok(profile.household_id)
}

fn set_household(ctx: &ReducerContext, household_id: String) {
    let sender = ctx.sender();
    match ctx.db.user_profile().identity().find(sender) {
        Some(profile) => {
            ctx.db.user_profile().identity().update(UserProfile { household_id, ..profile });
        }
        None => {
            ctx.db.user_profile().insert(UserProfile { identity: sender, household_id, data: "{}".into() });
        }
    }
}

fn add_membership(ctx: &ReducerContext, household_id: &str) {
    let sender = ctx.sender();
    let already = ctx.db.household_member().member().filter(&sender).any(|m| m.household_id == household_id);
    if !already {
        ctx.db.household_member().insert(HouseholdMember { id: 0, household_id: household_id.to_string(), member: sender });
    }
}

fn new_invite_code(ctx: &ReducerContext) -> String {
    loop {
        let code: String = (0..6)
            .map(|_| INVITE_ALPHABET[ctx.rng().gen_range(0..INVITE_ALPHABET.len())] as char)
            .collect();
        if ctx.db.household().invite_code().find(&code).is_none() {
            return code;
        }
    }
}

// MARK: - Profile & household reducers

#[reducer]
pub fn save_profile(ctx: &ReducerContext, data: String) -> Result<(), String> {
    check_len("Profile", &data)?;
    let sender = ctx.sender();
    match ctx.db.user_profile().identity().find(sender) {
        Some(profile) => {
            ctx.db.user_profile().identity().update(UserProfile { data, ..profile });
        }
        None => {
            ctx.db.user_profile().insert(UserProfile { identity: sender, household_id: String::new(), data });
        }
    }
    Ok(())
}

/// `household_id` is generated by the client so it can start listening without a round trip.
#[reducer]
pub fn create_household(ctx: &ReducerContext, household_id: String, name: String) -> Result<(), String> {
    check_id(&household_id)?;
    let name = name.trim().to_string();
    if name.is_empty() || name.len() > 80 {
        return Err("Household name must be 1–80 characters.".into());
    }
    if ctx.db.household().id().find(&household_id).is_some() {
        return Err("Household already exists.".into());
    }
    let invite_code = new_invite_code(ctx);
    ctx.db.household().insert(Household { id: household_id.clone(), name, invite_code, created_at: ctx.timestamp });
    add_membership(ctx, &household_id);
    set_household(ctx, household_id);
    Ok(())
}

#[reducer]
pub fn join_household(ctx: &ReducerContext, invite_code: String) -> Result<(), String> {
    let code = invite_code.trim().to_uppercase();
    let household = ctx
        .db
        .household()
        .invite_code()
        .find(&code)
        .ok_or("No household found with that invite code.")?;
    add_membership(ctx, &household.id);
    set_household(ctx, household.id);
    Ok(())
}

#[reducer]
pub fn leave_household(ctx: &ReducerContext) -> Result<(), String> {
    let hid = require_household(ctx)?;
    let sender = ctx.sender();
    let memberships: Vec<u64> = ctx
        .db
        .household_member()
        .member()
        .filter(&sender)
        .filter(|m| m.household_id == hid)
        .map(|m| m.id)
        .collect();
    for id in memberships {
        ctx.db.household_member().id().delete(id);
    }
    set_household(ctx, String::new());
    Ok(())
}

// MARK: - Fridge item reducers

fn put_item(ctx: &ReducerContext, hid: &str, id: String, count: i32, data: String) -> Result<(), String> {
    check_id(&id)?;
    check_len("Item", &data)?;
    let row = FridgeItem { id: id.clone(), household_id: hid.to_string(), count: count.max(0), data, updated_at: ctx.timestamp };
    match ctx.db.fridge_item().id().find(&id) {
        Some(existing) if existing.household_id != hid => Err("Item belongs to another household.".into()),
        Some(_) => {
            ctx.db.fridge_item().id().update(row);
            Ok(())
        }
        None => {
            ctx.db.fridge_item().insert(row);
            Ok(())
        }
    }
}

#[reducer]
pub fn upsert_item(ctx: &ReducerContext, id: String, count: i32, data: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    put_item(ctx, &hid, id, count, data)
}

/// Receipt import: all-or-nothing batch.
#[reducer]
pub fn upsert_items(ctx: &ReducerContext, ids: Vec<String>, counts: Vec<i32>, datas: Vec<String>) -> Result<(), String> {
    let hid = require_household(ctx)?;
    if ids.len() != counts.len() || ids.len() != datas.len() || ids.len() > 200 {
        return Err("Invalid batch.".into());
    }
    for ((id, count), data) in ids.into_iter().zip(counts).zip(datas) {
        put_item(ctx, &hid, id, count, data)?;
    }
    Ok(())
}

#[reducer]
pub fn increment_count(ctx: &ReducerContext, id: String, delta: i32) -> Result<(), String> {
    let hid = require_household(ctx)?;
    let item = ctx.db.fridge_item().id().find(&id).ok_or("Item not found.")?;
    if item.household_id != hid {
        return Err("Item belongs to another household.".into());
    }
    let count = (item.count + delta).max(0);
    ctx.db.fridge_item().id().update(FridgeItem { count, updated_at: ctx.timestamp, ..item });
    Ok(())
}

fn record_use(ctx: &ReducerContext, hid: &str, item_id: &str, name: &str, qty: i32) {
    let name: String = name.chars().take(80).collect();
    ctx.db.item_use().insert(ItemUse {
        id: 0,
        household_id: hid.to_string(),
        item_id: item_id.to_string(),
        name,
        qty,
        used_by: ctx.sender(),
        used_at: ctx.timestamp,
    });
}

/// The caller used `qty` of an item: lowers the count (removing the item at zero) and records who used it.
#[reducer]
pub fn use_item(ctx: &ReducerContext, id: String, qty: i32, name: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    let item = ctx.db.fridge_item().id().find(&id).ok_or("Item not found.")?;
    if item.household_id != hid {
        return Err("Item belongs to another household.".into());
    }
    let qty = qty.clamp(1, item.count.max(1));
    record_use(ctx, &hid, &id, &name, qty);
    let count = item.count - qty;
    if count <= 0 {
        ctx.db.fridge_item().id().delete(&id);
    } else {
        ctx.db.fridge_item().id().update(FridgeItem { count, updated_at: ctx.timestamp, ..item });
    }
    Ok(())
}

/// Records a use without changing the count, for clients that sync counts separately
/// (the iMessage backend: USED by text, then its sync lowers the count).
#[reducer]
pub fn log_use(ctx: &ReducerContext, id: String, qty: i32, name: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    check_id(&id)?;
    if !(1..=1000).contains(&qty) {
        return Err("Invalid quantity.".into());
    }
    record_use(ctx, &hid, &id, &name, qty);
    Ok(())
}

#[reducer]
pub fn delete_item(ctx: &ReducerContext, id: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    if let Some(item) = ctx.db.fridge_item().id().find(&id) {
        if item.household_id != hid {
            return Err("Item belongs to another household.".into());
        }
        ctx.db.fridge_item().id().delete(&id);
    }
    Ok(())
}

// MARK: - Approvals

/// Posts (or re-posts) an open question for the caller's household.
#[reducer]
pub fn post_approval(ctx: &ReducerContext, id: String, kind: String, title: String, detail: String, money: bool) -> Result<(), String> {
    let hid = require_household(ctx)?;
    check_id(&id)?;
    check_len("Approval", &detail)?;
    let row = Approval {
        id: id.clone(),
        household_id: hid.clone(),
        kind: kind.chars().take(40).collect(),
        title: title.chars().take(200).collect(),
        detail,
        money,
        status: "open".into(),
        decided_by: None,
        created_at: ctx.timestamp,
    };
    match ctx.db.approval().id().find(&id) {
        Some(existing) if existing.household_id != hid => Err("Approval belongs to another household.".into()),
        Some(existing) if existing.status != "open" => Ok(()), // already answered; the poster will close it
        Some(_) => {
            ctx.db.approval().id().update(row);
            Ok(())
        }
        None => {
            ctx.db.approval().insert(row);
            Ok(())
        }
    }
}

/// A member answers an open question from the app. First answer wins.
#[reducer]
pub fn decide_approval(ctx: &ReducerContext, id: String, approve: bool) -> Result<(), String> {
    let hid = require_household(ctx)?;
    let a = ctx.db.approval().id().find(&id).ok_or("That question was already answered.")?;
    if a.household_id != hid {
        return Err("Approval belongs to another household.".into());
    }
    if a.status != "open" {
        return Err("That question was already answered.".into());
    }
    let status = if approve { "approved" } else { "declined" };
    ctx.db.approval().id().update(Approval { status: status.into(), decided_by: Some(ctx.sender()), ..a });
    Ok(())
}

/// The poster removes a question once it's handled (answered here or by text, or expired).
#[reducer]
pub fn close_approval(ctx: &ReducerContext, id: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    if let Some(a) = ctx.db.approval().id().find(&id) {
        if a.household_id != hid {
            return Err("Approval belongs to another household.".into());
        }
        ctx.db.approval().id().delete(&id);
    }
    Ok(())
}

// MARK: - Shopping list & price history

#[reducer]
pub fn save_shopping_item(ctx: &ReducerContext, id: String, data: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    check_id(&id)?;
    check_len("Shopping item", &data)?;
    match ctx.db.shopping_item().id().find(&id) {
        Some(existing) if existing.household_id != hid => Err("Item belongs to another household.".into()),
        Some(existing) => {
            ctx.db.shopping_item().id().update(ShoppingItem { data, ..existing });
            Ok(())
        }
        None => {
            ctx.db.shopping_item().insert(ShoppingItem { id, household_id: hid, data });
            Ok(())
        }
    }
}

#[reducer]
pub fn delete_shopping_item(ctx: &ReducerContext, id: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    if let Some(item) = ctx.db.shopping_item().id().find(&id) {
        if item.household_id != hid {
            return Err("Item belongs to another household.".into());
        }
        ctx.db.shopping_item().id().delete(&id);
    }
    Ok(())
}

#[reducer]
pub fn save_price(ctx: &ReducerContext, upc: String, price: f64, store_id: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    check_id(&upc)?;
    if !price.is_finite() || price < 0.0 {
        return Err("Invalid price.".into());
    }
    let key = format!("{hid}|{upc}");
    let row = PriceHistory { key: key.clone(), household_id: hid, upc, last_price: price, last_store_id: store_id, checked_at: ctx.timestamp };
    if ctx.db.price_history().key().find(&key).is_some() {
        ctx.db.price_history().key().update(row);
    } else {
        ctx.db.price_history().insert(row);
    }
    Ok(())
}
