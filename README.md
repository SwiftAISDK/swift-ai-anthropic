<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-anthropic 1.0.0

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-anthropic.git", from: "1.0.0")
```

Products: `SwiftAIAnthropic`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# Swift AI Anthropic

An independent Swift-native port of the provider-facing Vercel AI SDK package
`@ai-sdk/anthropic`. Messages, streaming, tools, structured output, decisions/evaluation, batches, file upload and skills.

Swift 6.3 or newer; declared platforms macOS 12 and iOS 15. This source is
maintained in the canonical SwiftAISDK repository and exported as an independently
versioned Swift package. Swift versions are independent of the npm baselines.

## Usage

Depend on `.product(name: "SwiftAIAnthropic", package: "swift-ai-anthropic")`.
For generation and explicit registries also add `swift-ai-core` and its `SwiftAI`
product. The canonical [example](https://github.com/SwiftAISDK/SwiftAISDK/blob/main/Examples/AnthropicOnly) contains a complete
manifest for local development and runs offline with an injected transport.

```swift
import SwiftAI
import SwiftAIAnthropic

let provider = try AIProviders.anthropic(
    configuration: AnthropicProviderSettings(apiKey: "your-api-key")
)
let model = try provider.languageModel("your-model-id")
let result = try await AI.generateText(
    model: model,
    request: .init(messages: [.user("Hello")])
)
```

Native factories use typed `configuration:` settings. The legacy `settings:`
overloads belong to `SwiftAISDK`. When importing both facades, qualify `SwiftAI.AI`
or `SwiftAISDK.AI` and the appropriate factory namespace. Core uses explicit model
objects or registries; it does not initialize an implicit Gateway.

Runtime dependencies are core contracts, transport and utilities only. Bedrock,
Vertex and MiniMax policy remains with those hosting providers; wire adapter
configuration allows the aggregate to reuse Messages behavior without a reverse
provider dependency. File support remains upload-only.

## Porting and verification

Run `swift test --package-path Packages/swift-ai-anthropic --no-parallel` from the
canonical checkout. Full verification is `node Scripts/test-packages.mjs`, followed
by `node Scripts/verify-provider-isolation.mjs` and
`node Scripts/verify-provider-versions.mjs`. The latter uses synthetic local Git
tags, not released version histories.

`Porting/map.json` owns source/test/fixture relationships. Reviewed npm versions,
archive evidence and test snapshot dispositions remain in the canonical
`Porting/upstream-lock.json`. Extraction does not advance baselines or claim new
upstream parity. Cross-package wire APIs support port adapters; prefer the typed
provider factory for application code.

Licensed under Apache-2.0; see LICENSE. Vercel names identify provenance, not
affiliation. Contribute through the canonical SwiftAISDK repository. Distribution repositories are generated from it.
