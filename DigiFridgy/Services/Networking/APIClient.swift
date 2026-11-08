import Foundation

nonisolated enum APIError: LocalizedError {
    case badStatus(Int, String)
    case notConfigured(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, _) where code == 429:
            "That service is busy right now. Try again in a minute."
        case .badStatus, .decoding:
            "Something went wrong on the server. Try again in a minute."
        case .notConfigured(let what):
            "\(what) isn't available in this build."
        }
    }

    /// Technical detail for the log and Settings → Developer.
    var failureReason: String? {
        switch self {
        case .badStatus(let code, let body):
            "Server returned \(code). \(body.prefix(140))"
        case .notConfigured(let what):
            "\(what) is not configured. Add its key to Config/Secrets.xcconfig."
        case .decoding(let detail):
            "Unexpected response format: \(detail)"
        }
    }
}

/// Tiny wrapper over URLSession: builds requests, checks status, decodes JSON.
nonisolated final class APIClient: Sendable {
    static let shared = APIClient()
    static let userAgent = "DigiFridgy/0.1 (hackathon)"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static let maxRateLimitRetries = 2

    /// Seconds from a numeric Retry-After header, else 1 s, 2 s, …; never more than 10 s.
    static func rateLimitDelay(retryAfter: String?, attempt: Int) -> Duration {
        let seconds = retryAfter.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? Double(1 << max(attempt - 1, 0))
        return .milliseconds(Int(min(max(seconds, 0.5), 10) * 1000))
    }

    func url(_ base: String, query: [(String, String)] = []) -> URL {
        var comps = URLComponents(string: base)!
        if !query.isEmpty {
            comps.queryItems = (comps.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return comps.url!
    }

    func get<T: Decodable>(_ type: T.Type, from url: URL, headers: [String: String] = [:],
                           decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return try await send(request, as: type, decoder: decoder)
    }

    func send<T: Decodable>(_ request: URLRequest, as type: T.Type,
                            decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        var request = request
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var (data, response) = try await session.data(for: request)
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Rate limited: wait as told (Retry-After, capped) and try again, at most twice.
        var retries = 0
        while status == 429, retries < Self.maxRateLimitRetries {
            retries += 1
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            try await Task.sleep(for: Self.rateLimitDelay(retryAfter: header, attempt: retries))
            (data, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        guard (200..<300).contains(status) else {
            throw APIError.badStatus(status, String(decoding: data, as: UTF8.self))
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error).prefix(200).description)
        }
    }
}
