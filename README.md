<!-- Generated distribution; edit the canonical repository. -->
# swift-ai-anthropic 1.5.1

Independent Swift-native port of Vercel AI SDK. Source and upstream dispositions are in PROVENANCE.json and Porting/.

## Distribution manifest

Add this package to your SwiftPM dependencies:

```swift
.package(url: "https://github.com/SwiftAISDK/swift-ai-anthropic.git", from: "1.5.1")
```

Products: `SwiftAIAnthropic`.
Contribute and report issues in the canonical SwiftAISDK repository.

## Authored usage guide

# Anthropic for Swift

`SwiftAIAnthropic` adds Anthropic to [SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK), an independent Swift port of the Vercel AI SDK. It ports `@ai-sdk/anthropic` and supports text generation, evaluation, decisions, extraction, provider files and skills.

Provider guide with models, options, streaming and errors:

- [Anthropic](https://swiftaisdk.github.io/SwiftAISDK/providers/anthropic/)

## Usage

Add the `SwiftAI` product from `swift-ai-core` and the `SwiftAIAnthropic` product from this package to your target, then create the provider:

```swift
import SwiftAI
import SwiftAIAnthropic

let provider = try AIProviders.anthropic(configuration: AnthropicProviderSettings())
```

By default the provider reads `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL` from the environment; values set in `AnthropicProviderSettings` take precedence.

To use every provider through one dependency, add the complete [SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK) package instead; see [Install](https://swiftaisdk.github.io/SwiftAISDK/getting-started/install/).

## Contributing

This package is exported from `Packages/swift-ai-anthropic` in the canonical [SwiftAISDK](https://github.com/SwiftAISDK/SwiftAISDK) repository. Open issues and pull requests there.
