import AppKit
import SwiftUI
import Security
import QingfengCore

// Exercise the real analysis/send/retry paths with synthetic secrets and responses.
// No user defaults, user Keychain items, or external model services are accessed.
@MainActor private final class CredentialProbe {
    var stored: [String: String] = [:]
    var reads = 0
    var writes = 0
    var denyRead = false
    var denyWrite = false
    var transportError: Error?
    var sentKeys: [String] = []
    var interactionRequests: [Bool] = []

    func session() -> AICredentialSession {
        AICredentialSession(read: { config, allowInteraction in
            self.reads += 1
            self.interactionRequests.append(allowInteraction)
            if self.denyRead { throw AIServiceError.configuration("Synthetic Keychain denial") }
            return self.stored[config.credentialAccount] ?? ""
        }, write: { key, config in
            self.writes += 1
            if self.denyWrite { throw AIServiceError.configuration("Synthetic Keychain write failure") }
            self.stored[config.credentialAccount] = key
        })
    }

    func model() -> AssistantModel {
        AssistantModel(preview: true, credentials: session(), stream: { _, key, _ in
            self.sentKeys.append(key)
            return AsyncThrowingStream { continuation in
                if let error = self.transportError { continuation.finish(throwing: error) }
                else { continuation.yield("Synthetic reply"); continuation.finish() }
            }
        })
    }
}

@MainActor enum CredentialChecks {
    static func settled(_ model: AssistantModel) async throws {
        for _ in 0..<500 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Assistant request did not settle")
    }

    static func ask(_ model: AssistantModel) async throws {
        model.input = "Can this cache be deleted?"
        model.sendInput()
        try await settled(model)
    }

    static func openSettings(_ model: AssistantModel) async throws {
        model.showSettings = true
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 900),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AISettingsView(model: model))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        model.showSettings = false
    }

    static func run() async throws {
        let config = AIConfiguration(baseURL: "https://model.example.invalid/v1", model: "test-model")
        let item = ScanItem(path: "/tmp/qingfeng-credential-check/cache.bin", title: "cache.bin", category: .cache,
                            note: "Synthetic fixture", measurement: QingfengCore.Measurement(), eligible: false, suggested: false)
        let probe = CredentialProbe()
        probe.stored[config.credentialAccount] = "test-key-one"
        let model = probe.model()
        model.configuration = config
        for _ in 0..<3 {
            model.analyze(item)
            try await settled(model)
            precondition(model.error == nil && !model.showSettings)
        }
        try await ask(model)
        model.retry(); try await settled(model)
        model.clear(); model.analyze(item); try await settled(model)
        precondition(probe.reads == 1 && probe.writes == 0)
        precondition(probe.sentKeys == Array(repeating: "test-key-one", count: 6))
        precondition(probe.interactionRequests == [false])
        print("PASS repeated right-click analysis, follow-up, retry and new chat reuse one Keychain read")

        try await openSettings(model)
        var otherModel = config; otherModel.model = "another-model"
        try model.save(otherModel)
        try await ask(model)
        precondition(probe.reads == 1 && probe.writes == 0 && probe.sentKeys.last == "test-key-one")
        precondition(probe.stored[config.credentialAccount] == "test-key-one")
        print("PASS opening settings and saving only a model change neither reads nor overwrites the saved key")

        let savedProbe = CredentialProbe()
        let pending = savedProbe.model()
        pending.analyze(item)
        precondition(pending.showSettings && pending.pendingAnalysis != nil)
        try pending.save(config, credential: .replace("  test-key-saved\n"))
        try await settled(pending)
        pending.analyze(item); try await settled(pending)
        precondition(savedProbe.reads == 0 && savedProbe.writes == 1)
        precondition(savedProbe.sentKeys == ["test-key-saved", "test-key-saved"])
        precondition(pending.pendingAnalysis == nil && !pending.showSettings)
        let testKey = try pending.keyForConnectionTest(config, credential: .unchanged)
        let draftKey = try pending.keyForConnectionTest(config, credential: .replace("test-key-draft"))
        precondition(testKey == "test-key-saved" && draftKey == "test-key-draft")
        try await ask(pending)
        precondition(savedProbe.sentKeys.last == "test-key-saved" && savedProbe.reads == 0 && savedProbe.writes == 1)
        print("PASS save-and-analyze and connection testing reuse saved credentials; unsaved test keys stay separate")

        let otherEndpoint = AIConfiguration(baseURL: "https://other.example.invalid/v1", model: "test-model")
        let otherProvider = AIConfiguration(provider: .anthropic, baseURL: config.baseURL, model: config.model)
        probe.stored[otherEndpoint.credentialAccount] = "test-key-two"
        probe.stored[otherProvider.credentialAccount] = "test-key-three"
        for next in [otherEndpoint, otherProvider, config] {
            try model.save(next)
            try await ask(model)
        }
        precondition(probe.reads == 3 && probe.writes == 0)
        precondition(Array(probe.sentKeys.suffix(3)) == ["test-key-two", "test-key-three", "test-key-one"])
        print("PASS credentials are isolated by provider and endpoint and reused when switching back")

        let localProbe = CredentialProbe()
        let local = localProbe.model()
        let localConfig = AIConfiguration(provider: .ollama, baseURL: "http://localhost:11434", model: "test-model")
        try local.save(localConfig)
        try await ask(local); try await ask(local)
        precondition(localProbe.reads == 1 && localProbe.writes == 0 && localProbe.sentKeys == ["", ""])
        try pending.save(config, credential: .remove)
        try await ask(pending)
        precondition(savedProbe.reads == 0 && savedProbe.writes == 2 && savedProbe.sentKeys.last == "")
        precondition(savedProbe.stored[config.credentialAccount] == "")
        print("PASS empty local-service keys are cached and explicit removal clears the cached and saved key")

        try model.save(config, credential: .replace("test-key-replaced"))
        try await ask(model)
        precondition(probe.sentKeys.last == "test-key-replaced" && probe.reads == 3)
        probe.denyWrite = true
        do { try model.save(config, credential: .replace("test-key-failed")); preconditionFailure("Expected write failure") }
        catch { /* A failed save must preserve the usable cached and stored key. */ }
        try await ask(model)
        precondition(probe.sentKeys.last == "test-key-replaced")
        precondition(probe.stored[config.credentialAccount] == "test-key-replaced")
        print("PASS replacement updates the cache and failed saves preserve the prior credential")

        let deniedProbe = CredentialProbe(); deniedProbe.denyRead = true
        let denied = deniedProbe.model(); denied.configuration = config
        try await ask(denied)
        for _ in 0..<3 { denied.analyze(item); try await settled(denied) }
        precondition(deniedProbe.reads == 1 && deniedProbe.sentKeys.isEmpty)
        precondition(denied.credentialAccessBlocked && denied.error != nil && !denied.showSettings)
        try await openSettings(denied)
        try denied.save(config)
        denied.clear(); try await ask(denied)
        denied.retry(); try await settled(denied)
        precondition(deniedProbe.reads == 1 && denied.credentialAccessBlocked && !denied.showSettings)
        precondition(deniedProbe.interactionRequests == [false])
        deniedProbe.denyRead = false; deniedProbe.stored[config.credentialAccount] = "test-key-unlocked"
        denied.authorizeAndRetry(); try await settled(denied)
        denied.analyze(item); try await settled(denied)
        precondition(deniedProbe.reads == 2 && deniedProbe.sentKeys == ["test-key-unlocked", "test-key-unlocked"])
        precondition(!denied.credentialAccessBlocked && denied.error == nil && !denied.showSettings)
        precondition(deniedProbe.interactionRequests == [false, true])
        print("PASS first chat, right-click and retry forbid authorization UI; only explicit authorization permits it")

        let httpProbe = CredentialProbe(); httpProbe.stored[config.credentialAccount] = "test-key-http"
        httpProbe.transportError = AIServiceError.http(401)
        let http = httpProbe.model(); http.configuration = config
        try await ask(http)
        precondition(http.error != nil && !http.credentialAccessBlocked && !http.showSettings)
        http.retry(); try await settled(http)
        precondition(httpProbe.reads == 1 && httpProbe.sentKeys.count == 2 && !http.showSettings)
        let restarted = httpProbe.model(); restarted.configuration = config
        httpProbe.transportError = nil
        try await ask(restarted)
        precondition(httpProbe.reads == 2 && restarted.error == nil)
        precondition(httpProbe.interactionRequests == [false, false])
        print("PASS service authentication errors do not reopen settings; a new app session reads Keychain afresh")

        let settingsProbe = CredentialProbe(); settingsProbe.denyRead = true
        let settings = settingsProbe.model(); settings.configuration = config
        do { _ = try settings.keyForConnectionTest(config, credential: .unchanged); preconditionFailure("Expected access failure") }
        catch { }
        precondition(settingsProbe.interactionRequests == [false])
        settingsProbe.denyRead = false
        try settings.authorizeCredential(config)
        precondition(settingsProbe.interactionRequests == [false, true])
        print("PASS connection testing is silent; settings authorization is a separate explicit action")

        try checkLegacyInteractionGate()
        try checkLockedTestKeychain()
        print("Assistant credential checks: 11/11 passed")
    }

    static func checkLegacyInteractionGate() throws {
        var original: DarwinBoolean = true
        precondition(SecKeychainGetUserInteractionAllowed(&original) == errSecSuccess)
        try AISecretStore.withInteraction(allowed: false) {
            var current: DarwinBoolean = true
            precondition(SecKeychainGetUserInteractionAllowed(&current) == errSecSuccess && !current.boolValue)
        }
        var restored: DarwinBoolean = false
        precondition(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess && restored.boolValue == original.boolValue)
        do {
            try AISecretStore.withInteraction(allowed: false) { throw AIServiceError.configuration("Synthetic failure") }
        } catch { }
        precondition(SecKeychainGetUserInteractionAllowed(&restored) == errSecSuccess && restored.boolValue == original.boolValue)
        print("PASS actual legacy Keychain interaction gate forbids UI and restores prior state after success or failure")
    }

    static func checkLockedTestKeychain() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/KeychainChecks/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = "synthetic-test-password"
        var keychain: SecKeychain?
        let created = SecKeychainCreate(directory.appendingPathComponent("test.keychain").path,
                                       UInt32(password.utf8.count), password, false, nil, &keychain)
        precondition(created == errSecSuccess && keychain != nil, "Cannot create isolated test keychain: \(created)")
        defer {
            SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true)
            SecKeychainDelete(keychain)
        }
        let config = AIConfiguration(baseURL: "https://keychain-check.example.invalid/" + UUID().uuidString, model: "test")
        let service = "local.qingfeng.mac.ai", account = config.credentialAccount, secret = "synthetic-value"
        let added = SecKeychainAddGenericPassword(keychain, UInt32(service.utf8.count), service,
            UInt32(account.utf8.count), account, UInt32(secret.utf8.count), secret, nil)
        precondition(added == errSecSuccess, "Cannot add synthetic key: \(added)")
        let value = try AISecretStore.read(config, keychain: keychain)
        precondition(value == secret)
        precondition(SecKeychainLock(keychain) == errSecSuccess)
        let start = Date()
        do {
            _ = try AISecretStore.read(config, keychain: keychain)
            preconditionFailure("Locked test keychain must not return a secret")
        } catch {
            let status = (error as NSError).code
            let elapsed = Date().timeIntervalSince(start)
            print("Locked synthetic keychain: status \(status), returned in \(elapsed)s")
            precondition(status == Int(errSecInteractionNotAllowed), "Unexpected silent-read status: \(status)")
        }
        precondition(Date().timeIntervalSince(start) < 2, "Silent key lookup waited for authorization")
        print("PASS real locked synthetic keychain returns interaction-not-allowed without opening an authorization dialog")

        precondition(SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true) == errSecSuccess)
        var trusted: SecTrustedApplication?
        precondition(SecTrustedApplicationCreateFromPath("/usr/bin/true", &trusted) == errSecSuccess)
        var access: SecAccess?
        precondition(SecAccessCreate("Qingfeng synthetic restricted key" as CFString, [trusted!] as CFArray, &access) == errSecSuccess)
        let restricted = AIConfiguration(baseURL: "https://restricted-key.example.invalid/" + UUID().uuidString, model: "test")
        var attributes = AISecretStore.query(restricted)
        attributes[kSecUseKeychain as String] = keychain!
        attributes[kSecAttrAccess as String] = access!
        attributes[kSecValueData as String] = Data(secret.utf8)
        precondition(SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess)
        let restrictedStart = Date()
        do {
            _ = try AISecretStore.read(restricted, keychain: keychain)
            preconditionFailure("Restricted key must not be disclosed to an untrusted reader")
        } catch {
            let status = (error as NSError).code
            print("Restricted synthetic key: status \(status), returned in \(Date().timeIntervalSince(restrictedStart))s")
            precondition([Int(errSecInteractionNotAllowed), Int(errSecAuthFailed)].contains(status), "Restricted read returned \(status)")
        }
        precondition(Date().timeIntervalSince(restrictedStart) < 2, "Restricted key waited for authorization")
        print("PASS real key restricted to another signed app is rejected without an authorization dialog")
    }
}
