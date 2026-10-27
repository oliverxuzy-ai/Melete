import Foundation

struct APIError: LocalizedError {
    let message: String
    /// HTTP status when the server answered; nil for a connection that never got an answer.
    var status: Int? = nil
    var errorDescription: String? { message }
}

/// Thin async client for the local FastAPI server.
struct API {
    let base: URL

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func request(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = 600
        if let body { req.httpBody = body }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError(message: detail ?? "HTTP \(code)", status: code)
        }
        return data
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try API.decoder.decode(T.self, from: try await request("GET", path))
    }

    func send<T: Decodable>(_ method: String, _ path: String, json: [String: Any?] = [:]) async throws -> T {
        let clean = json.compactMapValues { $0 }.merging(json.filter { $0.value == nil }.mapValues { _ in NSNull() }) { a, _ in a }
        let body = try JSONSerialization.data(withJSONObject: clean)
        return try API.decoder.decode(T.self, from: try await request(method, path, body: body, contentType: "application/json"))
    }

    func delete(_ path: String) async throws {
        _ = try await request("DELETE", path)
    }

    func upload<T: Decodable>(_ path: String, fields: [String: String], fileField: String, filename: String, data: Data) async throws -> T {
        let boundary = "----speech\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let out = try await request("POST", path, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        return try API.decoder.decode(T.self, from: out)
    }

    /// Keeps query strings intact (appendingPathComponent would escape the "?").
    func url(_ path: String) -> URL { URL(string: base.absoluteString.hasSuffix("/") ? base.absoluteString + path : base.absoluteString + "/" + path)! }

    // ---- typed calls
    func config() async throws -> ServerConfig { try await get("api/config") }
    func practices() async throws -> [PracticeListItem] { try await get("api/practices") }
    func practice(_ id: String) async throws -> Practice { try await get("api/practices/\(id)") }
    func sessions(filter: String) async throws -> [SessionSummary] { try await get("api/sessions?practice=\(filter)") }
    func session(_ id: String) async throws -> Session { try await get("api/sessions/\(id)") }

    // coaching and daily clips
    func today() async throws -> TodayPayload { try await get("api/today") }
    func shuffle() async throws -> TodayPayload { try await send("POST", "api/plan/shuffle") }
    func commitWeek() async throws -> TodayPayload { try await send("POST", "api/week/commit") }
    func settings() async throws -> SettingsPayload { try await get("api/settings") }
    func daily() async throws -> DailyPayload { try await get("api/daily") }
    func agenda() async throws -> AgendaPayload { try await get("api/agenda") }
    func recap(offset: Int) async throws -> Recap { try await get("api/recap?offset=\(offset)") }
    func sources() async throws -> [SourceItem] { try await get("api/sources") }
}
