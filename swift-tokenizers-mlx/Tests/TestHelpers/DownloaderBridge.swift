import Foundation
import HFAPI
import MLXLMCommon

enum DownloaderBridgeError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid Hugging Face repository ID: '\(id)'. Expected format 'namespace/name'."
        }
    }
}

extension HFClient {
    /// Shared zero-config client for tests. `HFClient.init` throws only on
    /// environment misconfiguration (e.g. a malformed `HF_ENDPOINT`), so a
    /// trap here surfaces the configuration error directly.
    public static let `default`: HFClient = {
        do {
            return try HFClient()
        } catch {
            fatalError("Failed to create default HFClient: \(error.localizedDescription)")
        }
    }()
}

/// Whether a cached snapshot plausibly contains the weights the caller asked
/// for; see swift-hf-api-mlx's Downloader bridge for the rationale. A cached
/// snapshot can be a partial download from an earlier, narrower pattern set,
/// and the cache cannot distinguish "file not in the repo" from "file not
/// downloaded".
func cachedSnapshotSatisfies(patterns: [String], at directory: URL) -> Bool {
    guard
        let files = try? FileManager.default.subpathsOfDirectory(atPath: directory.path)
    else {
        return false
    }

    for pattern in patterns where pattern.contains("safetensors") {
        let matched = files.contains { path in
            fnmatch(pattern, path, 0) == 0
                || fnmatch(pattern, (path as NSString).lastPathComponent, 0) == 0
        }
        if !matched {
            return false
        }
    }

    let indexURL = directory.appending(path: "model.safetensors.index.json")
    if let data = try? Data(contentsOf: indexURL),
        let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let weightMap = index["weight_map"] as? [String: String]
    {
        let present = Set(files)
        for weightFile in Set(weightMap.values) where !present.contains(weightFile) {
            return false
        }
    }

    return true
}

// swift-format-ignore: AvoidRetroactiveConformances
extension HFAPI.HFClient: @retroactive Downloader {
    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = RepositoryID(id) else {
            throw DownloaderBridgeError.invalidRepositoryID(id)
        }
        let repository = model(repoID)

        // The Downloader contract treats an empty pattern list as "the whole
        // repository", whereas hf-hub treats an empty allow list as "nothing".
        let allowPatterns = patterns.isEmpty ? nil : patterns

        if !useLatest,
            let cached = try await repository.resolveCachedSnapshot(
                revision: revision, allowPatterns: allowPatterns),
            cachedSnapshotSatisfies(patterns: patterns, at: cached)
        {
            return cached
        }

        // Test helpers don't display progress, so download events are not
        // bridged to Foundation.Progress here.
        return try await repository.snapshotDownload(
            revision: revision, allowPatterns: allowPatterns)
    }
}
