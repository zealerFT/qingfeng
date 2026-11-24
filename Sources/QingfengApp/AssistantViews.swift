import SwiftUI
import QingfengCore

struct AssistantView: View {
    @ObservedObject var model: AssistantModel
    var collapse: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("清风 AI").font(.system(size: 15, weight: .semibold))
                    Text(model.serviceLabel).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Button { model.showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help("AI 模型设置").disabled(model.busy)
                Button { model.clear() } label: { Image(systemName: "square.and.pencil") }.help("新对话")
                Button(action: collapse) { Image(systemName: "minus") }.help("收起为悬浮图标")
            }.buttonStyle(.plain).padding(18).background(Theme.sidebar)
            if model.showSettings {
                AISettingsView(model: model)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if model.messages.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 32)).foregroundStyle(Theme.accent)
                                    Text("这个文件，可以清理吗？").font(.system(size: 21, weight: .semibold))
                                    Text("在清理项目、大文件或重要数据中右键，选择「发送给 AI 分析」，会直接开始分析，无需再按发送。")
                                        .font(.system(size: 13)).lineSpacing(5)
                                    Text("结合文件用途、删除影响和恢复成本，先看建议，再由你决定。")
                                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                    if !model.configured {
                                        Button("配置模型服务") { model.showSettings = true }.buttonStyle(PrimaryButton())
                                    }
                                }.padding(12)
                            }
                            ForEach(model.messages) { message in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(message.role == .user ? "你" : "清风 AI").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                                    if message.text.isEmpty && model.busy {
                                        HStack { ProgressView().controlSize(.small); Text("正在分析…").font(.system(size: 12)) }
                                    } else {
                                        Text(.init(message.text)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(message.role == .user ? Theme.pale : .white, in: RoundedRectangle(cornerRadius: 12))
                            }
                            if let error = model.error {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.amber)
                                    HStack {
                                        Button("重试") { model.retry() }.disabled(model.busy)
                                        Button("检查配置") { model.showSettings = true }.disabled(model.busy)
                                    }.font(.system(size: 12))
                                }.padding(12)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(16)
                    }
                    .onChange(of: model.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: model.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    TextField("询问文件用途或清理建议…", text: $model.input, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5)
                        .onSubmit { model.sendInput() }
                    HStack {
                        Text("只发送提问和所选元数据，不上传文件正文。")
                            .font(.system(size: 9)).foregroundStyle(Theme.muted)
                        Spacer()
                        if model.busy {
                            Button("停止") { model.stop() }.buttonStyle(QuietButton())
                        } else {
                            Button { model.sendInput() } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(PrimaryButton()).disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .keyboardShortcut(.return, modifiers: .command).help("发送（⌘↩）")
                        }
                    }
                }.padding(16).background(.white)
            }
        }.background(Theme.background).foregroundStyle(Theme.ink).tint(Theme.accent)
            .preferredColorScheme(.light).clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(minWidth: 420, minHeight: 480)
    }
}

private struct AIPreset: Identifiable {
    let id: String
    let provider: AIProvider
    let base: String
    static let all: [AIPreset] = [
        .init(id: "OpenAI", provider: .openAICompatible, base: "https://api.openai.com/v1"),
        .init(id: "DeepSeek", provider: .openAICompatible, base: "https://api.deepseek.com/v1"),
        .init(id: "通义千问", provider: .openAICompatible, base: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        .init(id: "硅基流动", provider: .openAICompatible, base: "https://api.siliconflow.cn/v1"),
        .init(id: "Moonshot / Kimi", provider: .openAICompatible, base: "https://api.moonshot.cn/v1"),
        .init(id: "Claude", provider: .anthropic, base: "https://api.anthropic.com"),
        .init(id: "Gemini", provider: .gemini, base: "https://generativelanguage.googleapis.com/v1beta"),
        .init(id: "Ollama（本机）", provider: .ollama, base: "http://localhost:11434"),
        .init(id: "LM Studio（本机）", provider: .openAICompatible, base: "http://localhost:1234/v1")
    ]
}

struct AISettingsView: View {
    @ObservedObject var model: AssistantModel
    @State private var draft = AIConfiguration()
    @State private var key = ""
    @State private var preset = "自定义"
    @State private var message: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var keyLoaded = true
    @State private var credentialScope = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text("模型服务").font(.system(size: 20, weight: .semibold))
                Picker("快速填写", selection: $preset) {
                    Text("自定义").tag("自定义")
                    ForEach(AIPreset.all) { Text($0.id).tag($0.id) }
                }.onChange(of: preset) { _, value in
                    guard let selected = AIPreset.all.first(where: { $0.id == value }) else { return }
                    draft = AIConfiguration(provider: selected.provider, baseURL: selected.base)
                    loadKey()
                }
                Picker("接口协议", selection: $draft.provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("服务地址").font(.system(size: 12, weight: .medium))
                    TextField("https://…/v1", text: $draft.baseURL).textFieldStyle(.roundedBorder)
                    Text("兼容接口填写 API Base URL；可使用自己的网关。本机服务支持 HTTP。")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("模型 ID").font(.system(size: 12, weight: .medium))
                    TextField("填写服务控制台或本机已安装的模型 ID", text: $draft.model).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key").font(.system(size: 12, weight: .medium))
                    SecureField("本机无鉴权服务可留空", text: $key).textFieldStyle(.roundedBorder)
                    Text("密钥保存在 macOS 钥匙串。留空并保存会移除该地址的已存密钥。")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    Button("读取此地址已保存的密钥") { loadKey() }.font(.system(size: 11))
                }
                Toggle("显示可拖动的桌面悬浮图标", isOn: $model.floatingIconEnabled).font(.system(size: 12))
                Text("主动发送时，提问及所选文件的名称、路径（主目录显示为 ~）、类型、大小和时间会发给上述服务。文件正文与整盘扫描报告不会发送；AI 建议不会自动执行清理。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                if let pending = model.pendingAnalysis {
                    Text("保存后自动开始：\(pending)").font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Theme.amber).textSelection(.enabled) }
                HStack {
                    Button(testing ? "取消测试" : "测试连接") {
                        if testing { testTask?.cancel(); testing = false }
                        else { testConnection() }
                    }.buttonStyle(QuietButton())
                    Spacer()
                    Button("返回") { model.showSettings = false }.buttonStyle(QuietButton())
                    Button(model.pendingAnalysis == nil ? "保存" : "保存并分析") {
                        do {
                            draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
                            try model.save(draft, key: key)
                        } catch { message = error.localizedDescription }
                    }.buttonStyle(PrimaryButton()).disabled(testing || !keyLoaded)
                }
            }.padding(22).font(.system(size: 12))
        }
        .onAppear { draft = model.configuration; loadKey() }
        .onChange(of: draft.credentialAccount) { _, account in
            guard credentialScope != account else { return }
            credentialScope = account; key = ""; keyLoaded = true; message = nil
        }
        .onDisappear { testTask?.cancel() }
    }
    private func loadKey() {
        credentialScope = draft.credentialAccount
        if model.isPreview { key = ""; keyLoaded = true; return }
        do { key = try AISecretStore.read(draft); keyLoaded = true; message = nil }
        catch { keyLoaded = false; message = error.localizedDescription }
    }
    private func testConnection() {
        testing = true; message = nil
        let config = draft; let secret = key
        testTask = Task {
            do {
                var reply = ""
                for try await chunk in AIClient().stream(configuration: config, apiKey: secret,
                                                         turns: [AIChatTurn(role: .user, content: "连接测试，请只回复：连接成功。")]) {
                    try Task.checkCancellation()
                    reply += chunk
                }
                if !Task.isCancelled { message = "已收到模型回复：\(String(reply.prefix(120)))" }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
            testing = false
        }
    }
}
