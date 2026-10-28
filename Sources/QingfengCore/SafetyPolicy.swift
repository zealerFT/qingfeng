import Foundation
import Darwin

public struct SafetyPolicy: Sendable {
    public let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL.resolvingSymlinksInPath()
    }
    public func url(_ relative: String) -> URL { home.appendingPathComponent(relative).standardizedFileURL }
    public static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
    public static func stamp(_ url: URL) throws -> FileStamp {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return FileStamp(device: info.st_dev, inode: info.st_ino, mode: info.st_mode,
                         size: info.st_size, allocatedBytes: Int64(info.st_blocks) * 512,
                         modified: Int64(info.st_mtimespec.tv_sec),
                         modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                         changed: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
    public static func isLink(_ stamp: FileStamp) -> Bool { stamp.mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
    public static func isDirectory(_ stamp: FileStamp) -> Bool { stamp.mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }
    public static func isRegular(_ stamp: FileStamp) -> Bool { stamp.mode & UInt16(S_IFMT) == UInt16(S_IFREG) }

    public func hasSafeAncestry(_ target: URL) -> Bool {
        let path = target.standardizedFileURL.path
        guard Self.isWithin(path, home.path), path != home.path else { return false }
        var cursor = target.standardizedFileURL
        while cursor.path != home.path {
            guard let stamp = try? Self.stamp(cursor), !Self.isLink(stamp) else { return false }
            cursor.deleteLastPathComponent()
        }
        return true
    }

    public static let developerPaths: [(String, String)] = [
        (".npm/_cacache", "npm 下载缓存"), (".npm/_logs", "npm 日志"),
        (".cache/uv", "uv 包缓存"), (".cache/pip", "pip 下载缓存"),
        (".cache/puppeteer", "Puppeteer 浏览器缓存"),
        ("Library/Caches/go-build", "Go 编译缓存"), ("Library/Caches/goimports", "Goimports 缓存"),
        ("Library/Caches/gopls", "gopls 索引"), ("Library/Caches/golangci-lint", "Go 检查缓存"),
        ("Library/Caches/pip", "pip 下载缓存"), ("Library/Caches/Homebrew", "Homebrew 下载缓存"),
        ("Library/Caches/Yarn", "Yarn 下载缓存"), ("Library/Caches/pnpm", "pnpm 下载缓存"),
        ("Library/Caches/node-gyp", "node-gyp 构建缓存"),
        ("Library/Caches/ms-playwright", "Playwright 浏览器缓存"),
        ("Library/Caches/ms-playwright-go", "Playwright Go 浏览器缓存"),
        ("Library/Caches/Cypress", "Cypress 浏览器缓存"),
        ("Library/Developer/Xcode/DerivedData", "Xcode 构建与索引")
    ]
    public static let jetBrainsSafeNames: Set<String> = ["caches", "index", "compile-server", "tmp"]

    public func allows(_ target: URL, category: ScanCategory, now: Date = Date()) -> Bool {
        guard hasSafeAncestry(target) else { return false }
        let path = target.standardizedFileURL.path
        let rel = String(path.dropFirst(home.path.count + 1))
        switch category {
        case .cache:
            guard target.deletingLastPathComponent().path == url("Library/Caches").path else { return false }
            let name = target.lastPathComponent
            return !name.hasPrefix("com.apple.") && !["JetBrains", "CloudKit", "FamilyCircle", "familycircled"].contains(name)
                && !Self.developerPaths.contains(where: { $0.0 == rel })
        case .developer:
            if Self.developerPaths.contains(where: { $0.0 == rel }) { return true }
            let parts = rel.split(separator: "/").map(String.init)
            return parts.count == 5 && parts[0...2] == ["Library", "Caches", "JetBrains"][...]
                && Self.jetBrainsSafeNames.contains(parts[4])
        case .logs:
            guard target.deletingLastPathComponent().path == url("Library/Logs").path,
                  let s = try? Self.stamp(target), Self.isRegular(s) || Self.isDirectory(s) else { return false }
            return now.timeIntervalSince1970 - Double(s.modified) >= 30 * 86400
        case .installers:
            guard target.deletingLastPathComponent().path == url("Downloads").path,
                  ["dmg", "pkg", "xip"].contains(target.pathExtension.lowercased()),
                  let s = try? Self.stamp(target), Self.isRegular(s) else { return false }
            return now.timeIntervalSince1970 - Double(s.modified) >= 30 * 86400
        case .large, .protected: return false
        }
    }
}
