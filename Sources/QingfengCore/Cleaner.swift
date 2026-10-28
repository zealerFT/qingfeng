import Foundation

public enum CleanupError: LocalizedError {
    case forbidden, changed, incomplete, overlap
    case activeApplication(String)
    public var errorDescription: String? {
        switch self {
        case .forbidden: return "此位置不在清理白名单中，或路径包含符号链接。"
        case .changed: return "扫描后内容已变化；已跳过，请重新扫描。"
        case .incomplete: return "扫描不完整或含特殊文件；已跳过。"
        case .overlap: return "所选路径有重复或嵌套，已拒绝本次操作。"
        case .activeApplication(let reason): return reason
        }
    }
}

public final class Cleaner {
    public let policy: SafetyPolicy
    public let directoryLimit: Int
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                directoryLimit: Int = ScanLimit.defaultDirectory) {
        policy = SafetyPolicy(home: home)
        self.directoryLimit = ScanLimit.normalizedDirectory(directoryLimit)
    }

    public func validate(_ item: ScanItem, cancellation: CancellationFlag = CancellationFlag()) throws {
        guard item.eligible, policy.allows(item.url, category: item.category) else { throw CleanupError.forbidden }
        guard item.measurement.complete, !item.measurement.unsafeEntries, !item.measurement.entries.isEmpty else {
            throw CleanupError.incomplete
        }
        let fresh = DiskScanner(home: policy.home, cancellation: cancellation,
                                directoryLimit: directoryLimit).measure(item.url, limit: directoryLimit)
        guard fresh.complete, !fresh.unsafeEntries else { throw CleanupError.incomplete }
        guard fresh == item.measurement else { throw CleanupError.changed }
        if item.category == .logs && Date().timeIntervalSince(fresh.newest) < 30 * 86400 { throw CleanupError.forbidden }
    }

    public func clean(_ items: [ScanItem], cancellation: CancellationFlag = CancellationFlag(),
                      blockingReason: (ScanItem) -> String? = { _ in nil },
                      progress: (String) -> Void = { _ in },
                      onEntry: (CleanupEntry) -> Void = { _ in },
                      trash: (URL) throws -> URL = Cleaner.systemTrash) -> [CleanupEntry] {
        let paths = items.map(\.path)
        let overlapping = paths.enumerated().contains { index, path in
            paths.enumerated().contains { other, candidate in index != other && SafetyPolicy.isWithin(path, candidate) }
        }
        var entries: [CleanupEntry] = []
        for item in items {
            if cancellation.isCancelled { break }
            progress(item.title)
            let entry: CleanupEntry
            do {
                guard !overlapping else { throw CleanupError.overlap }
                if let reason = blockingReason(item) { throw CleanupError.activeApplication(reason) }
                try validate(item, cancellation: cancellation)
                if cancellation.isCancelled { break }
                if let reason = blockingReason(item) { throw CleanupError.activeApplication(reason) }
                guard policy.allows(item.url, category: item.category),
                      try SafetyPolicy.stamp(item.url) == item.measurement.entries[item.path] else { throw CleanupError.changed }
                let destination = try trash(item.url)
                entry = CleanupEntry(source: item.path, destination: destination.path, bytes: item.bytes,
                                     success: true, message: "已移入废纸篓；清空后才会释放磁盘空间")
            } catch {
                entry = CleanupEntry(source: item.path, destination: nil, bytes: 0, success: false, message: error.localizedDescription)
            }
            entries.append(entry); onEntry(entry)
        }
        return entries
    }

    public static func systemTrash(_ url: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return (destination as URL?) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }
}
