import Foundation
import QingfengCore

@MainActor enum StorageChecks {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QingfengStorageChecks-" + UUID().uuidString)
        let suite = "QingfengStorageChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        func store() -> AISettingsStore { AISettingsStore(directory: directory, defaults: defaults) }
        let dataURL = directory.appendingPathComponent("settings.encrypted")
        let keyURL = directory.appendingPathComponent("encryption.key")
        let config = AIConfiguration(baseURL: "https://synthetic.example.invalid/v1", model: "synthetic-model")
        let secret = "synthetic-secret-only-for-isolated-tests"
        try store().save(config, credential: .replace(secret))
        let reopened = store()
        let savedConfig = try reopened.configuration(), savedKey = try reopened.key(for: config)
        precondition(savedConfig == config && savedKey == secret)
        let ciphertext = try Data(contentsOf: dataURL), keyBytes = try Data(contentsOf: keyURL)
        for text in [secret, config.baseURL, config.model] {
            precondition(ciphertext.range(of: Data(text.utf8)) == nil)
            precondition(keyBytes.range(of: Data(text.utf8)) == nil)
        }
        for (url, mode) in [(directory, 0o700), (dataURL, 0o600), (keyURL, 0o600)] {
            let actual = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
            precondition(actual.intValue == mode)
        }
        print("PASS encrypted configuration and keys survive reopening with private directory/file permissions and no plaintext fields")

        var changed = config; changed.model = "another-model"
        try store().save(changed, credential: .unchanged)
        let sameKey = try store().key(for: changed)
        precondition(sameKey == secret)
        let ciphertext2 = try Data(contentsOf: dataURL)
        precondition(ciphertext2 != ciphertext)
        let other = AIConfiguration(provider: .anthropic, baseURL: config.baseURL, model: "other")
        try store().save(other, credential: .replace("separate-key"))
        let otherEndpoint = AIConfiguration(baseURL: "https://another.example.invalid/v1", model: "other")
        try store().save(otherEndpoint, credential: .replace("endpoint-key"))
        try store().save(config, credential: .replace("replacement"))
        let replaced = try store().key(for: config), isolated = try store().key(for: other)
        let isolatedEndpoint = try store().key(for: otherEndpoint)
        precondition(replaced == "replacement" && isolated == "separate-key" && isolatedEndpoint == "endpoint-key")
        try store().save(config, credential: .remove)
        let removed = try store().key(for: config), retained = try store().key(for: other)
        precondition(removed.isEmpty && retained == "separate-key")
        let local = AIConfiguration(provider: .ollama, baseURL: "http://localhost:11434", model: "local-model")
        try store().save(local, credential: .unchanged)
        let empty = try store().key(for: local)
        precondition(empty.isEmpty)
        print("PASS model changes preserve keys; replacement/removal, protocols, endpoints and unauthenticated local services persist independently")

        let intact = try Data(contentsOf: dataURL)
        var tampered = intact; tampered[tampered.count / 2] ^= 0xff
        try tampered.write(to: dataURL)
        expectFailure { _ = try store().configuration() }
        expectFailure { try store().save(config, credential: .replace("must-not-overwrite")) }
        let preserved = try Data(contentsOf: dataURL)
        precondition(preserved == tampered)
        try intact.write(to: dataURL)
        try FileManager.default.removeItem(at: keyURL)
        expectFailure { _ = try store().key(for: other) }
        expectFailure { try store().save(config, credential: .replace("must-not-overwrite")) }
        let afterMissingKey = try Data(contentsOf: dataURL)
        precondition(afterMissingKey == intact && !FileManager.default.fileExists(atPath: keyURL.path))
        try keyBytes.write(to: keyURL)
        let recovered = try store().key(for: other)
        precondition(recovered == "separate-key")
        print("PASS tampered ciphertext and missing encryption key fail without replacing existing data; restored files recover")

        try FileManager.default.removeItem(at: directory)
        defaults.set(try JSONEncoder().encode(config), forKey: AISettingsStore.legacySettingsKey)
        let migrated = try store().configuration()
        precondition(migrated == config && defaults.data(forKey: AISettingsStore.legacySettingsKey) == nil)
        let notice = try store().notice(for: config)
        precondition(notice != nil)
        expectFailure { _ = try store().key(for: config) }
        try store().save(config, credential: .replace(secret))
        let migrationKey = try store().key(for: config), completedNotice = try store().notice(for: config)
        precondition(migrationKey == secret && completedNotice == nil)
        print("PASS nonsecret legacy settings migrate once; one local key save clears the migration notice across relaunches")

        var sentKeys: [String] = []
        func model() -> AssistantModel {
            AssistantModel(preview: true, credentials: AICredentialSession(store: store()), stream: { _, key, _ in
                sentKeys.append(key)
                return AsyncThrowingStream { $0.yield("Synthetic reply"); $0.finish() }
            })
        }
        let first = model()
        precondition(first.configuration == config && first.configurationNotice == nil)
        try await CredentialChecks.ask(first)
        try first.save(changed)
        let restarted = model()
        precondition(restarted.configuration == changed)
        try await CredentialChecks.ask(restarted)
        precondition(sentKeys == [secret, secret] && restarted.error == nil && !restarted.showSettings)
        print("PASS actual assistant relaunch loads encrypted model configuration and sends with the saved key automatically")
        print("Assistant storage checks: 5/5 passed")
    }

    private static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected local storage failure") }
        catch { /* Expected: no system dialog and no destructive fallback. */ }
    }
}
