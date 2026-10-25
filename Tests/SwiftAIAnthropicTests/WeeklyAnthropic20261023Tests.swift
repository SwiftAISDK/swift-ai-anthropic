@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing
@testable import SwiftAIAnthropic

@Suite("WeeklyAnthropic20261023")
struct WeeklyAnthropic20261023Tests {
    @Test(arguments: [JSONValue.string("batch-beta"), .array([123]), .null])
    func invalidBatchBetasAreRejectedBeforeIO(_ value: JSONValue) async throws {
        let transport = RecordingTransport(response: jsonResponse("{}"))
        let provider = try AIProviders.anthropic(configuration: AnthropicProviderSettings(apiKey: "key", transport: transport))
        await #expect(throws: AIError.self) {
            try await provider.batchLanguageModel("claude-haiku-4-5").startBatch(AIBatchStartOptions(
                requests: [AILanguageModelBatchRequest(id: "request-1", request: LanguageModelRequest(messages: [.user("Hi")]))],
                providerOptions: ["anthropic": ["anthropicBeta": value]]
            ))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func directAnthropicRetainsSamplingAndMediaRules() throws {
        let prepared = try AnthropicLanguageModel.body(for: LanguageModelRequest(messages: [AIMessage(role: .user, content: [
            .imageURL("https://example.com/image.png", providerMetadata: ["minimax": ["detail": "high", "cacheControl": ["type": "ephemeral"]]])
        ])], temperature: 1.5, topP: 0.8, maxOutputTokens: 100, providerOptions: ["anthropic": ["thinking": ["type": "adaptive"]]]), modelID: "claude-sonnet-4-5", providerID: "anthropic.messages")
        #expect(prepared.body["temperature"] == nil && prepared.body["top_p"] == nil)
        #expect(prepared.warnings.contains { $0.feature == "temperature" && $0.message?.contains("maximum of 1.0") == true })
        #expect(prepared.body["messages"]?[0]?["content"]?[0]?["source"] == ["type": "url", "url": "https://example.com/image.png"])
        #expect(prepared.body["messages"]?[0]?["content"]?[0]?["cache_control"] == nil)
        #expect(throws: AIError.self) {
            try AnthropicLanguageModel.body(for: LanguageModelRequest(messages: [AIMessage(role: .user, content: [
                .data(mimeType: "video/mp4", data: Data([1, 2, 3]))
            ])]), modelID: "claude-sonnet-4-5", providerID: "anthropic.messages")
        }
    }

    @Test func canonicalCacheLimitIncludesToolsAfterPrompt() throws {
        let options: [String: JSONValue] = ["anthropic": ["cacheControl": ["type": "ephemeral"]]]
        let prepared = try AnthropicLanguageModel.body(for: LanguageModelRequest(messages: [
            AIMessage(role: .system, content: [.text("System")], providerMetadata: options),
            AIMessage(role: .user, content: (1...3).map { .text("Part \($0)", providerMetadata: options) })
        ], tools: ["lookup": ["type": "object", "properties": [:], "providerOptions": .object(options)]]), modelID: "claude-sonnet-4-5", providerID: "anthropic.messages")
        #expect(prepared.body["tools"]?[0]?["cache_control"] == nil)
        #expect(prepared.warnings.filter { $0.feature == "cacheControl breakpoint limit" }.count == 1)
    }

    @Test func nullCustomOptionsStillApplyCanonicalBetas() throws {
        let prepared = try AnthropicLanguageModel.body(for: LanguageModelRequest(messages: [.user("Hi")], providerOptions: [
            "anthropic": ["effort": "high", "speed": "fast"], "minimax": .null
        ]), modelID: "minimax-m3.1-flash", providerID: "minimax.messages")
        #expect(prepared.body["output_config"]?["effort"] == "high")
        #expect(prepared.betas.contains("fast-mode-2026-02-01"))
    }
}
