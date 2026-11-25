import Foundation
import CryptoKit
import Darwin
import QingfengCore

enum AICredentialEdit {
    case unchanged, replace(String), remove
}

/// App-owned storage, outside the replaceable .app bundle. No system credential APIs.
/// The local key protects data at rest, not against a process with access to both files.
@MainActor final class AISettingsStore {
    private struct State: Codable {
        var version = 1
        var configuration = AIConfiguration()
        var credentials: [String: String] = [:]
        var legacyAccounts: Set<String> = []
    }

    static let legacySettingsKey = "Qingfeng.aiConfiguration"
    static let migrationNotice = "旧版 API Key 需要在这里重新填写一次。保存后，重启和更新都会自动读取，不再请求系统钥匙串授权。本机无鉴权服务可留空。"
    let directory: URL
    private let defaults: UserDefaults
    private var dataURL: URL { directory.appendingPathComponent("settings.encrypted") }
    private var keyURL: URL { directory.appendingPathComponent("encryption.key") }
    private let context = Data("local.qingfeng.mac.ai.settings.v1".utf8)

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Qingfeng/AI", isDirectory: true),
         defaults: UserDefaults = .standard) {
        self.directory = directory; self.defaults = defaults
    }

    func configuration() throws -> AIConfiguration { try load().configuration }

    func notice(for config: AIConfiguration) throws -> String? {
        try load().legacyAccounts.contains(config.credentialAccount) ? Self.migrationNotice : nil
    }

    func key(for config: AIConfiguration) throws -> String {
        let state = try load()
        if state.legacyAccounts.contains(config.credentialAccount), !isLocal(config) {
            throw failure(Self.migrationNotice)
        }
        return state.credentials[config.credentialAccount] ?? ""
    }

    func save(_ config: AIConfiguration, credential: AICredentialEdit) throws {
        var state = try load()
        state.configuration = config
        switch credential {
        case .unchanged: break
        case .replace(let key):
            state.credentials[config.credentialAccount] = key.trimmingCharacters(in: .whitespacesAndNewlines)
            state.legacyAccounts.remove(config.credentialAccount)
        case .remove:
            state.credentials.removeValue(forKey: config.credentialAccount)
            state.legacyAccounts.remove(config.credentialAccount)
        }
        try write(state)
        defaults.removeObject(forKey: Self.legacySettingsKey)
    }

    private func isLocal(_ config: AIConfiguration) -> Bool {
        ["localhost", "127.0.0.1", "[::1]", "::1"].contains(URL(string: config.baseURL)?.host?.lowercased() ?? "")
    }

    private func load() throws -> State {
        if FileManager.default.fileExists(atPath: dataURL.path) {
            do {
                try verifyRegularFile(dataURL)
                let key = try encryptionKey(create: false)
                let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: dataURL))
                let bytes = try AES.GCM.open(sealed, using: key, authenticating: context)
                let state = try JSONDecoder().decode(State.self, from: bytes)
                guard state.version == 1 else { throw failure("AI 配置版本不受支持，请更新清风。") }
                return state
            } catch {
                throw failure("无法读取本地加密的 AI 配置。配置或加密文件可能损坏、缺失或无法访问；原文件已保留，请恢复备份后重试。")
            }
        }
        var state = State()
        // Only nonsecret legacy preferences are migrated. Never access old credential storage.
        if let bytes = defaults.data(forKey: Self.legacySettingsKey) {
            guard let config = try? JSONDecoder().decode(AIConfiguration.self, from: bytes) else {
                throw failure("旧版模型配置无法读取，原配置已保留。")
            }
            state.configuration = config
            state.legacyAccounts.insert(config.credentialAccount)
            try write(state)
            defaults.removeObject(forKey: Self.legacySettingsKey)
        }
        return state
    }

    private func write(_ state: State) throws {
        do {
            let key = try encryptionKey(create: true)
            let bytes = try JSONEncoder().encode(state)
            let sealed = try AES.GCM.seal(bytes, using: key, authenticating: context)
            guard let encrypted = sealed.combined else { throw failure("无法加密 AI 配置。") }
            if FileManager.default.fileExists(atPath: dataURL.path) { try verifyRegularFile(dataURL) }
            // Atomic replacement is confined to a private 0700 directory.
            try encrypted.write(to: dataURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataURL.path)
        } catch { throw failure("无法保存本地加密的 AI 配置，请检查应用数据目录的可用空间和访问权限。") }
    }

    private func verifyRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw failure("AI 配置文件类型异常。") }
    }

    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        let fm = FileManager.default
        if fm.fileExists(atPath: keyURL.path) {
            try verifyRegularFile(keyURL)
            let bytes = try Data(contentsOf: keyURL)
            guard bytes.count == 32 else { throw failure("AI 配置的加密文件已损坏。") }
            return SymmetricKey(data: bytes)
        }
        guard create, !fm.fileExists(atPath: dataURL.path) else { throw failure("AI 配置的加密文件缺失。") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw failure("AI 配置目录异常。") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        let fd = Darwin.open(keyURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("无法创建 AI 配置的加密文件。") }
        defer { Darwin.close(fd) }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard written == bytes.count, fsync(fd) == 0 else {
            try? fm.removeItem(at: keyURL)
            throw failure("无法写入 AI 配置的加密文件。")
        }
        return key
    }

    private func failure(_ message: String) -> Error { AIServiceError.configuration(message) }
}

/// Cache successful credential reads for a run; saving config and keys is one transaction.
@MainActor final class AICredentialSession {
    private var entries: [String: String] = [:]
    private let readSecret: (AIConfiguration) throws -> String
    private let writeSettings: (AIConfiguration, AICredentialEdit) throws -> Void
    private let readConfiguration: () throws -> AIConfiguration
    private let readNotice: (AIConfiguration) throws -> String?

    convenience init(store: AISettingsStore) {
        self.init(read: store.key, write: store.save, configuration: store.configuration, notice: store.notice)
    }
    init(read: @escaping (AIConfiguration) throws -> String,
         write: @escaping (AIConfiguration, AICredentialEdit) throws -> Void,
         configuration: @escaping () throws -> AIConfiguration = { AIConfiguration() },
         notice: @escaping (AIConfiguration) throws -> String? = { _ in nil }) {
        readSecret = read; writeSettings = write; readConfiguration = configuration; readNotice = notice
    }
    func configuration() throws -> AIConfiguration { try readConfiguration() }
    func notice(for config: AIConfiguration) -> String? { try? readNotice(config) }
    func key(for config: AIConfiguration) throws -> String {
        if let key = entries[config.credentialAccount] { return key }
        let key = try readSecret(config)
        entries[config.credentialAccount] = key
        return key
    }
    func save(_ edit: AICredentialEdit, for config: AIConfiguration) throws {
        try writeSettings(config, edit)
        switch edit {
        case .unchanged: break
        case .replace(let key): entries[config.credentialAccount] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        case .remove: entries[config.credentialAccount] = ""
        }
    }
}
