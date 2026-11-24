import Foundation

public final class DiskScanner: @unchecked Sendable {
    public let policy: SafetyPolicy
    private let fm = FileManager.default
    private let flag: CancellationFlag
    private let progress: @Sendable (String) -> Void
    private var issues: [ScanIssue] = []
    public let directoryLimit: Int
    public let largeMinimum: Int64
    public let inventoryLimit: Int
    public var scanIssues: [ScanIssue] { issues }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                cancellation: CancellationFlag = CancellationFlag(),
                directoryLimit: Int = ScanLimit.defaultDirectory,
                largeMinimum: Int64 = 50_000_000, inventoryLimit: Int = 2_000_000,
                progress: @escaping @Sendable (String) -> Void = { _ in }) {
        policy = SafetyPolicy(home: home); flag = cancellation
        self.directoryLimit = ScanLimit.normalizedDirectory(directoryLimit)
        self.largeMinimum = max(1, largeMinimum)
        self.inventoryLimit = max(1, inventoryLimit)
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
            let big = largeFiles(roots: defaultLargeRoots)
            report.items.append(contentsOf: big.items)
            report.largeFileSummary = big.largeFileSummary
        }
        report.items.sort { $0.bytes > $1.bytes }
        report.issues = issues
        report.cancelled = flag.isCancelled
        return report
    }

    public var defaultLargeRoots: [URL] {
        // Test scanners with an isolated home never enumerate the real Applications directory.
        policy.home.path == fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
            ? [policy.home, URL(fileURLWithPath: "/Applications")] : [policy.home]
    }

    public func largeFiles(roots: [URL], minimum: Int64? = nil, entryLimit: Int? = nil,
                           resultLimit: Int = 20_000) -> ScanReport {
        var report = ScanReport()
        let issueStart = issues.count
        let threshold = max(1, minimum ?? largeMinimum)
        let limit = max(1, entryLimit ?? inventoryLimit)
        let maxResults = max(1, resultLimit)
        let candidates = Array(Set(roots.map { $0.standardizedFileURL.path })).sorted { $0.count < $1.count }
        var paths: [String] = []
        for path in candidates where !paths.contains(where: { SafetyPolicy.isWithin(path, $0) }) { paths.append(path) }
        var summary = LargeFileSummary(roots: paths, minimumBytes: threshold)
        let keys: Set<URLResourceKey> = [.isPackageKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .contentAccessDateKey]
        // Visit the usual personal/model locations before potentially huge source trees.
        // The remaining home is still scanned, excluding only roots already visited.
        let priorityDirectories = [".ollama/models", ".lmstudio/models", ".cache/huggingface",
                                   "Models", "Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"]
        let traversalPaths = paths.flatMap { path -> [String] in
            guard path == policy.home.path else { return [path] }
            return priorityDirectories.map { policy.url($0).path }.filter {
                fm.fileExists(atPath: $0) && policy.hasSafeAncestry(URL(fileURLWithPath: $0))
            } + [path]
        }
        var visitedRoots = Set<String>()

        func add(_ url: URL, stamp: FileStamp, values: URLResourceValues, package: Bool) {
            var measurement: Measurement
            if package {
                measurement = measure(url, retainEntries: false, limit: directoryLimit)
                if !measurement.complete { summary.unreadableEntries += 1 }
            } else {
                measurement = Measurement(); measurement.bytes = stamp.allocatedBytes; measurement.files = 1
                measurement.newest = Date(timeIntervalSince1970: Double(stamp.modified) + Double(stamp.modifiedNanos) / 1e9)
                measurement.entries[url.path] = stamp
            }
            let logical = package ? measurement.bytes : stamp.size
            guard max(logical, measurement.bytes) >= threshold else { return }
            summary.matchedFiles += 1
            let eligible = !package && policy.allows(url, category: .large)
            report.items.append(ScanItem(path: url.path, title: url.lastPathComponent, category: .large,
                note: eligible ? "个人文件；确认不再需要后，可勾选移入废纸篓" : "仅供查看与 AI 分析；应用、模型目录和受保护位置请通过所属应用管理",
                measurement: measurement, eligible: eligible, suggested: false,
                logicalBytes: logical, lastAccessed: values.contentAccessDate))
            if report.items.count > maxResults * 2 {
                report.items.sort { $0.fileSize > $1.fileSize }
                report.items = Array(report.items.prefix(maxResults))
            }
        }

        for path in traversalPaths {
            if flag.isCancelled || summary.reachedEntryLimit { break }
            if summary.visitedEntries >= limit { summary.reachedEntryLimit = true; break }
            defer { visitedRoots.insert(path) }
            let root = URL(fileURLWithPath: path)
            do {
                let rootStamp = try SafetyPolicy.stamp(root)
                guard !SafetyPolicy.isLink(rootStamp) else { continue }
                let rootValues = try root.resourceValues(forKeys: keys)
                if SafetyPolicy.isRegular(rootStamp) || rootValues.isPackage == true {
                    summary.visitedEntries += 1
                    if !root.lastPathComponent.hasSuffix(".icloud") && (rootValues.isUbiquitousItem != true || rootValues.ubiquitousItemDownloadingStatus == .current
                        || rootValues.ubiquitousItemDownloadingStatus == .downloaded) {
                        add(root, stamp: rootStamp, values: rootValues, package: rootValues.isPackage == true)
                    } else { summary.skippedCloudFiles += 1 }
                    continue
                }
                guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [], options: [], errorHandler: { url, error in
                    summary.unreadableEntries += 1
                    if self.issues.count < 200 { self.issues.append(ScanIssue(path: url.path, error: error)) }
                    return !self.flag.isCancelled
                }) else { continue }
                while let rawURL = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                    let url = rawURL.standardizedFileURL
                    if flag.isCancelled { break }
                    if visitedRoots.contains(url.path) { enumerator.skipDescendants(); continue }
                    if summary.visitedEntries >= limit { summary.reachedEntryLimit = true; break }
                    summary.visitedEntries += 1
                    // Foundation URLs/resource values are released per entry, keeping a home-wide scan bounded.
                    autoreleasepool {
                        do {
                            let stamp = try SafetyPolicy.stamp(url)
                            if SafetyPolicy.isLink(stamp) || stamp.device != rootStamp.device { enumerator.skipDescendants(); return }
                            if url.lastPathComponent.hasSuffix(".icloud") {
                                summary.skippedCloudFiles += 1; enumerator.skipDescendants(); return
                            }
                            let directory = SafetyPolicy.isDirectory(stamp)
                            let package = try directory && rawURL.resourceValues(forKeys: [.isPackageKey]).isPackage == true
                            // Most home entries are small source/dependency files. Only candidates need
                            // cloud status and access dates; ordinary directories need only package status.
                            guard package || (SafetyPolicy.isRegular(stamp) && max(stamp.size, stamp.allocatedBytes) >= threshold) else { return }
                            let values = try rawURL.resourceValues(forKeys: keys)
                            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current
                                && values.ubiquitousItemDownloadingStatus != .downloaded {
                                summary.skippedCloudFiles += 1; enumerator.skipDescendants(); return
                            }
                            if package {
                                enumerator.skipDescendants()
                                add(url, stamp: stamp, values: values, package: true)
                            } else {
                                add(url, stamp: stamp, values: values, package: false)
                            }
                        } catch {
                            summary.unreadableEntries += 1
                            if issues.count < 200 { issues.append(ScanIssue(path: url.path, error: error)) }
                        }
                    }
                    if summary.visitedEntries % 5_000 == 0 {
                        progress("查找大文件 · 已检查 \(summary.visitedEntries.formatted()) 项 · 找到 \(summary.matchedFiles.formatted()) 个")
                    }
                }
            } catch {
                summary.unreadableEntries += 1
                if issues.count < 200 { issues.append(ScanIssue(path: path, error: error)) }
            }
        }
        report.items.sort { $0.fileSize > $1.fileSize }
        summary.reachedResultLimit = summary.matchedFiles > maxResults
        report.items = Array(report.items.prefix(maxResults))
        if summary.reachedEntryLimit {
            issues.append(ScanIssue(path: paths.first ?? "", message: "大文件扫描达到 \(limit.formatted()) 项上限；结果不完整。可在设置提高大文件扫描上限，或选择文件夹单独扫描。", kind: .limit))
        }
        if summary.reachedResultLimit {
            issues.append(ScanIssue(path: paths.first ?? "", message: "找到 \(summary.matchedFiles.formatted()) 项，当前保留最大的 \(maxResults.formatted()) 项；请选择更小的文件夹进一步查看。", kind: .limit))
        }
        summary.cancelled = flag.isCancelled
        report.issues = Array(issues.dropFirst(issueStart))
        summary.issueIDs = report.issues.map(\.id)
        report.largeFileSummary = summary
        report.cancelled = flag.isCancelled
        return report
    }
}
