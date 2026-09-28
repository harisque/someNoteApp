# Swift Tokenizers MLX

This package allows [Swift Tokenizers](https://github.com/DePasqualeOrg/swift-tokenizers) to seamlessly integrate with [MLX Swift LM](https://github.com/DePasqualeOrg/mlx-swift-lm) by providing protocol conformance and convenience overloads.

This package depends on [DePasqualeOrg/mlx-swift-lm](https://github.com/DePasqualeOrg/mlx-swift-lm), an independently maintained fork of ml-explore/mlx-swift-lm with a throwing tokenizer API. Because SwiftPM resolves each package identity to a single URL, consumers must also use the fork's URL for `mlx-swift-lm` (and `DePasqualeOrg/mlx-swift`) rather than the ml-explore URLs.

Refer to the [Benchmarks](#Benchmarks) section to compare the performance of Swift Tokenizers and Swift Transformers.

## Setup

Add this package alongside MLX Swift LM in your `Package.swift`:

```swift
.package(url: "https://github.com/DePasqualeOrg/swift-tokenizers-mlx/", branch: "main"),
```

And add the module you need to your target's dependencies:

```swift
.product(name: "MLXLMTokenizers", package: "swift-tokenizers-mlx"),
// and/or
.product(name: "MLXEmbeddersTokenizers", package: "swift-tokenizers-mlx"),
```

## Usage

`MLXLMTokenizers` provides convenience overloads with a default tokenizer loader, so you can omit the `using:` parameter:

```swift
import MLXLLM
import MLXLMHFAPI
import MLXLMTokenizers

// TokenizersLoader is used automatically
let model = try await loadModel(
    from: HFClient.default,
    id: "mlx-community/Qwen3-4B-4bit"
)
```

Load from a local directory:

```swift
import MLXLLM
import MLXLMTokenizers

let container = try await loadModelContainer(from: modelDirectory)
```

You can also pass `TokenizersLoader()` explicitly to the core API:

```swift
let container = try await loadModelContainer(
    from: HFClient.default,
    using: TokenizersLoader(),
    id: "mlx-community/Qwen3-4B-4bit"
)
```

For embedders, import `MLXEmbeddersTokenizers` to get the same default tokenizer behavior:

```swift
import MLXEmbedders
import MLXEmbeddersTokenizers
import MLXEmbeddersHFAPI

let container = try await loadModelContainer(
    from: HFClient.default,
    configuration: EmbedderRegistry.qwen3_embedding
)
```

## Testing

Benchmarks are included by default. Integration tests are opt-in and download models from Hugging Face on first run. The integration suite stays at roughly 5 GB or less per repository to avoid RAM issues on lower-memory devices.

### Running integration tests

In Xcode, set `TOKENIZERS_MLX_ENABLE_INTEGRATION_TESTS=1` in the test scheme environment.

From the command line, prefix the variable with `TEST_RUNNER_` so `xcodebuild` forwards it into the test host:

```bash
TEST_RUNNER_TOKENIZERS_MLX_ENABLE_INTEGRATION_TESTS=1 \
  xcodebuild test -scheme swift-tokenizers-mlx-Package -destination 'platform=macOS,arch=arm64' -only-testing:IntegrationTests
```

## Benchmarks

| | Swift Transformers | Swift Tokenizers | |
| --- | ---: | ---: | --- |
| Tokenizer load | 386.9 ms | 168.1 ms | 2.3x faster |
| Tokenization | 29.1 ms | 4.5 ms | 6.5x faster |
| Decoding | 35.1 ms | 3.9 ms | 9.0x faster |
| LLM load | 416.9 ms | 183.8 ms | 2.3x faster |
| VLM load | 465.5 ms | 225.8 ms | 2.1x faster |
| Embedding load | 414.3 ms | 197.7 ms | 2.1x faster |

These results were observed on an M3 MacBook Pro using Swift Tokenizers [`0.5.0`](https://github.com/DePasqualeOrg/swift-tokenizers/releases/tag/0.5.0), Swift Transformers [`1.3.2`](https://github.com/huggingface/swift-transformers/releases/tag/1.3.2), and MLX Swift LM [`3.31.3`](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.31.3).

A re-run on the same machine in June 2026 with Swift Tokenizers [`0.7.0`](https://github.com/DePasqualeOrg/swift-tokenizers/releases/tag/0.7.0), the Rust-backed Swift HF API 0.4.x, and the DePasqualeOrg mlx-swift-lm fork produced: tokenizer load 192.9 ms, tokenization 5.0 ms, decoding 4.8 ms, LLM load 226.7 ms, VLM load 302.1 ms, and embedding load 245.4 ms (medians, release configuration). The Swift Transformers column has not been re-measured on that stack.

### Running benchmarks

The benchmarks use tests from MLX Swift LM and can be run from this package in Xcode or from the command line with `xcodebuild`:

```bash
xcodebuild test -scheme swift-tokenizers-mlx-Package -configuration Release -destination 'platform=macOS,arch=arm64' -only-testing:Benchmarks
```
