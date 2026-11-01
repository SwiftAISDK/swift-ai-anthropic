import Foundation
import Testing
@testable import SwiftAIAnthropic
import SwiftAIProvider
import SwiftAITransport

private let weeklyClosedSchema: JSONValue = ["type": "object", "properties": ["answer": ["type": "string"]], "required": ["answer"], "additionalProperties": false]
private let weeklyRecursiveSchema: JSONValue = ["type": "object", "properties": ["root": ["$ref": "#/$defs/node"]], "required": ["root"], "additionalProperties": false, "$defs": ["node": ["type": "object", "properties": ["children": ["type": "array", "items": ["$ref": "#/$defs/node"]]], "required": ["children"], "additionalProperties": false]]]

@Suite struct Weekly20261101AnthropicStructuredOutput {
    @Test func nativeFallbackOverridesHostingDefaultOnlyForLosslessSchema() throws {
        for model in ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"] {
            let call = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")], responseFormat: .json(schema: weeklyClosedSchema)), modelID: model, providerID: "test.messages", supportsNativeStructuredOutput: false, supportsStrictTools: false)
            #expect(call.body["output_config"]?["format"]?["schema"] == weeklyClosedSchema)
            #expect(call.body["tools"] == nil)
            #expect(!call.usesJSONToolResponseFormat)
        }
        let call = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")], responseFormat: .json(schema: weeklyRecursiveSchema)), modelID: "claude-sonnet-5-5", providerID: "test.messages", supportsNativeStructuredOutput: false)
        #expect(call.body["output_config"] == nil)
        #expect(call.body["tool_choice"]?["type"] == "auto")
        #expect(call.body["tools"]?[0]?["name"] == "json")
        #expect(call.usesJSONToolResponseFormat)
    }

    @Test func schemaPolicyCountsReferencedPropertiesAndRejectsOpenMaps() {
        func optional(_ count: Int) -> JSONValue {
            .object(["type": "object", "properties": .object(Dictionary(uniqueKeysWithValues: (0..<count).map { ("f\($0)", JSONValue.object(["type": "string"])) })), "additionalProperties": false])
        }
        #expect(anthropicSupportsNativeStructuredOutputSchema(optional(10)))
        #expect(!anthropicSupportsNativeStructuredOutputSchema(optional(11)))
        let referenced: JSONValue = ["type": "object", "properties": ["x": ["$ref": "#/$defs/D"], "y": ["$ref": "#/$defs/D"]], "required": ["x", "y"], "additionalProperties": false, "$defs": .object(["D": optional(6)])]
        #expect(!anthropicSupportsNativeStructuredOutputSchema(referenced))
        for open: JSONValue in [["type": "object"], ["additionalProperties": true], ["additionalProperties": ["type": "number"]], ["patternProperties": ["^x-": ["type": "string"]]]] {
            #expect(!anthropicSupportsNativeStructuredOutputSchema(open))
        }
        #expect(anthropicSupportsNativeStructuredOutputSchema(["type": "object", "additionalProperties": false]))
        #expect(!anthropicSupportsNativeStructuredOutputSchema(weeklyRecursiveSchema))
    }

    @Test func referenceCyclesIgnoreInstanceDataAndUnusedDefinitions() {
        #expect(anthropicHasCircularSchemaReference(["type": "object", "properties": ["parent": ["$ref": "#"]]]))
        #expect(!anthropicHasCircularSchemaReference(["type": "object", "default": ["$ref": "#"], "$defs": ["unused": ["$ref": "#/$defs/unused"]]]))
        #expect(!anthropicHasCircularSchemaReference(["properties": ["remote": ["$ref": "https://example.com/schema"], "broken": ["$ref": "#/%E0%A4%A"]]]))
        #expect(anthropicResolveSchemaPointer(["$defs": ["a/b~c": "value"]], pointer: "#/$defs/a~1b~0c") == "value")
        #expect(anthropicResolveSchemaPointer(["$defs": ["a b": "value"]], pointer: "#/$defs/a%20b") == "value")
    }

    @Test func sanitizerRetainsTopLevelReferenceDefinitions() {
        let schema: JSONValue = ["$ref": "#/definitions/Answer", "definitions": ["Answer": weeklyClosedSchema], "$defs": ["Unused": ["type": "string"]]]
        #expect(anthropicSanitizeJSONSchema(schema) == schema)
    }

    @Test func adaptiveReasoningRoundsDownAndNoneWarnsForBetweenTools() throws {
        let call = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")], reasoning: "xhigh"), modelID: "claude-opus-4-6", providerID: "anthropic.messages")
        #expect(call.body["output_config"]?["effort"] == "high")
        #expect(call.warnings.contains { $0.type == "compatibility" && $0.feature == "reasoning" })
        let none = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")], reasoning: "none"), modelID: "claude-sonnet-5-5", providerID: "anthropic.messages")
        #expect(none.body["thinking"]?["type"] == "between_tools")
        #expect(none.warnings.contains { $0.type == "compatibility" && $0.message?.contains("lowest thinking setting") == true })
    }

    @Test func generationSelectsFinalFallbackTextAndRetainsCitations() {
        let text: JSONValue = ["type": "text", "text": "{\"answer\":\"42\"}", "citations": [["type": "web_search_result_location", "cited_text": "42", "title": "Answer", "url": "https://example.com", "encrypted_index": "opaque"]]]
        let preamble: JSONValue = ["type": "text", "text": "checking"]
        let tool: JSONValue = ["type": "server_tool_use", "id": "call_1", "name": "lookup", "input": [:]]
        let result = anthropicGeneratedContent(from: .array([preamble, tool, text]), providerID: "anthropic.messages", citationDocuments: [], usesJSONToolResponseFormat: true, stopReason: "end_turn")
        #expect(result.text == "{\"answer\":\"42\"}")
        #expect(result.content.contains { $0.citations.count == 1 })
        let paused = anthropicGeneratedContent(from: .array([preamble, tool]), providerID: "anthropic.messages", citationDocuments: [], usesJSONToolResponseFormat: true, stopReason: "tool_use")
        #expect(paused.text == "")
        let json: JSONValue = ["type": "tool_use", "id": "json_1", "name": "json", "input": ["answer": "42"]]
        #expect(anthropicGeneratedContent(from: .array([preamble, json]), providerID: "anthropic.messages", citationDocuments: [], usesJSONToolResponseFormat: true).text == "{\"answer\":\"42\"}")
    }

    @Test func streamHoldsFallbackUntilTerminalAndDiscardsToolPreamble() {
        var parser = AnthropicStreamingJSONToolText(providerID: "anthropic.messages", captureFallbackText: true)
        #expect(parser.apply(event: ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]).isEmpty)
        #expect(parser.apply(event: ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "checking"]]).isEmpty)
        _ = parser.apply(event: ["type": "content_block_start", "index": 1, "content_block": ["type": "server_tool_use", "name": "lookup"]])
        _ = parser.apply(event: ["type": "content_block_start", "index": 2, "content_block": ["type": "text", "text": ""]])
        _ = parser.apply(event: ["type": "content_block_delta", "index": 2, "delta": ["type": "text_delta", "text": "{\"answer\":42}"]])
        _ = parser.apply(event: ["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
        let parts = parser.apply(event: ["type": "message_stop"])
        #expect(parts.count == 3)
        #expect(parts.contains { if case let .textDeltaPart(id, delta, _) = $0 { return id == "2" && delta == "{\"answer\":42}" }; return false })
    }

    @Test func nativeStreamEmitsFallbackTextWithCitationsAtResponseBoundary() async throws {
        let events: [JSONValue] = [
            ["type": "message_start", "message": ["id": "msg_1", "usage": ["input_tokens": 1, "output_tokens": 0]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "{\"root\":{}}"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "citations_delta", "citation": ["type": "web_search_result_location", "cited_text": "answer", "title": "Report", "url": "https://example.com/report", "encrypted_index": "opaque"]]],
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]],
            ["type": "message_stop"]
        ]
        let body = try events.map { "data: " + String(decoding: try encodeJSONBody($0), as: UTF8.self) }.joined(separator: "\n\n")
        let transport = RecordingTransport(response: sseResponse(body))
        var config = AnthropicModelConfiguration(baseURL: "https://example.com/v1", http: .init(providerID: "anthropic.messages", headers: [:], transport: transport, url: { _, path in URL(string: "https://example.com/v1\(path)")! }))
        config.supportsNativeStructuredOutput = false
        let model = AnthropicLanguageModel(modelID: "claude-sonnet-5-5", config: config)
        var parts: [LanguageStreamPart] = []
        for try await part in model.stream(.init(messages: [.user("Hi")], responseFormat: .json(schema: weeklyRecursiveSchema))) { parts.append(part) }
        #expect(parts.compactMap { if case let .textDeltaPart(_, delta, _) = $0 { return delta }; return nil }.joined() == "{\"root\":{}}")
        #expect(parts.flatMap(\.citations).count == 1)
        #expect(parts.contains { if case let .finishMetadata(reason, _, _) = $0 { return reason == "stop" }; return false })
    }
}
