import Foundation
import QingfengCore

extension CleanerTests {
    private var analysisHash: String { String(repeating: "a", count: 64) }
    private var blobPath: String { ".ollama/models/blobs/sha256-" + analysisHash }
    private var indexPath: String { ".ollama/models/manifests/registry.ollama.ai/library/" }
    @discardableResult private func manifest(_ model: String, matchingConfig: Bool = false, matchingLayer: Bool = true) throws -> URL {
        let digest = "sha256:" + analysisHash
        let other = "sha256:" + String(repeating: "b", count: 64)
        let data: [String: Any] = [
            "schemaVersion": 2,
            "config": ["digest": matchingConfig ? digest : other, "mediaType": "application/vnd.docker.container.image.v1+json", "size": 12],
            "layers": [["digest": matchingLayer ? digest : other, "mediaType": "application/vnd.ollama.image.model", "size": 1024]],
            "unrelated_private_field": "MUST_NOT_UPLOAD_INDEX_BODY"
        ]
        return try file(indexPath + model, data: String(decoding: JSONSerialization.data(withJSONObject: data), as: UTF8.self))
    }
    private func analysisItem() throws -> ScanItem {
        try file(blobPath, data: "MUST_NOT_UPLOAD_SELECTED_BODY")
        var measurement = Measurement(); measurement.bytes = 4096; measurement.files = 1
        return ScanItem(path: root.appendingPathComponent(blobPath).path, title: "sha256-" + analysisHash,
                        category: .large, note: "Synthetic model fixture; read only", measurement: measurement,
                        eligible: false, suggested: false, logicalBytes: 1024)
    }

    func testAIModelContextIdentifiesSharedReferencesAndLayers() throws {
        let item = try analysisItem()
        try manifest("sample/large"); try manifest("sample/chat")
        try manifest("config-only/latest", matchingConfig: true, matchingLayer: false)
        try manifest("unrelated/latest", matchingLayer: false)
        try file(".ollama/models/manifests/.DS_Store", data: "not a manifest")
        let context = try FileAnalysisContext.collect(for: item, home: root)
        let evidence = try require(context.ollama)
        expectEqual(evidence.status, "complete")
        expectEqual(evidence.manifestsRead, 4)
        expectEqual(evidence.matchingManifests, 3)
        expectEqual(evidence.references.map(\.model), ["config-only:latest", "sample:chat", "sample:large"])
        expectEqual(evidence.references.map(\.role), ["config", "layer", "layer"])
        expectEqual(evidence.references.last?.declaredBytes, 1024)
        expectEqual(evidence.references.last?.manifestPath, "~/" + indexPath + "sample/large")
        expectTrue(context.storage.basis.contains("exact_local_manifest_digest_match"))
        expectEqual(context.storage.root, "~/.ollama/models")
        expectEqual(context.storage.relativePath, "blobs/sha256-" + analysisHash)
        let prompt = FileAnalysisPrompt.userMessage(for: item, context: context, home: root)
        expectFalse(prompt.contains(root.path))
        expectFalse(prompt.contains("MUST_NOT_UPLOAD"))
        expectFalse(prompt.contains("unrelated:latest"))
        expectTrue(prompt.contains("qingfeng_allows_trash"))
        expectTrue(FileAnalysisPrompt.system.contains("移除一个标签也不一定释放共享数据"))
        expectTrue(FileAnalysisPrompt.system.contains("不要从 sha256 哈希猜"))
    }

    func testAIModelContextExplainsUnavailableAndIncompleteIndexes() throws {
        let item = try analysisItem()
        let missing = try require(FileAnalysisContext.collect(for: item, home: root).ollama)
        expectEqual(missing.status, "unavailable")
        expectFalse(missing.limitations.isEmpty)
        try manifest("unrelated/latest", matchingLayer: false)
        let unmatched = try require(FileAnalysisContext.collect(for: item, home: root).ollama)
        expectEqual(unmatched.status, "complete")
        expectEqual(unmatched.matchingManifests, 0)
        expectTrue(unmatched.scope.contains("零匹配不证明无引用或可删除"))
        try file(indexPath + "broken/latest", data: "not-json")
        try manifest("sample/latest")
        let incomplete = try require(FileAnalysisContext.collect(for: item, home: root).ollama)
        expectEqual(incomplete.status, "partial")
        expectEqual(incomplete.matchingManifests, 1)
        expectFalse(incomplete.limitations.isEmpty)
    }

    func testAIModelContextBoundsReadsAndReferences() throws {
        let item = try analysisItem()
        try manifest("sample/one"); try manifest("sample/two")
        var limits = FileAnalysisContext.Limits(); limits.entries = 0
        let limited = try require(FileAnalysisContext.collect(for: item, home: root, limits: limits).ollama)
        expectEqual(limited.status, "partial"); expectEqual(limited.manifestsRead, 0)
        limits = .init(); limits.manifestBytes = 10
        let oversized = try require(FileAnalysisContext.collect(for: item, home: root, limits: limits).ollama)
        expectEqual(oversized.status, "partial"); expectEqual(oversized.manifestsRead, 0)
        limits = .init(); limits.totalBytes = 1
        expectEqual(try FileAnalysisContext.collect(for: item, home: root, limits: limits).ollama?.status, "partial")
        limits = .init(); limits.references = 1
        let capped = try require(FileAnalysisContext.collect(for: item, home: root, limits: limits).ollama)
        expectEqual(capped.matchingManifests, 2); expectEqual(capped.references.count, 1)
        expectTrue(capped.referencesTruncated)
        limits = .init(); limits.seconds = 0
        expectEqual(try FileAnalysisContext.collect(for: item, home: root, limits: limits).ollama?.status, "partial")
    }

    func testAIModelContextRejectsSymlinks() throws {
        let item = try analysisItem()
        let original = try manifest("sample/latest")
        let link = root.appendingPathComponent(indexPath + "sample/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let evidence = try require(FileAnalysisContext.collect(for: item, home: root).ollama)
        expectEqual(evidence.status, "partial")
        expectEqual(evidence.matchingManifests, 1)
        let index = root.appendingPathComponent(".ollama/models/manifests")
        let moved = root.appendingPathComponent("moved-index")
        try FileManager.default.moveItem(at: index, to: moved)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: moved)
        expectEqual(try FileAnalysisContext.collect(for: item, home: root).ollama?.status, "unavailable")
    }

    func testAIAnalysisIncludesVisibleLocationAndProtocolEvidence() throws {
        let item = try analysisItem(); try manifest("sample/latest")
        let context = try FileAnalysisContext.collect(for: item, home: root)
        let display = FileAnalysisPrompt.displayMessage(for: item, context: context, home: root)
        expectTrue(display.contains("位置：~/" + blobPath))
        expectTrue(display.contains("所在文件夹：~/.ollama/models/blobs"))
        expectTrue(display.contains("sample:latest")); expectFalse(display.contains(root.path))
        let prompt = FileAnalysisPrompt.userMessage(for: item, context: context, home: root)
        let metadata = try require(JSONSerialization.jsonObject(with: Data(prompt[prompt.firstIndex(of: "{")!...].utf8)) as? [String: Any])
        expectEqual(metadata["parent_path"] as? String, "~/.ollama/models/blobs")
        expectEqual(metadata["logical_bytes"] as? Int, 1024)
        expectEqual(metadata["qingfeng_allows_trash"] as? Bool, false)
        for provider in AIProvider.allCases {
            let request = try AIRequest.make(configuration: AIConfiguration(provider: provider, baseURL: "https://example.test", model: "fixture"),
                                             apiKey: "", turns: [AIChatTurn(role: .user, content: prompt)])
            let json = try require(JSONSerialization.jsonObject(with: try require(request.httpBody)) as? [String: Any])
            let actual: String?
            if provider == .gemini {
                let first = (json["contents"] as? [[String: Any]])?.first
                actual = (first?["parts"] as? [[String: Any]])?.first?["text"] as? String
            } else { actual = (json["messages"] as? [[String: Any]])?.last?["content"] as? String }
            expectEqual(actual, prompt)
        }
        let cache = ScanItem(path: root.appendingPathComponent("Library/Caches/example.app/data").path, title: "data", category: .cache,
                             note: "fixture", measurement: item.measurement, eligible: true, suggested: false)
        let cacheContext = try FileAnalysisContext.collect(for: cache, home: root)
        expectEqual(cacheContext.storage.basis, "directory_layout_only")
        expectEqual(cacheContext.storage.root, "~/Library/Caches")
        expectTrue(cacheContext.ollama == nil)
    }
}
