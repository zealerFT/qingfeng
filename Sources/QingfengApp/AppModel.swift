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
    @Published var page: Page = .overview
    @Published var report: ScanReport?
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var cleaning = false
    @Published var cancelling = false
    @Published var status = "准备好，为 Mac 腾出空间"
    @Published var search = ""
    @Published var filter: ScanCategory?
    @Published var total: Int64 = 0
    @Published var available: Int64 = 0
    @Published var history: [CleanupEntry] = []
    @Published var showConfirmation = false
    @Published var showIssues = false
    @Published var showSettings = false
    @Published var notice: String?
    @Published var acknowledged = false
    @Published var directoryLimit: Int
    @Published var limitText: String
    private var cancellation = CancellationFlag()
    private let store = HistoryStore()
    private static let directoryLimitKey = "Qingfeng.directoryScanLimit"
    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.directoryLimitKey)
        let limit = saved == 0 ? ScanLimit.defaultDirectory : ScanLimit.normalizedDirectory(saved)
        directoryLimit = limit
        limitText = limit.formatted()
        refreshDisk(); history = store.load()
    }

    var items: [ScanItem] { report?.items ?? [] }
    var cleanable: [ScanItem] { items.filter(\.eligible) }
    var selectedItems: [ScanItem] { cleanable.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var cleanableBytes: Int64 { cleanable.reduce(0) { $0 + $1.bytes } }
    var usedFraction: Double { total > 0 ? min(1, max(0, Double(total - available) / Double(total))) : 0 }
    var visibleItems: [ScanItem] {
        items.filter { item in
            let match: Bool
            switch page {
            case .clean: match = [.cache, .developer, .logs, .installers].contains(item.category) && (filter == nil || filter == item.category)
            case .large: match = item.category == .large
            case .protected: match = item.category == .protected
            default: match = true
            }
            return match && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.path.localizedCaseInsensitiveContains(search))
        }
    }

    func refreshDisk() {
        if let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            total = Int64(values.volumeTotalCapacity ?? 0); available = Int64(values.volumeAvailableCapacity ?? 0)
        }
    }

    func scan(folder: URL? = nil) {
        guard !busy else { return }
        busy = true; cleaning = false; cancelling = false; selected.removeAll()
        cancellation = CancellationFlag()
        let flag = cancellation
        let limit = directoryLimit
        status = folder == nil ? "正在分析本机空间…" : "正在查找大文件…"
        let model = self
        Task.detached(priority: .utility) {
            let scanner = DiskScanner(cancellation: flag, directoryLimit: limit) { message in
                Task { @MainActor in if model.busy && !model.cancelling { model.status = message } }
            }
            let result = folder.map { scanner.largeFiles(roots: [$0]) } ?? scanner.scan()
            await model.finishScan(result, customFolder: folder != nil)
        }
    }
    private func finishScan(_ result: ScanReport, customFolder: Bool) {
        if customFolder {
            var merged = report ?? ScanReport()
            let existing = Set(merged.items.filter { $0.category != .large }.map(\.path))
            merged.items.removeAll { $0.category == .large }
            merged.items.append(contentsOf: result.items.filter { !existing.contains($0.path) })
            merged.issues.append(contentsOf: result.issues); merged.date = result.date; merged.cancelled = result.cancelled
            report = merged; page = .large
        } else { report = result }
        busy = false; cancelling = false
        status = result.cancelled ? "扫描已停止，显示已完成的结果" : "扫描完成 · \(result.date.formatted(date: .omitted, time: .shortened))"
        refreshDisk()
    }
    func cancel() { cancellation.cancel(); cancelling = true; status = "正在安全停止…" }
    func toggle(_ item: ScanItem) {
        guard item.eligible, !busy else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    func selectOlder() {
        let running = Self.runningApplications()
        selected = Set(visibleItems.filter {
            $0.eligible && $0.suggested && ApplicationUsage.blockingReason(for: $0.path, applications: running) == nil
        }.map(\.id))
    }
    func openFolderPicker() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "扫描此文件夹"
        panel.message = "只查找占用超过 200 MB 的本地文件，不自动删除，也不下载 iCloud 文件。"
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
        showSettings = true
    }
    func resetSettingsDraft() { limitText = ScanLimit.defaultDirectory.formatted() }
    func applySettings() {
        let sanitized = limitText.filter { $0 != "," && $0 != " " && $0 != "_" }
        guard !sanitized.isEmpty, sanitized.allSatisfy(\.isNumber),
              let value = Int(sanitized), ScanLimit.isValidDirectory(value) else {
            notice = "请输入 \(ScanLimit.minimumDirectory.formatted()) 到 \(ScanLimit.maximumDirectory.formatted()) 之间的整数。"
            return
        }
        directoryLimit = value
        limitText = value.formatted()
        UserDefaults.standard.set(value, forKey: Self.directoryLimitKey)
        showSettings = false
        report = nil
        selected.removeAll()
        status = "扫描上限已设置为 \(value.formatted()) 项，正在重新扫描…"
        scan()
    }
    func prepareCleanup() { acknowledged = false; showConfirmation = true }

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
                            measurement: m, eligible: item.eligible, suggested: item.suggested)
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "清风空间报告.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: url, options: .atomic)
            } catch { notice = "导出失败：\(error.localizedDescription)" }
        }
    }
}
