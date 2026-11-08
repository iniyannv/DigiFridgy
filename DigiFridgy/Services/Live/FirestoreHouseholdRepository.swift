import Foundation
import FirebaseFirestore

/// Firestore-backed household data. See `firestore.rules` for the access model.
final class FirestoreHouseholdRepository: HouseholdRepository {
    private var db: Firestore { Firestore.firestore() }
    private let encoder = Firestore.Encoder()

    private func users() -> CollectionReference { db.collection("users") }
    private func households() -> CollectionReference { db.collection("households") }
    private func items(_ hid: String) -> CollectionReference { households().document(hid).collection("items") }
    private func shopping(_ hid: String) -> CollectionReference { households().document(hid).collection("shopping") }
    private func prices(_ hid: String) -> CollectionReference { households().document(hid).collection("priceHistory") }

    // MARK: Profile

    func profile(uid: String) async throws -> UserProfile? {
        let snap = try await users().document(uid).getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: UserProfile.self)
    }

    func saveProfile(_ profile: UserProfile) async throws {
        try await users().document(profile.uid).setData(encoder.encode(profile))
    }

    // MARK: Household

    func createHousehold(name: String, ownerUid: String) async throws -> Household {
        var code = Household.makeInviteCode()
        for _ in 0..<5 {
            let clash = try await households().whereField("inviteCode", isEqualTo: code).limit(to: 1).getDocuments()
            if clash.isEmpty { break }
            code = Household.makeInviteCode()
        }
        let ref = households().document()
        let household = Household(id: ref.documentID, name: name, inviteCode: code,
                                  memberUids: [ownerUid], createdAt: .now)
        try await ref.setData(encoder.encode(household))
        return household
    }

    func joinHousehold(code: String, uid: String) async throws -> Household {
        let normalized = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let snap = try await households().whereField("inviteCode", isEqualTo: normalized).limit(to: 1).getDocuments()
        guard let doc = snap.documents.first else { throw HouseholdError.codeNotFound }
        // Security rules only allow appending your own uid.
        try await doc.reference.updateData(["memberUids": FieldValue.arrayUnion([uid])])
        var household = try doc.data(as: Household.self)
        if !household.memberUids.contains(uid) { household.memberUids.append(uid) }
        return household
    }

    func household(id: String) async throws -> Household? {
        let snap = try await households().document(id).getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: Household.self)
    }

    func leaveHousehold(id: String, uid: String) async throws {
        try await households().document(id).updateData(["memberUids": FieldValue.arrayRemove([uid])])
    }

    // MARK: Items

    func itemsStream(householdId: String) -> AsyncThrowingStream<[FridgeItem], any Error> {
        AsyncThrowingStream { continuation in
            let registration = items(householdId).addSnapshotListener { snapshot, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                let decoded = snapshot?.documents.compactMap { try? $0.data(as: FridgeItem.self) } ?? []
                continuation.yield(decoded)
            }
            let box = ListenerBox(registration)
            continuation.onTermination = { _ in box.remove() }
        }
    }

    func fetchItems(householdId: String) async throws -> [FridgeItem] {
        let snap = try await items(householdId).getDocuments()
        return snap.documents.compactMap { try? $0.data(as: FridgeItem.self) }
    }

    func saveItem(_ item: FridgeItem, householdId: String) async throws {
        try await items(householdId).document(item.id).setData(encoder.encode(item))
    }

    func saveItems(_ newItems: [FridgeItem], householdId: String) async throws {
        let batch = db.batch()
        for item in newItems {
            batch.setData(try encoder.encode(item), forDocument: items(householdId).document(item.id))
        }
        try await batch.commit()
    }

    func incrementCount(itemId: String, by delta: Int, householdId: String) async throws {
        try await items(householdId).document(itemId).updateData(["count": FieldValue.increment(Int64(delta))])
    }

    func deleteItem(id: String, householdId: String) async throws {
        try await items(householdId).document(id).delete()
    }

    // MARK: Shopping list

    func shoppingStream(householdId: String) -> AsyncThrowingStream<[ShoppingListItem], any Error> {
        AsyncThrowingStream { continuation in
            let registration = shopping(householdId).addSnapshotListener { snapshot, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                let decoded = snapshot?.documents.compactMap { try? $0.data(as: ShoppingListItem.self) } ?? []
                continuation.yield(decoded.sorted { $0.addedAt > $1.addedAt })
            }
            let box = ListenerBox(registration)
            continuation.onTermination = { _ in box.remove() }
        }
    }

    func saveShoppingItem(_ item: ShoppingListItem, householdId: String) async throws {
        try await shopping(householdId).document(item.id).setData(encoder.encode(item))
    }

    func deleteShoppingItem(id: String, householdId: String) async throws {
        try await shopping(householdId).document(id).delete()
    }

    // MARK: Price history

    func priceHistory(upc: String, householdId: String) async throws -> PriceHistory? {
        let snap = try await prices(householdId).document(upc).getDocument()
        guard snap.exists else { return nil }
        return try snap.data(as: PriceHistory.self)
    }

    func savePriceHistory(_ history: PriceHistory, householdId: String) async throws {
        try await prices(householdId).document(history.upc).setData(encoder.encode(history))
    }
}

/// Lets the stream's @Sendable termination handler remove the Firestore listener.
private nonisolated final class ListenerBox: @unchecked Sendable {
    private let registration: any ListenerRegistration
    init(_ registration: any ListenerRegistration) { self.registration = registration }
    func remove() { registration.remove() }
}

nonisolated enum HouseholdError: LocalizedError {
    case codeNotFound
    case noHousehold

    var errorDescription: String? {
        switch self {
        case .codeNotFound: "No household found with that invite code."
        case .noHousehold: "Join or create a household first."
        }
    }
}
