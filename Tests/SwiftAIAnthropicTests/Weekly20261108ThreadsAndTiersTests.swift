import Foundation
import Testing
@testable import SwiftAIAnthropic
import SwiftAIProvider
import SwiftAITransport

let weeklyAnthropicMessage = #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#

@Suite struct Weekly20261108ThreadsAndTiers {
    @Test(arguments: [false, true]) func createAndContinueRetainLocalToolsAndOnlySendNewTurns(stream: Bool) throws {
        let tools: [String: JSONValue] = ["weather": ["type": "object", "properties": [:]]]
        var request = LanguageModelRequest(messages: [.system("Be concise"), .user("Hello")], tools: tools,
            providerOptions: ["anthropic": ["thread": ["type": "create"]]])
        let create = try AnthropicLanguageModel.body(for: request, modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", stream: stream, supportsMessageThreads: true)
        #expect(create.body["thread"] == ["type": "create"])
        #expect(create.body["system"]?[0]?["text"] == "Be concise")
        #expect(create.body["tools"]?[0]?["name"] == "weather")
        #expect(create.betas.contains("message-threads-2026-08-12"))
        request.providerOptions = ["anthropic": ["thread": ["type": "continue", "previousMessageId": "msg_previous"], "cacheControl": ["type": "ephemeral"]]]
        request.toolChoice = ["type": "auto"]
        let next = try AnthropicLanguageModel.body(for: request, modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", stream: stream, supportsMessageThreads: true)
        #expect(next.body["thread"] == ["type": "continue", "previous_message_id": "msg_previous"])
        #expect(next.body["system"] == nil)
        #expect(next.body["tools"] == nil)
        #expect(next.body["messages"]?.arrayValue?.count == 1)
        #expect(next.body["messages"]?[0]?["content"]?[0]?["text"] == "Hello")
        #expect(next.body["tool_choice"] == ["type": "auto"])
        #expect(next.body["cache_control"] == ["type": "ephemeral"])
        #expect(next.warnings.contains { $0.message?.contains("To change system instructions or tools, start a new thread") == true })
        #expect(!next.markCodeExecutionDynamic)
    }

    @Test func emptyPauseContinuationAndCustomNamespaceAreAccepted() throws {
        let request = LanguageModelRequest(messages: [], providerOptions: ["custom": ["thread": ["type": "continue", "previousMessageId": "paused"]]])
        let call = try AnthropicLanguageModel.body(for: request, modelID: "claude-sonnet-4-6", providerID: "custom.messages", supportsMessageThreads: true)
        #expect(call.body["messages"]?.arrayValue?.isEmpty == true)
        #expect(call.body["thread"]?["previous_message_id"] == "paused")
    }

    @Test func threadContinuationPreservesDynamicWebExecutionAndJSONChoice() throws {
        let tool = AnthropicTools.webSearch_20260209()
        var request = LanguageModelRequest(messages: [.user("Next")], tools: ["research": tool],
            providerOptions: ["anthropic": ["thread": ["type": "continue", "previousMessageId": "web"]]])
        let web = try AnthropicLanguageModel.body(for: request, modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", supportsMessageThreads: true)
        #expect(web.markCodeExecutionDynamic)
        #expect(web.body["tools"] == nil)
        request.tools = [:]
        request.responseFormat = .json(schema: ["type": "object", "properties": [:]], name: nil, description: nil)
        request.providerOptions["anthropic"] = ["thread": ["type": "continue", "previousMessageId": "json"], "structuredOutputMode": "jsonTool"]
        let json = try AnthropicLanguageModel.body(for: request, modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", supportsMessageThreads: true)
        #expect(json.body["tools"] == nil)
        #expect(json.body["tool_choice"]?["type"] == "any")
    }

    @Test func topLevelThreadCacheControlCountsTowardBreakpointLimit() throws {
        let parts = (0..<4).map { AIContentPart.text("Block \($0)", providerMetadata: ["anthropic": ["cacheControl": ["type": "ephemeral"]]]) }
        let call = try AnthropicLanguageModel.body(for: .init(messages: [.init(role: .user, content: parts)],
            providerOptions: ["anthropic": ["thread": ["type": "create"], "cacheControl": ["type": "ephemeral"]]]),
            modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", supportsMessageThreads: true)
        #expect(call.body["messages"]?[0]?["content"]?.arrayValue?.filter { $0["cache_control"] != nil }.count == 3)
        #expect(call.warnings.contains { $0.feature == "cacheControl breakpoint limit" })
    }

    @Test func threadBetaPinningAndUnsupportedPlatformsAreExplicit() throws {
        var request = LanguageModelRequest(messages: [.init(role: .user, content: [.data(mimeType: "application/pdf", data: Data([1]))])],
            providerOptions: ["anthropic": ["thread": ["type": "create"]]])
        let unpinned = try AnthropicLanguageModel.body(for: request, modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", supportsMessageThreads: true)
        #expect(unpinned.warnings.contains { $0.feature == "providerOptions.anthropic.thread" && $0.message?.contains("pdfs-2024-09-25") == true })
        request.providerOptions["anthropic"] = ["thread": ["type": "create"], "anthropicBeta": ["pdfs-2024-09-25"]]
        let pinned = try AnthropicLanguageModel.body(for: request, modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", supportsMessageThreads: true)
        #expect(!pinned.warnings.contains { $0.feature == "providerOptions.anthropic.thread" })
        for provider in ["bedrock.anthropic.messages", "googleVertex.anthropic.messages"] {
            #expect(throws: AIError.self) { try AnthropicLanguageModel.body(for: request, modelID: "claude-sonnet-4-6", providerID: provider) }
        }
    }

    @Test func invalidThreadOptionsAndContextEditsRejectBeforeSending() throws {
        let invalid: [JSONValue] = [["type": "continue"], ["type": "continue", "previousMessageId": ""], ["type": "invalid"], .null]
        for value in invalid {
            #expect(throws: AIError.self) { try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")], providerOptions: ["anthropic": ["thread": value]]), modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", supportsMessageThreads: true) }
        }
        let edits: [JSONValue] = [["compaction": ["type": "summarize"]], ["contextManagement": ["edits": [["type": "clear_thinking_20251015"]]]], ["contextManagement": ["edits": [["type": "compact_20260112"]]]]]
        for value in edits {
            var options = value.objectValue ?? [:]; options["thread"] = ["type": "create"]
            #expect(throws: AIError.self) { try AnthropicLanguageModel.body(for: .init(messages: [], providerOptions: ["anthropic": .object(options)]), modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", supportsMessageThreads: true) }
        }
        let allowed = try AnthropicLanguageModel.body(for: .init(messages: [], providerOptions: ["anthropic": ["thread": ["type": "create"], "contextManagement": ["edits": [["type": "clear_thinking_20251015", "keep": "all"]]]]]), modelID: "claude-sonnet-4-6", providerID: "anthropic.messages", supportsMessageThreads: true)
        #expect(allowed.body["context_management"]?["edits"]?[0]?["keep"] == "all")
    }

    @Test func batchesRejectThreadsWithoutHTTP() async throws {
        let transport = RecordingTransport(response: jsonResponse("{}"))
        let provider = try AIProviders.anthropic(configuration: .init(apiKey: "key", transport: transport))
        await #expect(throws: AIError.self) { try await provider.batchLanguageModel("claude-sonnet-4-6").startBatch(.init(requests: [.init(id: "request", request: .init(messages: [.user("Hi")], providerOptions: ["anthropic": ["thread": ["type": "create"]]]))])) }
        #expect(await transport.requests().isEmpty)
    }

    @Test(arguments: [false, true]) func typedPingsAreOptInAndDoNotBecomeWireOptions(enabled: Bool) async throws {
        let transport = RecordingTransport(response: sseResponse("""
        data: {"type":"ping"}

        data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1}}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1,"service_tier":"priority"}}

        data: {"type":"message_stop"}
        """))
        let model = try AIProviders.anthropic(configuration: .init(apiKey: "key", transport: transport)).languageModel("claude-sonnet-4-6")
        var parts: [LanguageStreamPart] = []
        for try await part in model.stream(.init(messages: [.user("Hi")], includeRawChunks: true, providerOptions: ["anthropic": ["includePings": .bool(enabled)]])) { parts.append(part) }
        #expect(parts.filter { if case .ping = $0 { true } else { false } }.count == (enabled ? 1 : 0))
        #expect(parts.contains { if case let .finishMetadata(_, _, metadata) = $0 { metadata["anthropic"]?["serviceTier"] == "priority" } else { false } })
        let body = try decodeJSONBody(try #require(await transport.requests().first?.body))
        #expect(body["includePings"] == nil)
        #expect(parts.contains { if case let .requestMetadata(metadata) = $0 { metadata.url == "https://api.anthropic.com/v1/messages" } else { false } })
    }

    @Test func serviceTierUsesUsageThenTopLevelAndOmitsForeignTier() async throws {
        let raw: JSONValue = ["usage": ["service_tier": "priority"], "service_tier": "standard"]
        #expect(anthropicProviderMetadata(from: raw, providerID: "anthropic.messages")["anthropic"]?["serviceTier"] == "priority")
        #expect(anthropicProviderMetadata(from: ["service_tier": "standard"], providerID: "anthropic.messages")["anthropic"]?["serviceTier"] == "standard")
        let call = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")], providerOptions: ["anthropic": ["serviceTier": "priority"]]), modelID: "claude-sonnet-4-6", providerID: "anthropic.messages")
        #expect(call.body["service_tier"] == nil)
        #expect(call.warnings.contains { $0.feature == "serviceTier" })
        #expect(throws: AIError.self) { try anthropicTypedOptions(from: ["serviceTier": .null], argumentPrefix: "test") }
    }

    @Test(arguments: [false, true]) func expiredThreadsPreserveRecoveryDetailsAndReadableError(streaming: Bool) async throws {
        let raw = #"{"type":"error","error":{"type":"not_found_error","message":"Thread not found","details":{"error_code":"thread_not_found","unsupported":[{"future":true}]}}}"#
        let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 404, headers: ["x-request-id": "request_1"], body: Data(raw.utf8)))
        let model = try AIProviders.anthropic(configuration: .init(apiKey: "key", transport: transport)).languageModel("claude-sonnet-4-6")
        do {
            let request = LanguageModelRequest(messages: [.user("Hi")], providerOptions: ["anthropic": ["thread": ["type": "continue", "previousMessageId": "expired"]]])
            if streaming { for try await _ in model.stream(request) {} }
            else { _ = try await model.generate(request) }
            Issue.record("Expired thread must fail")
        } catch let failure as AIError {
            let error = try #require(failure.apiCallError)
            #expect(error.statusCode == 404)
            #expect(error.message == "Thread not found")
            #expect(try decodeJSONBody(Data(error.responseBody.utf8))["error"]?["details"]?["error_code"] == "thread_not_found")
            #expect(!error.isRetryable)
        }
    }
}
