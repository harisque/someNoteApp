// Copyright © Anthony DePasquale

import Foundation
import MLXEmbedders
import MLXLMCommon
import MLXLMTokenizers

// MARK: - EmbedderModelFactory convenience overloads

extension EmbedderModelFactory {

    /// Load an embedding model using ``TokenizersLoader`` for tokenization.
    public func load(
        from downloader: any Downloader,
        configuration: ModelConfiguration,
        useLatest: Bool = false,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> sending EmbedderModelContext {
        try await load(
            from: downloader, using: TokenizersLoader(),
            configuration: configuration,
            useLatest: useLatest, progressHandler: progressHandler)
    }

    /// Load an embedding model container using ``TokenizersLoader`` for tokenization.
    public func loadContainer(
        from downloader: any Downloader,
        configuration: ModelConfiguration,
        useLatest: Bool = false,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> EmbedderModelContainer {
        try await loadContainer(
            from: downloader, using: TokenizersLoader(),
            configuration: configuration,
            useLatest: useLatest, progressHandler: progressHandler)
    }

    /// Load an embedding model from a local directory using ``TokenizersLoader``
    /// for tokenization.
    public func load(
        from directory: URL
    ) async throws -> sending EmbedderModelContext {
        try await load(from: directory, using: TokenizersLoader())
    }

    /// Load an embedding model container from a local directory using
    /// ``TokenizersLoader`` for tokenization.
    public func loadContainer(
        from directory: URL
    ) async throws -> EmbedderModelContainer {
        try await loadContainer(from: directory, using: TokenizersLoader())
    }
}

// MARK: - Free function convenience overloads

/// Load an embedding model using ``TokenizersLoader`` for tokenization.
public func loadModel(
    from downloader: any Downloader,
    configuration: ModelConfiguration,
    useLatest: Bool = false,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> sending EmbedderModelContext {
    try await EmbedderModelFactory.shared.load(
        from: downloader, using: TokenizersLoader(),
        configuration: configuration,
        useLatest: useLatest, progressHandler: progressHandler)
}

/// Load an embedding model container using ``TokenizersLoader`` for tokenization.
public func loadModelContainer(
    from downloader: any Downloader,
    configuration: ModelConfiguration,
    useLatest: Bool = false,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> EmbedderModelContainer {
    try await EmbedderModelFactory.shared.loadContainer(
        from: downloader, using: TokenizersLoader(),
        configuration: configuration,
        useLatest: useLatest, progressHandler: progressHandler)
}

/// Load an embedding model from a local directory using ``TokenizersLoader``
/// for tokenization.
public func loadModel(
    from directory: URL
) async throws -> sending EmbedderModelContext {
    try await EmbedderModelFactory.shared.load(from: directory, using: TokenizersLoader())
}

/// Load an embedding model container from a local directory using
/// ``TokenizersLoader`` for tokenization.
public func loadModelContainer(
    from directory: URL
) async throws -> EmbedderModelContainer {
    try await EmbedderModelFactory.shared.loadContainer(from: directory, using: TokenizersLoader())
}
