import Foundation

/// A future official source for Confidential documents (fetch updates / push back).
/// Not configured yet; the app currently ships Confidential files in its bundle.
public protocol ConfidentialSource: Sendable {
    /// Returns local URLs of newly fetched confidential files.
    func fetchUpdates() async throws -> [URL]
    /// Publishes the given files back to the official source.
    func push(_ urls: [URL]) async throws
}

public enum ConfidentialSourceError: LocalizedError {
    case notConfigured
    public var errorDescription: String? { "Confidential source not configured." }
}

/// Placeholder source used until the official endpoint is wired up. Every call
/// throws so a mis-wired UI surfaces the "not configured" state instead of
/// silently doing nothing.
public struct UnconfiguredConfidentialSource: ConfidentialSource {
    public init() {}
    public func fetchUpdates() async throws -> [URL] { throw ConfidentialSourceError.notConfigured }
    public func push(_ urls: [URL]) async throws { throw ConfidentialSourceError.notConfigured }
}

/// Confidential seeding. At this stage the official source is not configured, so
/// Confidential documents are shipped inside the app bundle and imported on first
/// launch. Seeding is idempotent: a bundled file whose name already exists as a
/// Confidential document is skipped, so this can run every launch and still pick up
/// files added to the bundle later.
@available(macOS 10.15, iOS 13.0, *)
extension DocumentAssistant {
    /// Imports every regular file under `bundleFolderURL` (recursively) that is not
    /// already present as a Confidential document.
    public func syncBundledConfidential(bundleFolderURL: URL?) async throws {
        guard let root = bundleFolderURL,
              FileManager.default.fileExists(atPath: root.path) else { return }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                try await syncBundledConfidential(bundleFolderURL: url)
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if documents.contains(where: { $0.category == .confidential && $0.name == url.lastPathComponent }) { continue }
            try await importDocument(url: url, category: .confidential)
        }
    }

    /// Reserved for the future official source. No-op until `confidentialSource`
    /// is configured; then imports any fetched file not already present.
    public func syncConfidentialFromSource() async throws {
        guard let source = confidentialSource else { return }
        let urls = try await source.fetchUpdates()
        for url in urls
        where !documents.contains(where: { $0.category == .confidential && $0.name == url.lastPathComponent }) {
            try await importDocument(url: url, category: .confidential)
        }
    }
}
