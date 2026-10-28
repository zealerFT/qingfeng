import Foundation

public enum ScanCategory: String, Codable, CaseIterable, Sendable {
    case cache, developer, logs, installers, large, protected
    public var title: String {
        switch self {
        case .cache: return "应用缓存"
        case .developer: return "开发缓存"
        case .logs: return "旧日志"
        case .installers: return "旧安装包"
        case .large: return "大文件"
        case .protected: return "重要数据"
        }
    }
    public var symbol: String {
        switch self {
        case .cache: return "square.stack.3d.up"
        case .developer: return "hammer"
        case .logs: return "doc.text"
        case .installers: return "shippingbox"
        case .large: return "doc.richtext"
        case .protected: return "lock.shield"
        }
    }
}

public enum ScanLimit {
    public static let defaultDirectory = 300_000
    public static let minimumDirectory = 10_000
    public static let maximumDirectory = 1_000_000

    public static func isValidDirectory(_ value: Int) -> Bool {
        (minimumDirectory...maximumDirectory).contains(value)
    }

    public static func normalizedDirectory(_ value: Int) -> Int {
        min(max(value, minimumDirectory), maximumDirectory)
    }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let mode: UInt16
    public let size: Int64
    public let allocatedBytes: Int64
    public let modified: Int64
    public let modifiedNanos: Int64
    public let changed: Int64
    public let changedNanos: Int64
}

public struct Measurement: Codable, Equatable, Sendable {
    public var bytes: Int64 = 0
    public var files: Int = 0
    public var newest: Date = .distantPast
    public var complete = true
    public var unsafeEntries = false
    // A metadata snapshot of each entry is used for revalidation; no file content is read.
    public var entries: [String: FileStamp] = [:]
    public init() {}
}

public struct ScanItem: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let category: ScanCategory
    public let note: String
    public let measurement: Measurement
    public let eligible: Bool
    public let suggested: Bool
    public var bytes: Int64 { measurement.bytes }
    public var url: URL { URL(fileURLWithPath: path) }
    public init(path: String, title: String, category: ScanCategory, note: String,
                measurement: Measurement, eligible: Bool, suggested: Bool) {
        self.path = path; self.title = title; self.category = category; self.note = note
        self.measurement = measurement; self.eligible = eligible; self.suggested = suggested
    }
}

public struct ScanIssue: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case permission, changed, limit, safety, io
        public var title: String {
            switch self {
            case .permission: return "访问被拒绝"
            case .changed: return "扫描时文件已变化"
            case .limit: return "达到扫描上限"
            case .safety: return "已跳过特殊路径"
            case .io: return "读取失败"
            }
        }
    }
    public var id: String { path + message + category.rawValue }
    public let path: String
    public let message: String
    // Optional for decoding reports exported by 1.0.0; legacy messages aren't assumed to be permission errors.
    public let kind: Kind?
    public var category: Kind { kind ?? .io }
    public init(path: String, message: String, kind: Kind = .io) {
        self.path = path; self.message = message; self.kind = kind
    }
    public init(path: String, error: Error) {
        let kind = Self.classify(error)
        let advice: String
        switch kind {
        case .changed: advice = "文件在扫描时已被删除或替换；这不是权限问题。请退出对应应用后重新扫描。"
        case .permission: advice = "系统拒绝访问；可检查清风的文件访问授权及该目录的访问限制。"
        default: advice = "请检查该位置是否仍可访问，再重试。"
        }
        self.init(path: path, message: advice + "\n" + error.localizedDescription, kind: kind)
    }
    public static func classify(_ error: Error) -> Kind {
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSPOSIXErrorDomain {
                switch current.code {
                case 1, 13: return .permission // EPERM, EACCES
                case 2, 20: return .changed // ENOENT, ENOTDIR after enumeration
                default: break
                }
            }
            if current.domain == NSCocoaErrorDomain {
                if [CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue].contains(current.code) { return .permission }
                if [CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue].contains(current.code) { return .changed }
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return .io
    }
}

public struct ScanReport: Codable, Sendable {
    public var items: [ScanItem] = []
    public var issues: [ScanIssue] = []
    public var date = Date()
    public var cancelled = false
    public init() {}
    public var cleanableBytes: Int64 { items.filter(\.eligible).reduce(0) { $0 + $1.bytes } }
    public var hasPermissionIssues: Bool { issues.contains { $0.category == .permission } }
    public var issueSummary: String {
        let parts = ScanIssue.Kind.allCases.compactMap { kind -> String? in
            let count = issues.filter { $0.category == kind }.count
            return count == 0 ? nil : "\(kind.title) \(count)"
        }
        return parts.joined(separator: " · ")
    }
}

public struct CleanupEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let source: String
    public let destination: String?
    public let bytes: Int64
    public let success: Bool
    public let message: String
    public init(source: String, destination: String?, bytes: Int64, success: Bool, message: String) {
        id = UUID(); date = Date(); self.source = source; self.destination = destination
        self.bytes = bytes; self.success = success; self.message = message
    }
}

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func cancel() { lock.lock(); value = true; lock.unlock() }
}

public func displayBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
