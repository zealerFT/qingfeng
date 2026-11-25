import AppKit
import SwiftUI
import QingfengCore

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
    @Published private(set) var configurationNotice: String?
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

    init(preview: Bool = false, credentials: AICredentialSession? = nil,
         stream: @escaping (AIConfiguration, String, [AIChatTurn]) -> AsyncThrowingStream<String, Error> = {
             AIClient().stream(configuration: $0, apiKey: $1, turns: $2)
         }) {
        self.preview = preview
        self.credentials = credentials ?? (preview
            ? AICredentialSession(read: { _ in "" }, write: { _, _ in }) : AICredentialSession(store: AISettingsStore()))
        self.stream = stream
        configuration = AIConfiguration()
        floatingIconEnabled = preview ? false : (UserDefaults.standard.object(forKey: "Qingfeng.aiFloatingIcon") as? Bool ?? true)
        do {
            configuration = try self.credentials.configuration()
            configurationNotice = self.credentials.notice(for: configuration)
        } catch { self.error = error.localizedDescription }
    }
    var configured: Bool { (try? configuration.endpoint()) != nil }
    var isPreview: Bool { preview }
    var serviceLabel: String { configured ? "\(configuration.provider.title) · \(configuration.model)" : "配置模型后开始咨询" }

    func save(_ config: AIConfiguration, credential: AICredentialEdit = .unchanged) throws {
        _ = try config.endpoint()
        try credentials.save(credential, for: config)
        configuration = config; showSettings = false; error = nil
        configurationNotice = credentials.notice(for: config)
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
        do { key = try credentials.key(for: configuration) }
        catch { self.error = error.localizedDescription; return }
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
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; busy = false; preparingAnalysis = nil
        messages.removeAll { $0.role == .assistant && $0.text.isEmpty }
    }
    func clear() {
        stop(); messages.removeAll(); lastRequest.removeAll(); lastResponseID = nil; error = nil
        pendingAnalysis = nil; pendingItem = nil
    }
}
