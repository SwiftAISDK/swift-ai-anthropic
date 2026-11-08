import Foundation
import Testing
import SwiftAIAnthropic
import SwiftAIProvider

@Test func weeklyProviderSelectorCompatibilityAnthropicBodyAndMetadataReferences() throws {
    let oldBody: (LanguageModelRequest, String, String, Bool, Bool?, Bool?, AnthropicRequestPolicy) throws -> AnthropicPreparedCall = AnthropicLanguageModel.body(for:modelID:providerID:stream:supportsNativeStructuredOutput:supportsStrictTools:policy:)
    let extendedBody: (LanguageModelRequest, String, String, Bool, Bool?, Bool?, Bool, AnthropicRequestPolicy) throws -> AnthropicPreparedCall = AnthropicLanguageModel.body(for:modelID:providerID:stream:supportsNativeStructuredOutput:supportsStrictTools:supportsMessageThreads:policy:)
    var policy = AnthropicRequestPolicy()
    policy.maximumTemperature = 0.5
    let request = LanguageModelRequest(messages: [.user("Hi")], temperature: 0.9)
    let forwarded = try oldBody(request, "claude-sonnet-4-6", "anthropic.messages", true, false, false, policy)
    let explicit = try extendedBody(request, "claude-sonnet-4-6", "anthropic.messages", true, false, false, false, policy)
    #expect(forwarded.body == explicit.body); #expect(forwarded.betas == explicit.betas); #expect(forwarded.warnings == explicit.warnings)
    #expect(forwarded.body["stream"] == true); #expect(forwarded.body["temperature"] == 0.5)
    let defaulted = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")]), modelID: "claude-sonnet-4-6", providerID: "anthropic.messages")
    #expect(defaulted.body["stream"] == nil || defaulted.body["stream"] == false)
    let threadRequest = LanguageModelRequest(messages: [.user("Hi")], providerOptions: ["anthropic": ["thread": ["type": "create"]]])
    #expect(throws: AIError.self) { _ = try oldBody(threadRequest, "claude-sonnet-4-6", "anthropic.messages", false, nil, nil, .init()) }
    #expect(try extendedBody(threadRequest, "claude-sonnet-4-6", "anthropic.messages", false, nil, nil, true, .init()).body["thread"] != nil)

    let oldMetadata: (JSONValue?, JSONValue, JSONValue, JSONValue, JSONValue, JSONValue, JSONValue, String, [String: JSONValue]) -> [String: JSONValue] = anthropicProviderMetadata(usage:stopSequence:stopDetails:container:contextManagement:inputTransformations:safeguardResults:providerID:requestProviderOptions:)
    let extendedMetadata: (JSONValue?, JSONValue, JSONValue, JSONValue, JSONValue, JSONValue, JSONValue, JSONValue?, String, [String: JSONValue]) -> [String: JSONValue] = anthropicProviderMetadata(usage:stopSequence:stopDetails:container:contextManagement:inputTransformations:safeguardResults:serviceTier:providerID:requestProviderOptions:)
    let usage: JSONValue = ["input_tokens": 3, "service_tier": "priority"]
    let actual = oldMetadata(usage, "END", ["reason": "pause"], ["id": "container"], ["applied": true], ["changed": true], ["safe": true], "anthropic.messages", [:])
    let expected = extendedMetadata(usage, "END", ["reason": "pause"], ["id": "container"], ["applied": true], ["changed": true], ["safe": true], nil, "anthropic.messages", [:])
    #expect(actual == expected); #expect(actual["anthropic"]?["serviceTier"] == "priority")
    #expect(actual["anthropic"]?["stopDetails"]?["reason"] == "pause")
    #expect(anthropicProviderMetadata(usage: nil, stopSequence: .null, container: .null, contextManagement: .null, providerID: "anthropic.messages")["anthropic"]?["stopDetails"] == nil)
    #expect(extendedMetadata(nil, .null, .null, .null, .null, .null, .null, "standard", "anthropic.messages", [:])["anthropic"]?["serviceTier"] == "standard")
}
