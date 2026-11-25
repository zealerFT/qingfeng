import AppKit
import SwiftUI
import Security
import QingfengCore

@MainActor enum AISecretStore {
    static func query(_ config: AIConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.qingfeng.mac.ai",
         kSecAttrAccount as String: config.credentialAccount]
    }
    // Existing releases use the legacy login keychain. Gate its UI for the entire
    // synchronous read; do not let SecItem's bridge substitute a different UI policy.
    static func withInteraction<T>(allowed: Bool, _ operation: () throws -> T) throws -> T {
        var previous: DarwinBoolean = true
        let status = SecKeychainGetUserInteractionAllowed(&previous)
        guard status == errSecSuccess else { throw error(status) }
        let changed = SecKeychainSetUserInteractionAllowed(allowed)
        guard changed == errSecSuccess else { throw error(changed) }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }

    static func read(_ config: AIConfiguration, allowInteraction: Bool = false, keychain: SecKeychain? = nil) throws -> String {
        var target = keychain
        if target == nil {
            let status = SecKeychainCopyDefault(&target)
            guard status == errSecSuccess else { throw error(status) }
        }
        if !allowInteraction {
            var state: SecKeychainStatus = 0
            let status = SecKeychainGetStatus(target, &state)
            guard status == errSecSuccess else { throw error(status) }
            guard state & SecKeychainStatus(kSecUnlockStateStatus) != 0 else { throw error(errSecInteractionNotAllowed) }
        }
        let service = "local.qingfeng.mac.ai", account = config.credentialAccount
        var length: UInt32 = 0
        var bytes: UnsafeMutableRawPointer?
        let status = try withInteraction(allowed: allowInteraction) {
            SecKeychainFindGenericPassword(target, UInt32(service.utf8.count), service,
                UInt32(account.utf8.count), account, &length, &bytes, nil)
        }
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw error(status) }
        guard let bytes else { return "" }
        defer { SecKeychainItemFreeContent(nil, bytes) }
        return String(decoding: Data(bytes: bytes, count: Int(length)), as: UTF8.self)
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
                userInfo: [NSLocalizedDescriptionKey: "已保存的密钥暂时无法静默读取（\(status)）。点击「授权并发送」可允许 macOS 验证，或在设置中更新密钥。"])
    }
}

enum AICredentialEdit {
    case unchanged, replace(String), remove
}

/// Keep successful reads (including empty local-service keys) for this app run.
/// A denied read is also remembered: only an explicit retry may ask macOS again.
@MainActor final class AICredentialSession {
    private enum Entry { case reading, loaded(String), failed(Error) }
    private var entries: [String: Entry] = [:]
    private let readSecret: @MainActor (AIConfiguration, Bool) throws -> String
    private let writeSecret: @MainActor (String, AIConfiguration) throws -> Void

    init(read: @escaping @MainActor (AIConfiguration, Bool) throws -> String = { try AISecretStore.read($0, allowInteraction: $1) },
         write: @escaping @MainActor (String, AIConfiguration) throws -> Void = AISecretStore.save) {
        readSecret = read; writeSecret = write
    }

    func key(for config: AIConfiguration, allowInteraction: Bool = false) throws -> String {
        let account = config.credentialAccount
        switch entries[account] {
        case .loaded(let key): return key
        case .failed(let error) where !allowInteraction: throw error
        case .reading: throw AIServiceError.configuration("正在读取此服务的密钥，请先完成 macOS 授权。")
        default: break
        }
        entries[account] = .reading
        do {
            let key = try readSecret(config, allowInteraction)
            entries[account] = .loaded(key)
            return key
        } catch {
            entries[account] = .failed(error)
            throw error
        }
    }

    func save(_ edit: AICredentialEdit, for config: AIConfiguration) throws {
        let key: String
        switch edit {
        case .unchanged: return
        case .replace(let value): key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .remove: key = ""
        }
        try writeSecret(key, config)
        entries[config.credentialAccount] = .loaded(key)
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
    @Published var conversationVisible = false
    @Published var error: String?
    @Published private(set) var credentialAccessBlocked = false
    @Published var pendingAnalysis: String?
    @Published var preparingAnalysis: String?
    @Published var floatingIconEnabled: Bool {
        didSet { if !preview { UserDefaults.standard.set(floatingIconEnabled, forKey: "Qingfeng.aiFloatingIcon") } }
    }
    private let preview: Bool
    private let credentials: AICredentialSession
    private let stream: (AIConfiguration, String, [AIChatTurn]) -> AsyncThrowingStream<String, Error>
    private var pendingItem: ScanItem?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastRequest: [AIChatTurn] = []
    private var lastResponseID: UUID?
    private static let settingsKey = "Qingfeng.aiConfiguration"

    init(preview: Bool = false, credentials: AICredentialSession? = nil,
         stream: @escaping (AIConfiguration, String, [AIChatTurn]) -> AsyncThrowingStream<String, Error> = {
             AIClient().stream(configuration: $0, apiKey: $1, turns: $2)
         }) {
        self.preview = preview
        self.credentials = credentials ?? (preview
            ? AICredentialSession(read: { _, _ in "" }, write: { _, _ in }) : AICredentialSession())
        self.stream = stream
        if !preview, let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let config = try? JSONDecoder().decode(AIConfiguration.self, from: data) { configuration = config }
        else { configuration = AIConfiguration() }
        floatingIconEnabled = preview ? false : (UserDefaults.standard.object(forKey: "Qingfeng.aiFloatingIcon") as? Bool ?? true)
    }
    var configured: Bool { (try? configuration.endpoint()) != nil }
    var isPreview: Bool { preview }
    var serviceLabel: String { configured ? "\(configuration.provider.title) · \(configuration.model)" : "配置模型后开始咨询" }

    func save(_ config: AIConfiguration, credential: AICredentialEdit = .unchanged) throws {
        _ = try config.endpoint()
        try credentials.save(credential, for: config)
        if !preview {
            let data = try JSONEncoder().encode(config)
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        configuration = config; showSettings = false; error = nil; credentialAccessBlocked = false
        if let item = pendingItem {
            pendingAnalysis = nil; pendingItem = nil
            analyze(item)
        }
    }
    func keyForConnectionTest(_ config: AIConfiguration, credential: AICredentialEdit) throws -> String {
        switch credential {
        case .unchanged: return try credentials.key(for: config)
        case .replace(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .remove: return ""
        }
    }
    func authorizeCredential(_ config: AIConfiguration) throws {
        _ = try credentials.key(for: config, allowInteraction: true)
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
    private func start(_ turns: [AIChatTurn], allowCredentialInteraction: Bool = false) {
        stop(); error = nil; credentialAccessBlocked = false
        lastRequest = turns; lastResponseID = nil
        let key: String
        do { key = try credentials.key(for: configuration, allowInteraction: allowCredentialInteraction) }
        catch { self.error = error.localizedDescription; credentialAccessBlocked = true; return }
        let config = configuration
        let response = AssistantMessage(role: .assistant, text: "")
        messages.append(response)
        lastResponseID = response.id
        let token = UUID(); generation = token; busy = true
        let stream = self.stream
        task = Task { [weak self] in
            do {
                for try await chunk in stream(config, key, turns) {
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
    func authorizeAndRetry() {
        guard !busy, credentialAccessBlocked, !lastRequest.isEmpty else { return }
        start(lastRequest, allowCredentialInteraction: true)
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; preparingAnalysis = nil
        messages.removeAll { $0.role == .assistant && $0.text.isEmpty }
    }
    func clear() {
        stop(); messages.removeAll(); lastRequest.removeAll(); lastResponseID = nil; error = nil; credentialAccessBlocked = false
        pendingAnalysis = nil; pendingItem = nil
    }
}
