import Foundation
import Darwin

/// Evidence collected only for the selected item. The selected file body is never opened.
public struct FileAnalysisContext: Encodable, Sendable {
    public var storage: StorageContext
    public var ollama: OllamaBlobContext?

    public struct StorageContext: Encodable, Sendable {
        public var root: String?
        public var relativePath: String?
        public var ownerHint: String
        public var purpose: String
        public var basis = "directory_layout_only"
    }
    public struct ManifestReference: Encodable, Sendable {
        public var model: String
        public var manifestPath: String
        public var role: String
        public var mediaType: String
        public var declaredBytes: Int64?
    }
    public struct OllamaBlobContext: Encodable, Sendable {
        public var digest: String
        public var indexPath: String
        public var status = "unavailable"
        public var limitations: [String] = []
        public var manifestsRead = 0
        public var matchingManifests = 0
        public var references: [ManifestReference] = []
        public var referencesTruncated = false
        public let scope = "仅核对同一存储目录的本地 manifests 索引；未检查运行任务、其他存储目录、远端可下载性或备份。零匹配不证明无引用或可删除。"
    }
    public struct Limits: Sendable {
        public var entries = 4_096
        public var manifestBytes = 262_144
        public var totalBytes = 8_388_608
        public var references = 128
        public var seconds: TimeInterval = 2
        public init() {}
    }

    public static func redactedPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = home.standardizedFileURL.path
        return SafetyPolicy.isWithin(path, root) ? "~" + String(path.dropFirst(root.count)) : path
    }

    public static func location(for item: ScanItem, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let url = item.url.standardizedFileURL
        func storage(_ root: URL, _ owner: String, _ purpose: String) -> Self {
            Self(storage: StorageContext(root: redactedPath(root, home: home),
                relativePath: String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                ownerHint: owner, purpose: purpose))
        }
        if blobDigest(url) != nil {
            return storage(url.deletingLastPathComponent().deletingLastPathComponent(), "Ollama（待索引核验）",
                           "符合 blobs/sha256-* 内容寻址布局；可能是模型权重、配置或其他模型层，哈希本身不能说明用途。")
        }
        let locations = [
            (".ollama/models", "Ollama", "本地模型存储；权重、配置与索引需要保持一致。"),
            (".cache/huggingface", "Hugging Face", "模型或数据集缓存；blobs 与 snapshots 可能共享内容，不能视为普通临时文件。"),
            (".lmstudio/models", "LM Studio", "下载或导入的本地模型，可能包含同组分片。"),
            ("Library/Developer/Xcode/DerivedData", "Xcode", "项目编译产物与索引，清理后可能需要重新编译。"),
            ("Library/Application Support", "由路径中的应用目录推断", "应用持久数据；可能含数据库、用户配置或下载资源。"),
            ("Library/Containers", "由路径中的容器标识推断", "沙盒应用数据；可能包含用户文档与数据库。"),
            ("Library/Group Containers", "由路径中的容器标识推断", "多个应用共享的持久数据。"),
            ("Library/Caches", "由路径中的应用目录推断", "应用缓存位置；仍需区分索引、模型和恢复成本，不能仅凭目录名判断可删。"),
            ("Library/Logs", "由路径中的应用目录推断", "应用日志，清理可能影响故障排查。")
        ]
        for (path, owner, purpose) in locations {
            let root = home.appendingPathComponent(path).standardizedFileURL
            if SafetyPolicy.isWithin(url.path, root.path) { return storage(root, owner, purpose) }
        }
        return Self(storage: StorageContext(ownerHint: "未确定", purpose: "结合完整目录层级、文件类型与扫描说明判断；尚无应用归属或依赖关系证据。"))
    }

    /// Run off the main actor. Bounded, cancellable reads of small manifest JSON files only.
    public static func collect(for item: ScanItem, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               limits: Limits = Limits()) throws -> Self {
        try Task.checkCancellation()
        var context = location(for: item, home: home)
        let url = item.url.standardizedFileURL
        guard let digest = blobDigest(url) else { return context }
        let index = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("manifests")
        var evidence = OllamaBlobContext(digest: digest, indexPath: redactedPath(index, home: home))
        // Reject links along the selected path and index path, including custom model stores.
        guard hasPlainAncestry(url), hasPlainAncestry(index),
              let stamp = try? SafetyPolicy.stamp(index), SafetyPolicy.isDirectory(stamp) else {
            evidence.limitations = ["索引或选中路径不存在、不可访问或含符号链接；未核验引用。"]
            context.ollama = evidence; return context
        }
        var issues = Set<String>()
        let fm = FileManager.default
        guard let entries = fm.enumerator(at: index, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
                                         errorHandler: { _, _ in issues.insert("部分索引目录不可读取。"); return true }) else {
            evidence.limitations = ["无法遍历本地模型索引。"]
            context.ollama = evidence; return context
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, limits.seconds)
        var visited = 0, bytesRead = 0
        while let rawEntry = entries.nextObject() as? URL {
            try Task.checkCancellation()
            guard visited < max(0, limits.entries), ProcessInfo.processInfo.systemUptime < deadline else {
                issues.insert("达到索引条目或时间上限，引用列表可能不完整。"); break
            }
            visited += 1
            let entry = rawEntry.standardizedFileURL
            guard SafetyPolicy.isWithin(entry.path, index.path), entry.path != index.path else {
                entries.skipDescendants(); issues.insert("索引路径无法对应到当前模型存储。"); continue
            }
            let relative = String(entry.path.dropFirst(index.path.count + 1))
            let parts = relative.split(separator: "/").map(String.init)
            guard parts.count <= 12 else { entries.skipDescendants(); issues.insert("索引层级超出读取范围。"); continue }
            guard let stamp = try? SafetyPolicy.stamp(entry), !SafetyPolicy.isLink(stamp) else {
                entries.skipDescendants(); issues.insert("跳过不可访问项或符号链接。"); continue
            }
            if SafetyPolicy.isDirectory(stamp) { continue }
            guard SafetyPolicy.isRegular(stamp), parts.count >= 3, hasPlainAncestry(entry) else {
                issues.insert("存在非标准索引项，未用于判断。"); continue
            }
            let remaining = max(0, limits.totalBytes - bytesRead)
            guard remaining > 0 else { issues.insert("达到索引总读取上限。"); break }
            guard let data = readManifest(entry, maxBytes: min(max(0, limits.manifestBytes), remaining)) else {
                issues.insert("部分索引无法读取或超过大小上限。"); continue
            }
            bytesRead += data.count
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  json["schemaVersion"] as? Int == 2,
                  let config = json["config"] as? [String: Any], let layers = json["layers"] as? [[String: Any]],
                  ([config] + layers).allSatisfy({ $0["digest"] is String && $0["mediaType"] is String }) else {
                issues.insert("部分模型索引格式无效或不受支持。"); continue
            }
            evidence.manifestsRead += 1
            let matches = [("config", config)] + layers.map { ("layer", $0) }
            let matching = matches.filter { $0.1["digest"] as? String == digest }
            guard !matching.isEmpty else { continue }
            evidence.matchingManifests += 1
            let repository = parts.dropFirst().dropLast().joined(separator: "/")
            let model = parts[0] == "registry.ollama.ai" && repository.hasPrefix("library/")
                ? String(repository.dropFirst("library/".count)) + ":" + parts.last!
                : parts[0] + "/" + repository + ":" + parts.last!
            for (role, layer) in matching {
                guard evidence.references.count < max(0, limits.references) else { evidence.referencesTruncated = true; continue }
                evidence.references.append(ManifestReference(model: model, manifestPath: redactedPath(entry, home: home),
                    role: role, mediaType: layer["mediaType"] as! String, declaredBytes: (layer["size"] as? NSNumber)?.int64Value))
            }
        }
        try Task.checkCancellation()
        evidence.references.sort { ($0.model, $0.role) < ($1.model, $1.role) }
        evidence.status = issues.isEmpty ? "complete" : "partial"
        evidence.limitations = issues.sorted()
        if evidence.matchingManifests > 0 {
            context.storage.ownerHint = "Ollama"
            context.storage.basis = "directory_layout_and_exact_local_manifest_digest_match"
            context.storage.purpose = "Ollama 内容寻址模型层；具体用途以匹配的 role 和 mediaType 为证据，多个模型标签可能共享此文件。"
        }
        context.ollama = evidence
        return context
    }

    private static func blobDigest(_ url: URL) -> String? {
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().lastPathComponent == "blobs", name.hasPrefix("sha256-") else { return nil }
        let hash = name.dropFirst(7)
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return "sha256:" + hash
    }
    private static func hasPlainAncestry(_ url: URL) -> Bool {
        var cursor = url
        // Foundation can spell macOS's /private/var as /var even after resolving.
        // Accept only these verified OS aliases; user-created links still stop the lookup.
        for alias in ["var", "tmp", "etc"] where SafetyPolicy.isWithin(cursor.path, "/" + alias) {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/" + alias),
               target == "private/" + alias || target == "/private/" + alias {
                cursor = URL(fileURLWithPath: "/private" + cursor.path)
            }
        }
        while cursor.path != "/" {
            guard let stamp = try? SafetyPolicy.stamp(cursor), !SafetyPolicy.isLink(stamp) else { return false }
            cursor.deleteLastPathComponent()
        }
        return true
    }
    private static func readManifest(_ url: URL, maxBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maxBytes,
              let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return data
    }
}
