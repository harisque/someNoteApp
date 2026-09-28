// Copyright © Anthony DePasquale

import Foundation
import MLXLMCommon

// MARK: - ModelFactory convenience overloads

extension ModelFactory {

    /// Load a model using ``TokenizersLoader`` for tokenization.
    public func load(
        from downloader: any Downloader,
        configuration: ModelConfiguration,
        useLatest: Bool = false,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> sending ModelContext {
        try await load(
            from: downloader, using: TokenizersLoader(),
            configuration: configuration,
            useLatest: useLatest, progressHandler: progressHandler)
    }

    /// Load a model container using ``TokenizersLoader`` for tokenization.
    public func loadContainer(
        from downloader: any Downloader,
        configuration: ModelConfiguration,
        useLatest: Bool = false,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        try await loadContainer(
            from: downloader, using: TokenizersLoader(),
            configuration: configuration,
            useLatest: useLatest, progressHandler: progressHandler)
    }

    /// Load a model from a local directory using ``TokenizersLoader``
    /// for tokenization.
    public func load(
        from directory: URL
    ) async throws -> sending ModelContext {
        try await load(from: directory, using: TokenizersLoader())
    }

    /// Load a model container from a local directory using ``TokenizersLoader``
    /// for tokenization.
    public func loadContainer(
        from directory: URL
    ) async throws -> ModelContainer {
        try await loadContainer(from: directory, using: TokenizersLoader())
    }
}

// MARK: - Free function convenience overloads

/// Load a model using ``TokenizersLoader`` for tokenization.
public func loadModel(
    from downloader: any Downloader,
    configuration: ModelConfiguration,
    useLatest: Bool = false,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> sending ModelContext {
    try await MLXLMCommon.loadModel(
        from: downloader, using: TokenizersLoader(), configuration: configuration,
        useLatest: useLatest, progressHandler: progressHandler)
}

/// Load a model container using ``TokenizersLoader`` for tokenization.
public func loadModelContainer(
    from downloader: any Downloader,
    configuration: ModelConfiguration,
    useLatest: Bool = false,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> sending ModelContainer {
    try await MLXLMCommon.loadModelContainer(
        from: downloader, using: TokenizersLoader(), configuration: configuration,
        useLatest: useLatest, progressHandler: progressHandler)
}

/// Load a model by ID using ``TokenizersLoader`` for tokenization.
public func loadModel(
    from downloader: any Downloader,
    id: String,
    revision: String = "main",
    useLatest: Bool = false,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> sending ModelContext {
    try await MLXLMCommon.loadModel(
        from: downloader, using: TokenizersLoader(), id: id, revision: revision,
        useLatest: useLatest, progressHandler: progressHandler)
}

/// Load a model container by ID using ``TokenizersLoader`` for tokenization.
public func loadModelContainer(
    from downloader: any Downloader,
    id: String,
    revision: String = "main",
    useLatest: Bool = false,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> sending ModelContainer {
    try await MLXLMCommon.loadModelContainer(
        from: downloader, using: TokenizersLoader(), id: id, revision: revision,
        useLatest: useLatest, progressHandler: progressHandler)
}

/// Load a model from a local directory using ``TokenizersLoader``
/// for tokenization.
public func loadModel(
    from directory: URL
) async throws -> sending ModelContext {
    try await MLXLMCommon.loadModel(from: directory, using: TokenizersLoader())
}

/// Load a model container from a local directory using ``TokenizersLoader``
/// for tokenization.
public func loadModelContainer(
    from directory: URL
) async throws -> sending ModelContainer {
    try await MLXLMCommon.loadModelContainer(from: directory, using: TokenizersLoader())
}
