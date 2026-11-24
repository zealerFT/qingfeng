import AppKit
import SwiftUI
import Security
import QingfengCore

enum AISecretStore {
    static func query(_ config: AIConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.qingfeng.mac.ai",
         kSecAttrAccount as String: config.credentialAccount]
    }
    static func read(_ config: AIConfiguration) throws -> String {
        var request = query(config)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw error(status) }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String, config: AIConfiguration) throws {
        let request = query(config)
        if key.isEmpty {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
            return
        }
        let update = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(request as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(update) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw error(status) }
    }
    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: "QingfengKeychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "无法访问钥匙串（\(status)）。请允许清风访问自己保存的 AI 密钥后重试。"])
    }
}

struct AssistantMessage: Identifiable {
    let id = UUID()
    let role: AIChatTurn.Role
    var text: String
    var requestContent: String?
    var isError = false
}

@MainActor final class AssistantModel: ObservableObject {
    @Published var configuration: AIConfiguration
    @Published var messages: [AssistantMessage] = []
    @Published var input = ""
    @Published var busy = false
    @Published var showSettings = false
    @Published var error: String?
    @Published var pendingAnalysis: String?
    @Published var preparingAnalysis: String?
    @Published var floatingIconEnabled: Bool {
        didSet { if !preview { UserDefaults.standard.set(floatingIconEnabled, forKey: "Qingfeng.aiFloatingIcon") } }
    }
    private let preview: Bool
    private var pendingItem: ScanItem?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastRequest: [AIChatTurn] = []
    private var lastResponseID: UUID?
    private static let settingsKey = "Qingfeng.aiConfiguration"

    init(preview: Bool = false) {
        self.preview = preview
        if !preview, let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let config = try? JSONDecoder().decode(AIConfiguration.self, from: data) { configuration = config }
        else { configuration = AIConfiguration() }
        floatingIconEnabled = preview ? false : (UserDefaults.standard.object(forKey: "Qingfeng.aiFloatingIcon") as? Bool ?? true)
    }
    var configured: Bool { (try? configuration.endpoint()) != nil }
    var isPreview: Bool { preview }
    var serviceLabel: String { configured ? "\(configuration.provider.title) · \(configuration.model)" : "配置模型后开始咨询" }

    func save(_ config: AIConfiguration, key: String) throws {
        _ = try config.endpoint()
        if !preview {
            try AISecretStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), config: config)
            let data = try JSONEncoder().encode(config)
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        configuration = config; showSettings = false; error = nil
        if let item = pendingItem {
            pendingAnalysis = nil; pendingItem = nil
            analyze(item)
        }
    }
    func analyze(_ item: ScanItem) {
        stop()
        pendingAnalysis = nil; pendingItem = nil
        if !configured {
            pendingAnalysis = FileAnalysisPrompt.displayMessage(for: item); pendingItem = item; showSettings = true; return
        }
        let token = UUID(); generation = token; busy = true; error = nil
        preparingAnalysis = item.title
        let worker = Task.detached(priority: .userInitiated) { try FileAnalysisContext.collect(for: item) }
        task = Task { [weak self] in
            do {
                let context = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.task = nil; self.preparingAnalysis = nil
                self.send(display: FileAnalysisPrompt.displayMessage(for: item, context: context),
                          content: FileAnalysisPrompt.userMessage(for: item, context: context))
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.busy = false; self.task = nil; self.preparingAnalysis = nil
            }
        }
    }
    func sendInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        guard text.count <= 8_000 else { error = "一次提问最多 8,000 字，请缩小问题范围。"; return }
        guard configured else { showSettings = true; return }
        input = ""; send(display: text, content: text)
    }
    private func send(display: String, content: String) {
        messages.append(AssistantMessage(role: .user, text: display, requestContent: content))
        let turns = messages.filter { !$0.isError && !$0.text.isEmpty }.suffix(16).map {
            AIChatTurn(role: $0.role, content: $0.requestContent ?? $0.text)
        }
        start(turns)
    }
    private func start(_ turns: [AIChatTurn]) {
        stop(); error = nil
        lastRequest = turns; lastResponseID = nil
        let key: String
        do { key = preview ? "" : try AISecretStore.read(configuration) }
        catch { self.error = error.localizedDescription; showSettings = true; return }
        let config = configuration
        let response = AssistantMessage(role: .assistant, text: "")
        messages.append(response)
        lastResponseID = response.id
        let token = UUID(); generation = token; busy = true
        task = Task { [weak self] in
            do {
                for try await chunk in AIClient().stream(configuration: config, apiKey: key, turns: turns) {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    if let index = self.messages.firstIndex(where: { $0.id == response.id }) { self.messages[index].text += chunk }
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                if let index = self.messages.firstIndex(where: { $0.id == response.id }) { self.messages[index].isError = true }
            }
            guard let self, self.generation == token else { return }
            self.busy = false; self.task = nil
        }
    }
    func retry() {
        guard !busy, !lastRequest.isEmpty else { return }
        messages.removeAll { $0.id == lastResponseID }
        start(lastRequest)
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; preparingAnalysis = nil
        messages.removeAll { $0.role == .assistant && $0.text.isEmpty }
    }
    func clear() {
        stop(); messages.removeAll(); lastRequest.removeAll(); lastResponseID = nil; error = nil
        pendingAnalysis = nil; pendingItem = nil
    }
}
