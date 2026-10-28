import Foundation

public final class DiskScanner: @unchecked Sendable {
    public let policy: SafetyPolicy
    private let fm = FileManager.default
    private let flag: CancellationFlag
    private let progress: @Sendable (String) -> Void
    private var issues: [ScanIssue] = []
    public let directoryLimit: Int
    public var scanIssues: [ScanIssue] { issues }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                cancellation: CancellationFlag = CancellationFlag(),
                directoryLimit: Int = ScanLimit.defaultDirectory,
                progress: @escaping @Sendable (String) -> Void = { _ in }) {
        policy = SafetyPolicy(home: home); flag = cancellation
        self.directoryLimit = ScanLimit.normalizedDirectory(directoryLimit)
        self.progress = progress
    }

    public func measure(_ root: URL, retainEntries: Bool = true, limit: Int = 300_000) -> Measurement {
        var result = Measurement()
        var stack = [root]
        var visited: Set<String> = []
        var count = 0
        var reachedLimit = false
        let rootDevice = (try? SafetyPolicy.stamp(root))?.device
        while let current = stack.popLast() {
            if flag.isCancelled { result.complete = false; break }
            if count >= limit { result.complete = false; reachedLimit = true; break }
            count += 1
            do {
                let s = try SafetyPolicy.stamp(current)
                if SafetyPolicy.isLink(s) || (!SafetyPolicy.isDirectory(s) && !SafetyPolicy.isRegular(s)) || s.device != rootDevice {
                    result.unsafeEntries = true
                    continue
                }
                let date = Date(timeIntervalSince1970: Double(s.modified) + Double(s.modifiedNanos) / 1e9)
                result.newest = max(result.newest, date)
                if retainEntries { result.entries[current.path] = s }
                let inodeKey = "\(s.device):\(s.inode)"
                if visited.insert(inodeKey).inserted { result.bytes += s.allocatedBytes }
                if SafetyPolicy.isDirectory(s) {
                    let children = try fm.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
                    stack.append(contentsOf: children)
                } else { result.files += 1 }
                if count % 10_000 == 0 { progress("正在统计 \(root.lastPathComponent) · \(count.formatted()) 项") }
            } catch {
                result.complete = false
                if issues.count < 200 { issues.append(ScanIssue(path: current.path, error: error)) }
            }
        }
        if reachedLimit {
            issues.append(ScanIssue(path: root.path, message: "此目录超过 \(limit.formatted()) 项扫描上限；已统计的占用仅供参考，该项暂不可清理。其他完整扫描的项目不受影响，修改权限不会解除此上限。", kind: .limit))
        }
        return result
    }

    private func children(_ root: URL) -> [URL] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard policy.hasSafeAncestry(root) else {
            issues.append(ScanIssue(path: root.path, message: "跳过符号链接或用户目录外的位置。", kind: .safety)); return []
        }
        do { return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.path < $1.path } }
        catch { issues.append(ScanIssue(path: root.path, error: error)); return [] }
    }

    public func scan() -> ScanReport {
        var report = ScanReport()
        func append(_ url: URL, title: String? = nil, category: ScanCategory, note: String) {
            guard !flag.isCancelled, fm.fileExists(atPath: url.path), policy.hasSafeAncestry(url) else { return }
            progress(title ?? url.lastPathComponent)
            let issueStart = issues.count
            let m = measure(url, retainEntries: category != .protected && category != .large, limit: directoryLimit)
            guard m.bytes > 0 else { return }
            let aged = Date().timeIntervalSince(m.newest) >= 7 * 86400
            let oldLog = category != .logs || Date().timeIntervalSince(m.newest) >= 30 * 86400
            let eligible = policy.allows(url, category: category) && m.complete && !m.unsafeEntries && oldLog
            let incompleteReason: String
            let itemIssues = issues.dropFirst(issueStart)
            if itemIssues.contains(where: { $0.category == .limit }) {
                incompleteReason = "达到扫描上限；该项仅供查看，与磁盘权限无关"
            } else if itemIssues.contains(where: { $0.category == .permission }) {
                incompleteReason = "部分路径访问被拒绝；该项仅供查看"
            } else if itemIssues.contains(where: { $0.category == .changed }) {
                incompleteReason = "扫描时文件已变化；请退出对应应用后重新扫描"
            } else { incompleteReason = "扫描未完成；仅展示已统计占用" }
            let warning: String = !m.complete ? incompleteReason :
                m.unsafeEntries && category != .protected ? "含链接或特殊文件；仅供查看" :
                category == .logs && !oldLog ? "含最近 30 天的日志；保留供排查问题" : note
            report.items.append(ScanItem(path: url.path, title: title ?? url.lastPathComponent,
                                        category: category, note: warning, measurement: m,
                                        eligible: eligible, suggested: eligible && aged))
        }
        let devSet = Set(SafetyPolicy.developerPaths.map { policy.url($0.0).path })
        for url in children(policy.url("Library/Caches")) {
            if flag.isCancelled { break }
            guard !devSet.contains(url.path), policy.allows(url, category: .cache) else { continue }
            append(url, category: .cache, note: "可重新生成；清理前退出相关应用")
        }
        for (path, name) in SafetyPolicy.developerPaths {
            if flag.isCancelled { break }
            append(policy.url(path), title: name, category: .developer,
                   note: "清理前停止相关构建；下次使用会重新下载或编译")
        }
        for version in children(policy.url("Library/Caches/JetBrains")) {
            if flag.isCancelled { break }
            for name in SafetyPolicy.jetBrainsSafeNames.sorted() {
                append(version.appendingPathComponent(name), title: "\(version.lastPathComponent) / \(name)",
                       category: .developer, note: "请先退出此 IDE；仅索引/构建缓存，保留 LocalHistory")
            }
            append(version.appendingPathComponent("LocalHistory"), title: "\(version.lastPathComponent) 本地历史",
                   category: .protected, note: "未提交代码可能保存在这里；仅查看，禁止清理")
        }
        for url in children(policy.url("Library/Logs")) {
            if flag.isCancelled { break }
            append(url, category: .logs, note: "整项至少 30 天未更新；清理后无法查看这些诊断日志")
        }
        for url in children(policy.url("Downloads")) {
            if flag.isCancelled { break }
            guard policy.allows(url, category: .installers) else { continue }
            append(url, category: .installers, note: "30 天前的安装包；确认已安装且不再需要")
        }
        let protected: [(String, String, String)] = [
            (".ollama/models", "Ollama 模型", "模型资产；请在 Ollama 中管理"),
            (".cache/huggingface", "Hugging Face 模型", "虽在 .cache 中，仍可能是重要模型资产"),
            (".cache/lm-studio", "LM Studio 数据", "模型与运行数据；请在 LM Studio 中管理"),
            (".lmstudio/models", "LM Studio 模型", "模型资产；仅供查看"),
            (".local/share/containers", "Podman 容器与虚拟机", "可能含数据库和持久卷；请在 Podman 中管理"),
            ("Library/Containers/com.docker.docker", "Docker 虚拟机", "可能含数据库和持久卷；请在 Docker 中管理"),
            ("Library/Application Support/MobileSync/Backup", "iPhone / iPad 备份", "设备备份；请在 Finder 中管理"),
            ("Library/Developer/Xcode/Archives", "Xcode 归档", "可能含发布版本和符号文件；仅供查看"),
            ("Library/pnpm/store", "pnpm 共享存储", "与项目链接相关；请使用 pnpm 自身管理")
        ]
        for (path, name, note) in protected {
            if flag.isCancelled { break }
            append(policy.url(path), title: name, category: .protected, note: note)
        }
        if !flag.isCancelled {
            let covered = report.items.filter { $0.category == .installers }.map(\.path)
            let big = largeFiles(roots: ["Downloads", "Desktop", "Documents", "Movies"].map(policy.url))
            report.items.append(contentsOf: big.items.filter { !covered.contains($0.path) })
        }
        report.items.sort { $0.bytes > $1.bytes }
        report.issues = issues
        report.cancelled = flag.isCancelled
        return report
    }

    public func largeFiles(roots: [URL], minimum: Int64 = 200_000_000) -> ScanReport {
        var report = ScanReport()
        var count = 0
        var seen = Set<String>()
        let excluded: Set<String> = ["node_modules", ".git", "Library", ".Trash", ".cache", "Pods"]
        var stack = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        while let url = stack.popLast() {
            if flag.isCancelled { break }
            if count >= 500_000 {
                issues.append(ScanIssue(path: url.path, message: "大文件扫描达到 50 万项上限；请选择更小的文件夹，无需修改磁盘权限。", kind: .limit)); break
            }
            count += 1
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            do {
                let s = try SafetyPolicy.stamp(url)
                if SafetyPolicy.isLink(s) { continue }
                let values = try url.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey])
                if values.isUbiquitousItem == true || url.lastPathComponent.hasSuffix(".icloud") { continue }
                if SafetyPolicy.isDirectory(s) {
                    if excluded.contains(url.lastPathComponent) || values.isPackage == true || url.lastPathComponent.hasPrefix(".") { continue }
                    stack.append(contentsOf: try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
                } else if SafetyPolicy.isRegular(s) && s.allocatedBytes >= minimum {
                    var m = Measurement(); m.bytes = s.allocatedBytes; m.files = 1
                    m.newest = Date(timeIntervalSince1970: Double(s.modified))
                    report.items.append(ScanItem(path: url.path, title: url.lastPathComponent, category: .large,
                                                note: "个人文件；在 Finder 中确认用途后自行管理", measurement: m,
                                                eligible: false, suggested: false))
                    if report.items.count > 400 { report.items.sort { $0.bytes > $1.bytes }; report.items = Array(report.items.prefix(200)) }
                }
                if count % 3000 == 0 { progress("查找大文件 · \(count.formatted()) 项") }
            } catch {
                if issues.count < 200 { issues.append(ScanIssue(path: url.path, error: error)) }
            }
        }
        report.items.sort { $0.bytes > $1.bytes }
        report.items = Array(report.items.prefix(200))
        report.issues = issues; report.cancelled = flag.isCancelled
        return report
    }
}
