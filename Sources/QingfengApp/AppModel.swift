import SwiftUI
import AppKit
import QingfengCore

enum Page: String, CaseIterable, Identifiable {
    case overview = "空间总览", clean = "清理项目", large = "大文件", protected = "重要数据", history = "操作记录"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .clean: return "sparkles"
        case .large: return "doc.text.magnifyingglass"
        case .protected: return "lock.shield"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

final class HistoryStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/清风/history.json")
    }
    func load() -> [CleanupEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CleanupEntry].self, from: data)) ?? []
    }
    func append(_ entry: CleanupEntry) throws {
        lock.lock(); defer { lock.unlock() }
        var all: [CleanupEntry] = []
        if FileManager.default.fileExists(atPath: url.path) {
            all = try JSONDecoder().decode([CleanupEntry].self, from: Data(contentsOf: url))
        }
        all.insert(entry, at: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Array(all.prefix(2000)))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var page: Page = .overview {
        didSet { if page != oldValue { selected.removeAll() } }
    }
    @Published var report: ScanReport?
    @Published var hasCleanupScan = false
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var cleaning = false
    @Published var cancelling = false
    @Published var status = "准备好，为 Mac 腾出空间"
    @Published var search = ""
    @Published var filter: ScanCategory?
    @Published var fileKind: FileKind?
    @Published var largeSort: LargeFileSort = .logical
    @Published var total: Int64 = 0
    @Published var available: Int64 = 0
    @Published var free: Int64 = 0
    @Published var includesReclaimable = false
    @Published var history: [CleanupEntry] = []
    @Published var showConfirmation = false
    @Published var showIssues = false
    @Published var showSettings = false
    @Published var notice: String?
    @Published var acknowledged = false
    @Published var directoryLimit: Int
    @Published var limitText: String
    @Published var largeMinimumMB: Int
    @Published var minimumText: String
    @Published var inventoryLimit: Int
    @Published var inventoryLimitText: String
    let assistant: AssistantModel
    let isPreview: Bool
    private var cancellation = CancellationFlag()
    private let store = HistoryStore()
    private static let directoryLimitKey = "Qingfeng.directoryScanLimit"
    init(preview: Bool = false) {
        isPreview = preview; assistant = AssistantModel(preview: preview)
        let saved = UserDefaults.standard.integer(forKey: Self.directoryLimitKey)
        let limit = saved == 0 ? ScanLimit.defaultDirectory : ScanLimit.normalizedDirectory(saved)
        directoryLimit = limit
        limitText = limit.formatted()
        let savedMinimum = UserDefaults.standard.integer(forKey: "Qingfeng.largeFileMinimumMB")
        let minimum = savedMinimum > 0 ? min(savedMinimum, 10_000) : 50
        largeMinimumMB = minimum; minimumText = String(minimum)
        let savedInventory = UserDefaults.standard.integer(forKey: "Qingfeng.largeScanLimit")
        let inventory = savedInventory > 0 ? min(max(savedInventory, 10_000), 10_000_000) : 2_000_000
        inventoryLimit = inventory; inventoryLimitText = inventory.formatted()
        if !preview { refreshDisk(); history = store.load() }
    }

    var items: [ScanItem] { report?.items ?? [] }
    var cleanable: [ScanItem] { items.filter { $0.eligible && $0.category != .large } }
    var selectedItems: [ScanItem] { items.filter { selected.contains($0.id) && canSelect($0) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var cleanableBytes: Int64 { cleanable.reduce(0) { $0 + $1.bytes } }
    var diskSpace: DiskSpaceBreakdown {
        DiskSpaceBreakdown(total: total, available: available, cleanup: hasCleanupScan ? cleanableBytes : nil, free: free)
    }
    var visibleItems: [ScanItem] {
        let filtered = items.filter { item in
            let match: Bool
            switch page {
            case .clean: match = [.cache, .developer, .logs, .installers].contains(item.category) && (filter == nil || filter == item.category)
            case .large: match = item.category == .large && (fileKind == nil || item.fileKind == fileKind)
            case .protected: match = item.category == .protected
            default: match = true
            }
            return match && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.path.localizedCaseInsensitiveContains(search))
        }
        guard page == .large else { return filtered }
        return filtered.sorted {
            switch largeSort {
            case .logical: return $0.fileSize == $1.fileSize ? $0.path < $1.path : $0.fileSize > $1.fileSize
            case .allocated: return $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
            case .accessed: return ($0.lastAccessed ?? .distantPast) > ($1.lastAccessed ?? .distantPast)
            }
        }
    }

    func refreshDisk() {
        if let capacity = try? VolumeCapacity.read(at: FileManager.default.homeDirectoryForCurrentUser) {
            total = capacity.total; available = capacity.available; free = capacity.free
            includesReclaimable = capacity.includesReclaimable
        }
    }

    func openAssistant() { assistant.conversationVisible = true }
    func analyze(_ item: ScanItem) {
        openAssistant()
        assistant.analyze(item)
    }

    func scan(folder: URL? = nil) {
        guard !busy else { return }
        busy = true; cleaning = false; cancelling = false; selected.removeAll()
        cancellation = CancellationFlag()
        let flag = cancellation
        let limit = directoryLimit
        let minimum = Int64(largeMinimumMB) * 1_000_000
        let inventory = inventoryLimit
        let largeOnly = folder != nil || page == .large
        status = largeOnly ? "正在查找大文件…" : "正在分析本机空间…"
        let model = self
        Task.detached(priority: .utility) {
            let scanner = DiskScanner(cancellation: flag, directoryLimit: limit, largeMinimum: minimum, inventoryLimit: inventory) { message in
                Task { @MainActor in if model.busy && !model.cancelling { model.status = message } }
            }
            let result = largeOnly ? scanner.largeFiles(roots: folder.map { [$0] } ?? scanner.defaultLargeRoots) : scanner.scan()
            await model.finishScan(result, customFolder: largeOnly)
        }
    }
    private func finishScan(_ result: ScanReport, customFolder: Bool) {
        if customFolder {
            var merged = report ?? ScanReport()
            let oldInventoryIssues = Set(merged.largeFileSummary?.issueIDs ?? [])
            var seenIssues = Set<String>()
            merged.issues = (merged.issues.filter { !oldInventoryIssues.contains($0.id) } + result.issues)
                .filter { seenIssues.insert($0.id).inserted }
            merged.items.removeAll { $0.category == .large }
            merged.items.append(contentsOf: result.items)
            merged.largeFileSummary = result.largeFileSummary
            merged.date = result.date; merged.cancelled = result.cancelled
            report = merged; page = .large
        } else { report = result; hasCleanupScan = true }
        busy = false; cancelling = false
        status = result.cancelled ? "扫描已停止，显示已完成的结果" : "扫描完成 · \(result.date.formatted(date: .omitted, time: .shortened))"
        refreshDisk()
    }
    func cancel() { cancellation.cancel(); cancelling = true; status = "正在安全停止…" }
    private func canSelect(_ item: ScanItem) -> Bool {
        item.eligible && ((page == .large && item.category == .large)
            || (page == .clean && [.cache, .developer, .logs, .installers].contains(item.category)))
    }
    func toggle(_ item: ScanItem) {
        guard canSelect(item), !busy else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    func selectAllVisible() {
        guard page == .large, !busy else { return }
        selected.formUnion(visibleItems.filter { canSelect($0) }.map(\.id))
    }
    func selectOlder() {
        guard page == .clean, !busy else { return }
        let running = Self.runningApplications()
        selected = Set(visibleItems.filter {
            $0.eligible && $0.suggested && ApplicationUsage.blockingReason(for: $0.path, applications: running) == nil
        }.map(\.id))
    }
    func openFolderPicker() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "扫描此文件夹"
        panel.message = "查找至少 \(largeMinimumMB) MB 的文件，包含隐藏位置与应用包；不下载云端文件。受保护内容可查看和咨询 AI。"
        if panel.runModal() == .OK, let url = panel.url { scan(folder: url) }
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openTrash() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        if !NSWorkspace.shared.open(url) { notice = "未能打开废纸篓，请点击 Dock 中的废纸篓图标。" }
    }
    func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    func openSettings() {
        limitText = directoryLimit.formatted()
        minimumText = String(largeMinimumMB); inventoryLimitText = inventoryLimit.formatted()
        showSettings = true
    }
    func resetSettingsDraft() {
        limitText = ScanLimit.defaultDirectory.formatted(); minimumText = "50"; inventoryLimitText = "2,000,000"
    }
    func applySettings() {
        let sanitized = limitText.filter { $0 != "," && $0 != " " && $0 != "_" }
        guard !sanitized.isEmpty, sanitized.allSatisfy(\.isNumber),
              let value = Int(sanitized), ScanLimit.isValidDirectory(value) else {
            notice = "请输入 \(ScanLimit.minimumDirectory.formatted()) 到 \(ScanLimit.maximumDirectory.formatted()) 之间的整数。"
            return
        }
        guard let minimum = Int(minimumText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)), (1...10_000).contains(minimum),
              let inventory = Int(inventoryLimitText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")),
              (10_000...10_000_000).contains(inventory) else {
            notice = "大文件门槛请输入 1–10,000 MB；大文件扫描上限请输入 10,000–10,000,000 项。"; return
        }
        directoryLimit = value
        largeMinimumMB = minimum; inventoryLimit = inventory
        UserDefaults.standard.set(minimum, forKey: "Qingfeng.largeFileMinimumMB")
        UserDefaults.standard.set(inventory, forKey: "Qingfeng.largeScanLimit")
        limitText = value.formatted()
        UserDefaults.standard.set(value, forKey: Self.directoryLimitKey)
        showSettings = false
        report = nil
        hasCleanupScan = false
        selected.removeAll()
        status = "扫描上限已设置为 \(value.formatted()) 项，正在重新扫描…"
        scan()
    }
    func prepareCleanup() {
        guard !busy, !selectedItems.isEmpty else { return }
        acknowledged = false; showConfirmation = true
    }

    nonisolated static func runningApplications() -> [RunningApplicationInfo] {
        let read: () -> [RunningApplicationInfo] = {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated, let identifier = app.bundleIdentifier else { return nil }
                let bundle = app.bundleURL.flatMap(Bundle.init(url:))
                var selector: String?
                if identifier.lowercased().hasPrefix("com.jetbrains."), let url = app.bundleURL {
                    let infoURL = url.appendingPathComponent("Contents/Resources/product-info.json")
                    if let data = try? Data(contentsOf: infoURL),
                       let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        selector = info["dataDirectoryName"] as? String
                    }
                }
                return RunningApplicationInfo(bundleID: identifier, name: app.localizedName ?? identifier,
                    version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    processID: app.processIdentifier, jetBrainsDirectory: selector)
            }
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }
    nonisolated static func blockingReason(_ item: ScanItem) -> String? {
        ApplicationUsage.blockingReason(for: item.path, applications: runningApplications())
    }

    func performCleanup() {
        let targets = selectedItems
        guard !busy, acknowledged, !targets.isEmpty else { return }
        showConfirmation = false; busy = true; cleaning = true; cancelling = false
        cancellation = CancellationFlag(); let flag = cancellation; let store = store
        let limit = directoryLimit
        Task.detached(priority: .utility) { [weak self] in
            var logError = false
            let entries = Cleaner(directoryLimit: limit).clean(targets, cancellation: flag, blockingReason: Self.blockingReason,
                progress: { message in Task { @MainActor [weak self] in self?.status = "正在复核并移入废纸篓 · \(message)" } },
                onEntry: { entry in do { try store.append(entry) } catch { logError = true } })
            await self?.finishCleanup(entries, logError: logError)
        }
    }
    private func finishCleanup(_ entries: [CleanupEntry], logError: Bool) {
        let moved = Set(entries.filter(\.success).map(\.source))
        report?.items.removeAll { moved.contains($0.path) }
        selected.removeAll(); history = store.load()
        if logError { history.insert(contentsOf: entries.reversed(), at: 0) }
        busy = false; cleaning = false; cancelling = false; refreshDisk()
        let failed = entries.filter { !$0.success }.count
        status = "已移入废纸篓 \(moved.count) 项\(failed > 0 ? "，跳过 \(failed) 项" : "")"
        notice = "\(status)。清空废纸篓后才会真正释放空间；你可先在 Finder 中检查或还原。"
            + (logError ? "\n部分操作记录未能保存，请保留本次窗口中的结果。" : "")
        page = .history
    }

    func exportReport() {
        guard var report else { return }
        // Strip individual filesystem snapshots from exported inventory.
        report.items = report.items.map { item in
            var m = item.measurement; m.entries.removeAll()
            return ScanItem(path: item.path, title: item.title, category: item.category, note: item.note,
                            measurement: m, eligible: item.eligible, suggested: item.suggested,
                            logicalBytes: item.logicalBytes, lastAccessed: item.lastAccessed)
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "清风空间报告.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: url, options: .atomic)
            } catch { notice = "导出失败：\(error.localizedDescription)" }
        }
    }
}
