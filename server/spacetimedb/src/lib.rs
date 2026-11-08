//! DigiFridgy SpacetimeDB module.
//!
//! All tables are private. Clients read only through per-caller views (`my_*`), which expose
//! the caller's own profile and the household they belong to, and write only through reducers,
//! which check household membership against `ctx.sender()`.
//!
//! Item / profile / shopping payloads are stored as the iOS app's JSON (`data` columns) so the
//! app's models can evolve without schema migrations. Columns the server needs to reason about
//! (ids, household, count) are real columns.
//!
//! Errors never say whether an id exists in someone else's household: every cross-household
//! lookup fails with the same "Item not found." as a missing id (deletes just succeed).

use std::cell::RefCell;
use std::collections::HashMap;

use spacetimedb::rand::Rng;
use spacetimedb::{reducer, table, view, Identity, ReducerContext, SpacetimeType, Table, Timestamp, ViewContext};

const MAX_DATA_LEN: usize = 32 * 1024;
const INVITE_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
/// 31^8 ≈ 8.5e11 codes. Older 6-character codes keep working until they're rotated.
const INVITE_LEN: usize = 8;
/// Upper bound for an item's count (the bridge makes one backend row per unit).
const MAX_COUNT: i32 = 999;
const NOT_FOUND: &str = "Item not found.";
const MAX_FAILED_JOINS: u32 = 10;
const FAILED_JOIN_WINDOW_MICROS: i64 = 60 * 60 * 1_000_000;

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

fn clamp_count(count: i32) -> i32 {
    count.clamp(0, MAX_COUNT)
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

fn set_household_of(ctx: &ReducerContext, who: Identity, household_id: String) {
    match ctx.db.user_profile().identity().find(who) {
        Some(profile) => {
            ctx.db.user_profile().identity().update(UserProfile { household_id, ..profile });
        }
        None => {
            ctx.db.user_profile().insert(UserProfile { identity: who, household_id, data: "{}".into() });
        }
    }
}

fn set_household(ctx: &ReducerContext, household_id: String) {
    set_household_of(ctx, ctx.sender(), household_id);
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
        let code: String = (0..INVITE_LEN)
            .map(|_| INVITE_ALPHABET[ctx.rng().gen_range(0..INVITE_ALPHABET.len())] as char)
            .collect();
        if ctx.db.household().invite_code().find(&code).is_none() {
            return code;
        }
    }
}

fn rotate_code(ctx: &ReducerContext, household_id: &str) {
    if let Some(household) = ctx.db.household().id().find(household_id.to_string()) {
        let invite_code = new_invite_code(ctx);
        ctx.db.household().id().update(Household { invite_code, ..household });
    }
}

/// Removes `who`'s membership rows; `keep` (if any) is left alone. Returns the households they left.
fn remove_memberships(ctx: &ReducerContext, who: Identity, only: Option<&str>, keep: Option<&str>) -> Vec<String> {
    let rows: Vec<HouseholdMember> = ctx
        .db
        .household_member()
        .member()
        .filter(&who)
        .filter(|m| only.is_none_or(|h| m.household_id == h) && keep.is_none_or(|k| m.household_id != k))
        .collect();
    let mut left = Vec::new();
    for row in rows {
        ctx.db.household_member().id().delete(row.id);
        if !left.contains(&row.household_id) {
            left.push(row.household_id);
        }
    }
    left
}

/// After someone leaves or is kicked: an empty household is deleted with everything in it;
/// otherwise its invite code changes, so a former member can't come back with the old one.
fn after_member_left(ctx: &ReducerContext, household_id: &str) {
    let hid = household_id.to_string();
    if ctx.db.household_member().household_id().filter(&hid).next().is_some() {
        rotate_code(ctx, household_id);
        return;
    }
    ctx.db.fridge_item().household_id().delete(&hid);
    ctx.db.shopping_item().household_id().delete(&hid);
    ctx.db.price_history().household_id().delete(&hid);
    ctx.db.item_use().household_id().delete(&hid);
    ctx.db.household().id().delete(&hid);
}

/// Leaves every household except `keep` (joining or creating another one moves you).
fn leave_other_households(ctx: &ReducerContext, keep: &str) {
    for hid in remove_memberships(ctx, ctx.sender(), None, Some(keep)) {
        after_member_left(ctx, &hid);
    }
}

// Failed join attempts per identity. A reducer that returns `Err` is rolled back, so a counter in a
// table would never be written on the failure path; this lives in the module instance's memory
// instead. It resets when the module restarts, which is fine for slowing down code guessing.
thread_local! {
    static FAILED_JOINS: RefCell<HashMap<Identity, (i64, u32)>> = RefCell::new(HashMap::new());
}

fn failed_joins(who: Identity, now: i64) -> u32 {
    FAILED_JOINS.with(|m| match m.borrow().get(&who) {
        Some(&(start, n)) if now - start < FAILED_JOIN_WINDOW_MICROS => n,
        _ => 0,
    })
}

fn note_failed_join(who: Identity, now: i64) {
    FAILED_JOINS.with(|m| {
        let mut m = m.borrow_mut();
        if m.len() > 10_000 {
            m.retain(|_, (start, _)| now - *start < FAILED_JOIN_WINDOW_MICROS);
        }
        let entry = m.entry(who).or_insert((now, 0));
        if now - entry.0 >= FAILED_JOIN_WINDOW_MICROS {
            *entry = (now, 0);
        }
        entry.1 += 1;
    });
}

/// The `"name"` string at the top level of an item's JSON, without a JSON dependency.
fn json_name(data: &str) -> Option<String> {
    let b = data.as_bytes();
    let (mut i, mut depth) = (0usize, 0i32);
    let mut expect_key = false;
    while i < b.len() {
        match b[i] {
            b'{' => {
                depth += 1;
                expect_key = depth == 1;
            }
            b'[' => depth += 1,
            b'}' | b']' => depth -= 1,
            b',' => expect_key = depth == 1,
            b'"' => {
                let (s, end) = json_string(b, i)?;
                i = end;
                if depth == 1 && expect_key {
                    expect_key = false;
                    if s == "name" {
                        let mut j = i;
                        while j < b.len() && (b[j] as char).is_whitespace() {
                            j += 1;
                        }
                        if j >= b.len() || b[j] != b':' {
                            return None;
                        }
                        j += 1;
                        while j < b.len() && (b[j] as char).is_whitespace() {
                            j += 1;
                        }
                        return if j < b.len() && b[j] == b'"' { json_string(b, j).map(|(v, _)| v) } else { None };
                    }
                }
                continue;
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Decodes the JSON string starting at the quote `b[start]`; returns it and the index after the closing quote.
fn json_string(b: &[u8], start: usize) -> Option<(String, usize)> {
    let mut out: Vec<u8> = Vec::new();
    let mut i = start + 1;
    while i < b.len() {
        match b[i] {
            b'"' => return Some((String::from_utf8_lossy(&out).into_owned(), i + 1)),
            b'\\' => {
                let c = *b.get(i + 1)?;
                match c {
                    b'n' | b't' | b'r' | b'b' | b'f' => out.push(b' '),
                    b'u' => {
                        let hex = std::str::from_utf8(b.get(i + 2..i + 6)?).ok()?;
                        let ch = u32::from_str_radix(hex, 16).ok().and_then(char::from_u32).unwrap_or('?');
                        let mut buf = [0u8; 4];
                        out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        i += 4;
                    }
                    other => out.push(other),
                }
                i += 2;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    None
}

/// The name shown in the usage log, taken from the item row (never from the caller).
fn item_name(item: &FridgeItem) -> String {
    let name = json_name(&item.data).map(|n| n.trim().to_string()).unwrap_or_default();
    if name.is_empty() { "item".into() } else { name }
}

/// An item in the caller's household. Someone else's item looks exactly like a missing one.
fn find_my_item(ctx: &ReducerContext, hid: &str, id: &str) -> Result<FridgeItem, String> {
    match ctx.db.fridge_item().id().find(id.to_string()) {
        Some(item) if item.household_id == hid => Ok(item),
        _ => Err(NOT_FOUND.into()),
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
    leave_other_households(ctx, &household_id);
    add_membership(ctx, &household_id);
    set_household(ctx, household_id);
    Ok(())
}

/// Moves the caller into the household with this invite code (leaving any other one).
/// At most `MAX_FAILED_JOINS` wrong codes per identity per hour.
#[reducer]
pub fn join_household(ctx: &ReducerContext, invite_code: String) -> Result<(), String> {
    let sender = ctx.sender();
    let now = ctx.timestamp.to_micros_since_unix_epoch();
    if failed_joins(sender, now) >= MAX_FAILED_JOINS {
        return Err("Too many wrong invite codes. Try again in an hour.".into());
    }
    let code = invite_code.trim().to_uppercase();
    let found = if code.is_empty() || code.len() > 16 { None } else { ctx.db.household().invite_code().find(&code) };
    let Some(household) = found else {
        note_failed_join(sender, now);
        return Err("No household found with that invite code.".into());
    };
    leave_other_households(ctx, &household.id);
    add_membership(ctx, &household.id);
    set_household(ctx, household.id);
    Ok(())
}

#[reducer]
pub fn leave_household(ctx: &ReducerContext) -> Result<(), String> {
    require_household(ctx)?;
    for hid in remove_memberships(ctx, ctx.sender(), None, None) {
        after_member_left(ctx, &hid);
    }
    set_household(ctx, String::new());
    Ok(())
}

/// Removes another member (by identity hex) from the caller's household and changes the invite code.
#[reducer]
pub fn kick_member(ctx: &ReducerContext, identity_hex: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    let hex = identity_hex.trim();
    let hex = hex.strip_prefix("0x").unwrap_or(hex);
    let target = Identity::from_hex(hex).map_err(|_| "Member not found.".to_string())?;
    if target == ctx.sender() {
        return Err("Use leave to leave the household yourself.".into());
    }
    if remove_memberships(ctx, target, Some(&hid), None).is_empty() {
        return Err("Member not found.".into());
    }
    if let Some(profile) = ctx.db.user_profile().identity().find(target) {
        if profile.household_id == hid {
            set_household_of(ctx, target, String::new());
        }
    }
    after_member_left(ctx, &hid);
    Ok(())
}

/// A fresh invite code for the caller's household; the old one stops working.
#[reducer]
pub fn rotate_invite_code(ctx: &ReducerContext) -> Result<(), String> {
    let hid = require_household(ctx)?;
    rotate_code(ctx, &hid);
    Ok(())
}

// MARK: - Fridge item reducers

fn put_item(ctx: &ReducerContext, hid: &str, id: String, count: i32, data: String) -> Result<(), String> {
    check_id(&id)?;
    check_len("Item", &data)?;
    let row = FridgeItem { id: id.clone(), household_id: hid.to_string(), count: clamp_count(count), data, updated_at: ctx.timestamp };
    match ctx.db.fridge_item().id().find(&id) {
        Some(existing) if existing.household_id != hid => Err(NOT_FOUND.into()),
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
    let item = find_my_item(ctx, &hid, &id)?;
    let count = clamp_count(item.count.saturating_add(delta));
    ctx.db.fridge_item().id().update(FridgeItem { count, updated_at: ctx.timestamp, ..item });
    Ok(())
}

/// Sets the count only if it's still `expected` (compare-and-set), so a retried or late write can't
/// apply a change twice or overwrite a newer edit. `new` of 0 removes the item.
#[reducer]
pub fn set_count_if(ctx: &ReducerContext, id: String, expected: i32, new: i32) -> Result<(), String> {
    let hid = require_household(ctx)?;
    let item = find_my_item(ctx, &hid, &id)?;
    if item.count != expected {
        return Err(format!("Count changed (now {}).", item.count));
    }
    let count = clamp_count(new);
    if count == 0 {
        ctx.db.fridge_item().id().delete(&id);
    } else if count != item.count {
        ctx.db.fridge_item().id().update(FridgeItem { count, updated_at: ctx.timestamp, ..item });
    }
    Ok(())
}

fn record_use(ctx: &ReducerContext, hid: &str, item: &FridgeItem, qty: i32) {
    let name: String = item_name(item).chars().take(80).collect();
    ctx.db.item_use().insert(ItemUse {
        id: 0,
        household_id: hid.to_string(),
        item_id: item.id.clone(),
        name,
        qty,
        used_by: ctx.sender(),
        used_at: ctx.timestamp,
    });
}

/// The caller used `qty` of an item: lowers the count (removing the item at zero) and records who used it.
/// `_name` is ignored (kept for older clients); the log takes the name from the item itself.
#[reducer]
pub fn use_item(ctx: &ReducerContext, id: String, qty: i32, _name: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    let item = find_my_item(ctx, &hid, &id)?;
    let qty = qty.clamp(1, item.count.max(1));
    record_use(ctx, &hid, &item, qty);
    let count = item.count - qty;
    if count <= 0 {
        ctx.db.fridge_item().id().delete(&id);
    } else {
        ctx.db.fridge_item().id().update(FridgeItem { count, updated_at: ctx.timestamp, ..item });
    }
    Ok(())
}

/// Records a use without changing the count, for clients that sync counts separately
/// (the iMessage backend: USED by text, then its sync lowers the count). The item must be in the
/// caller's household; `_name` is ignored like in `use_item`.
#[reducer]
pub fn log_use(ctx: &ReducerContext, id: String, qty: i32, _name: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    check_id(&id)?;
    if !(1..=1000).contains(&qty) {
        return Err("Invalid quantity.".into());
    }
    let item = find_my_item(ctx, &hid, &id)?;
    record_use(ctx, &hid, &item, qty);
    Ok(())
}

#[reducer]
pub fn delete_item(ctx: &ReducerContext, id: String) -> Result<(), String> {
    let hid = require_household(ctx)?;
    if find_my_item(ctx, &hid, &id).is_ok() {
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
        Some(existing) if existing.household_id != hid => Err(NOT_FOUND.into()),
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
        if item.household_id == hid {
            ctx.db.shopping_item().id().delete(&id);
        }
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
