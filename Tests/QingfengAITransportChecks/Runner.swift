import Foundation
import QingfengCore

@main enum TransportChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2, let port = Int(CommandLine.arguments[1]), (1...65535).contains(port) else {
            fatalError("Run through scripts/test-ai-transport.py with its loopback fixture server.")
        }
        let base = "http://127.0.0.1:\(port)"
        let turns = [AIChatTurn(role: .user, content: "Synthetic transport fixture")]
        var passed = 0
        for provider in AIProvider.allCases {
            let suffix: String
            switch provider { case .openAICompatible: suffix = "/v1"; case .gemini: suffix = "/v1beta"; default: suffix = "" }
            let configuration = AIConfiguration(provider: provider, baseURL: base + suffix, model: "test-model")
            var output = ""
            for try await part in AIClient().stream(configuration: configuration, apiKey: "synthetic-secret", turns: turns) { output += part }
            guard output == "建议保留。" else { fatalError("Unexpected streamed response: \(provider)") }
            passed += 1; print("PASS HTTP stream \(provider.rawValue)")
        }
        for (model, status) in [("unauthorized", 401), ("redirect", 302)] {
            do {
                for try await _ in AIClient().stream(configuration: AIConfiguration(baseURL: base + "/v1", model: model),
                                                     apiKey: "synthetic-secret", turns: turns) {}
                fatalError("Expected HTTP rejection")
            } catch AIServiceError.http(let code) {
                guard code == status else { fatalError("Unexpected HTTP status") }
                passed += 1; print("PASS HTTP \(status) handling")
            }
        }
        do {
            for try await _ in AIClient().stream(configuration: AIConfiguration(baseURL: base + "/v1", model: "empty"),
                                                 apiKey: "", turns: turns) {}
            fatalError("Expected empty response rejection")
        } catch AIServiceError.empty { passed += 1; print("PASS empty response") }
        let task = Task {
            for try await _ in AIClient().stream(configuration: AIConfiguration(baseURL: base + "/v1", model: "cancel"),
                                                 apiKey: "", turns: turns) {}
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.result
        passed += 1; print("PASS cancellation")
        print("AI transport checks: \(passed)/8 passed")
    }
}
