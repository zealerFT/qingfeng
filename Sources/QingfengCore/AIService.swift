import Foundation

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAICompatible, anthropic, gemini, ollama
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic / Claude"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama"
        }
    }
}

public struct AIConfiguration: Codable, Equatable, Sendable {
    public var provider: AIProvider
    public var baseURL: String
    public var model: String
    public init(provider: AIProvider = .openAICompatible, baseURL: String = "https://api.openai.com/v1", model: String = "") {
        self.provider = provider; self.baseURL = baseURL; self.model = model
    }
    public var credentialAccount: String { provider.rawValue + ":" + baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    public func endpoint() throws -> URL {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 200 else {
            throw AIServiceError.configuration("请填写服务提供的模型 ID。")
        }
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw AIServiceError.configuration("服务地址需要完整 URL，不应包含密钥、查询参数或用户名。")
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard parts.scheme?.lowercased() == "https" || (parts.scheme?.lowercased() == "http" && local) else {
            throw AIServiceError.configuration("远程服务请使用 HTTPS；本机 Ollama / LM Studio 可使用 http://localhost。")
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        switch provider {
        case .openAICompatible:
            if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        case .anthropic:
            if !path.hasSuffix("/messages") { path += path.hasSuffix("/v1") ? "/messages" : "/v1/messages" }
        case .gemini:
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard !name.contains("/"), !name.contains("?"), !name.contains("#") else {
                throw AIServiceError.configuration("Gemini 模型 ID 不应包含 URL 路径或参数。")
            }
            if path.isEmpty { path = "/v1beta" }
            path += "/models/" + name + ":streamGenerateContent"
            parts.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        case .ollama:
            if !path.hasSuffix("/api/chat") { path += path.hasSuffix("/api") ? "/chat" : "/api/chat" }
        }
        parts.path = path
        guard let url = parts.url else { throw AIServiceError.configuration("服务地址无效。") }
        return url
    }
}

public struct AIChatTurn: Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}

public enum AIServiceError: LocalizedError {
    case configuration(String), http(Int), invalidResponse, service, empty, tooLong
    public var errorDescription: String? {
        switch self {
        case .configuration(let detail): return detail
        case .http(401), .http(403): return "鉴权失败，请检查当前服务的 API Key 和访问权限。"
        case .http(404): return "未找到接口或模型，请检查服务地址、协议类型和模型 ID。"
        case .http(429): return "服务限流或额度不足，请稍后重试或检查账户额度。"
        case .http(let status) where (300..<400).contains(status): return "服务返回了重定向。请直接填写最终 API 地址，密钥不会转发到重定向地址。"
        case .http(let status): return "模型服务返回 HTTP \(status)，请检查服务状态后重试。"
        case .invalidResponse: return "响应格式与所选协议不匹配，请检查接口类型。"
        case .service: return "模型服务返回错误，请检查模型名称、额度和服务配置。"
        case .empty: return "服务未返回可显示的回答，请检查该模型是否支持此接口。"
        case .tooLong: return "回答超过显示上限，已停止接收。请缩小问题范围。"
        }
    }
}

public enum AIRequest {
    public static func make(configuration: AIConfiguration, apiKey: String, turns: [AIChatTurn]) throws -> URLRequest {
        var request = URLRequest(url: try configuration.endpoint())
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/x-ndjson, application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any]
        let messages = turns.map { ["role": $0.role.rawValue, "content": $0.content] }
        switch configuration.provider {
        case .openAICompatible, .ollama:
            body = ["model": configuration.model, "stream": true,
                    "messages": [["role": "system", "content": FileAnalysisPrompt.system]] + messages]
            if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        case .anthropic:
            body = ["model": configuration.model, "stream": true, "max_tokens": 4096,
                    "system": FileAnalysisPrompt.system, "messages": messages]
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            body = ["systemInstruction": ["parts": [["text": FileAnalysisPrompt.system]]],
                    "contents": turns.map { ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]] as [String: Any] }]
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

/// Incremental SSE / NDJSON decoding; reasoning fields and tool calls are never executed or displayed.
public struct AIStreamDecoder {
    public let provider: AIProvider
    private var dataLines: [String] = []
    private var pendingBytes = 0
    public private(set) var finished = false
    public init(provider: AIProvider) { self.provider = provider }
    public mutating func push(_ line: String) throws -> String {
        guard !finished else { return "" }
        guard line.utf8.count <= 1_048_576 else { throw AIServiceError.tooLong }
        if provider == .ollama { return try decode(line) }
        if line.isEmpty { return try flush() }
        if line.hasPrefix("data:") {
            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            pendingBytes += value.utf8.count
            guard pendingBytes <= 1_048_576 else { throw AIServiceError.tooLong }
            dataLines.append(value)
        }
        return ""
    }
    public mutating func flush() throws -> String {
        guard !dataLines.isEmpty else { return "" }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll(); pendingBytes = 0
        return try decode(data)
    }
    private mutating func decode(_ value: String) throws -> String {
        if value == "[DONE]" { finished = true; return "" }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIServiceError.invalidResponse }
        if object["error"] != nil || object["type"] as? String == "error" { throw AIServiceError.service }
        switch provider {
        case .openAICompatible:
            let choices = object["choices"] as? [[String: Any]]
            let delta = choices?.first?["delta"] as? [String: Any]
            return delta?["content"] as? String ?? delta?["refusal"] as? String ?? ""
        case .anthropic:
            if object["type"] as? String == "message_stop" { finished = true }
            let delta = object["delta"] as? [String: Any]
            return delta?["text"] as? String ?? ""
        case .gemini:
            let candidates = object["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            return parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        case .ollama:
            if object["done"] as? Bool == true { finished = true }
            return (object["message"] as? [String: Any])?["content"] as? String ?? ""
        }
    }
}

public final class NoAIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct AIClient: Sendable {
    public init() {}
    public func stream(configuration: AIConfiguration, apiKey: String, turns: [AIChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForResource = 180
                config.httpCookieStorage = nil; config.urlCache = nil
                let session = URLSession(configuration: config, delegate: NoAIRedirects(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                do {
                    let request = try AIRequest.make(configuration: configuration, apiKey: apiKey, turns: turns)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else { throw AIServiceError.http(http.statusCode) }
                    var decoder = AIStreamDecoder(provider: configuration.provider)
                    var count = 0
                    func emit(_ text: String) throws {
                        count += text.count
                        guard count <= 120_000 else { throw AIServiceError.tooLong }
                        if !text.isEmpty { continuation.yield(text) }
                    }
                    // Preserve empty SSE delimiter lines; AsyncBytes.lines may omit them.
                    var line = Data()
                    var previousCR = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if byte == 10 && previousCR { previousCR = false; continue }
                        if byte == 10 || byte == 13 {
                            guard let string = String(data: line, encoding: .utf8) else { throw AIServiceError.invalidResponse }
                            try emit(decoder.push(string))
                            line.removeAll(keepingCapacity: true); previousCR = byte == 13
                            if decoder.finished { break }
                        } else {
                            previousCR = false; line.append(byte)
                            guard line.count <= 1_048_576 else { throw AIServiceError.tooLong }
                        }
                    }
                    if !line.isEmpty {
                        guard let string = String(data: line, encoding: .utf8) else { throw AIServiceError.invalidResponse }
                        try emit(decoder.push(string))
                    }
                    try emit(decoder.flush())
                    if count == 0 { throw AIServiceError.empty }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
