import Foundation
import os

/// A live SpacetimeDB subscription over WebSocket (`GET /v1/database/:db/subscribe`, subprotocol
/// `v1.json.spacetimedb`). It subscribes once to SQL queries over the per-caller views and keeps a local
/// copy of their rows: the server sends the initial rows, then only the inserts and deletes of each
/// transaction that touches them, from any client (another phone, the iMessage backend).
///
/// Rows arrive as JSON arrays in the view's column order, so each query is registered with its
/// column names (see the `*Row` structs in `server/spacetimedb/src/lib.rs`).
/// Reconnects with backoff; `isConnected` tells callers when to fall back to polling.
final class SpacetimeSubscription {
    private static let log = Logger(subsystem: "DigiFridgy", category: "spacetime")
    struct Query {
        let table: String
        let columns: [String]
        var sql: String { "SELECT * FROM \(table)" }
    }

    /// Called with a table's full current rows after the initial subscription and after every change to it.
    var onRows: (_ table: String, _ rows: [SpacetimeClient.Row]) -> Void = { _, _ in }
    /// Called when the connection comes up or drops.
    var onConnectionChange: (_ connected: Bool) -> Void = { _ in }

    private(set) var isConnected = false

    private let client: SpacetimeClient
    private let queries: [String: Query]
    private let session: URLSession
    /// Per table: row JSON → multiplicity (a view can return identical rows).
    private var tables: [String: [String: Int]] = [:]
    private var runTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    init(client: SpacetimeClient, queries: [Query], session: URLSession = .shared) {
        self.client = client
        self.queries = Dictionary(uniqueKeysWithValues: queries.map { ($0.table, $0) })
        self.session = session
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        setConnected(false)
    }

    // MARK: Connection

    private var url: URL {
        var comps = URLComponents(url: client.baseURL, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.path = "/v1/database/\(client.database)/subscribe"
        return comps.url!
    }

    private func run() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                try await connectAndListen { backoff = .seconds(1) }
            } catch SubscriptionFailure.unexpectedColumns(let table) {
                // The module's views changed shape; polling (which reads columns by name) keeps working.
                Self.log.error("\(table, privacy: .public) rows don't match the expected columns; using polling")
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                setConnected(false)
                return
            } catch {
                Self.log.info("subscription dropped: \(error.localizedDescription, privacy: .public)")
                // Dropped connection, server restart, no network, or a rejected token. The repository
                // polls over HTTP meanwhile (and surfaces auth errors from there).
            }
            socket = nil
            setConnected(false)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    private func connectAndListen(onApplied: () -> Void) async throws {
        guard let token = try await client.tokenProvider() else { throw SpacetimeError.notSignedIn }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("v1.json.spacetimedb", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.socket = socket
        socket.resume()

        let subscribe: [String: Any] = ["SubscribeMulti": [
            "query_strings": queries.values.map(\.sql).sorted(),
            "request_id": 1,
            "query_id": ["id": 1],
        ]]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: subscribe), as: UTF8.self)
        try await socket.send(.string(body))

        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            if try handle(data) {
                onApplied()
            }
        }
    }

    private func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        Self.log.info("subscription \(connected ? "live" : "down", privacy: .public)")
        onConnectionChange(connected)
    }

    // MARK: Messages

    /// Applies one server message. Returns true once the subscription is live.
    private func handle(_ data: Data) throws -> Bool {
        guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let error = message["SubscriptionError"] {
            throw SpacetimeError.badResponse("subscription: \(String(describing: error).prefix(160))")
        }
        if let applied = message["SubscribeMultiApplied"] as? [String: Any] {
            // Full initial state. Tables with no rows can be left out, so start every query empty.
            tables = queries.keys.reduce(into: [:]) { $0[$1] = [:] }
            apply((applied["update"] as? [String: Any])?["tables"] as? [[String: Any]] ?? [])
            try queries.keys.sorted().forEach(publish)
            setConnected(true)
            return true
        }
        let changed: [[String: Any]]
        if let light = message["TransactionUpdateLight"] as? [String: Any] {
            changed = (light["update"] as? [String: Any])?["tables"] as? [[String: Any]] ?? []
            Self.log.info("pushed update: \(changed.compactMap { $0["table_name"] as? String }, privacy: .public)")
        } else if let full = message["TransactionUpdate"] as? [String: Any],
                  let committed = (full["status"] as? [String: Any])?["Committed"] as? [String: Any] {
            changed = committed["tables"] as? [[String: Any]] ?? []
        } else {
            return false  // IdentityToken and other messages
        }
        try Set(apply(changed)).sorted().forEach(publish)
        return false
    }

    /// Applies deletes then inserts. Returns the names of the tables that changed.
    @discardableResult
    private func apply(_ updates: [[String: Any]]) -> [String] {
        var touched: [String] = []
        for table in updates {
            guard let name = table["table_name"] as? String, queries[name] != nil else { continue }
            var rows = tables[name] ?? [:]
            for update in table["updates"] as? [[String: Any]] ?? [] {
                for row in Self.rowKeys(update["deletes"]) {
                    if let n = rows[row], n > 1 { rows[row] = n - 1 } else { rows[row] = nil }
                }
                for row in Self.rowKeys(update["inserts"]) {
                    rows[row, default: 0] += 1
                }
            }
            tables[name] = rows
            touched.append(name)
        }
        return touched
    }

    private enum SubscriptionFailure: Error {
        case unexpectedColumns(String)
    }

    private func publish(_ table: String) throws {
        guard let query = queries[table] else { return }
        var result: [SpacetimeClient.Row] = []
        for (json, count) in tables[table] ?? [:] {
            guard let values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any],
                  values.count == query.columns.count else { throw SubscriptionFailure.unexpectedColumns(table) }
            var row: SpacetimeClient.Row = [:]
            for (name, value) in zip(query.columns, values) {
                row[name] = SpacetimeClient.unwrapOption(value)
            }
            result.append(contentsOf: repeatElement(row, count: count))
        }
        onRows(table, result)
    }

    /// Rows come as JSON strings of the row's values; keep them as strings so deletes match inserts exactly.
    private static func rowKeys(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { row in
            if let text = row as? String { return text }
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
