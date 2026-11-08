import Foundation
import Testing
@testable import SwiftAIAnthropic
import SwiftAIProvider
import SwiftAITransport

@Suite struct Weekly20261108InlineTools {
    private var schema: JSONValue { ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"], "additionalProperties": false] }
    private func changes(_ value: [JSONValue]) -> AIMessage {
        .init(role: .system, content: [], providerMetadata: ["anthropic": ["toolChanges": .array(value)]])
    }
    private func inline(_ name: String = "weather") -> JSONValue {
        ["type": "tool_addition", "tool": ["type": "function", "name": .string(name), "inputSchema": schema]]
    }
    private func call(_ request: LanguageModelRequest, model: String = "claude-sonnet-4-6", stream: Bool = false) throws -> AnthropicPreparedCall {
        try AnthropicLanguageModel.body(for: request, modelID: model, providerID: "anthropic.messages", stream: stream)
    }

    @Test func inlineToolsHaveStableDefinitionsAndSupersedeReferenceBeta() throws {
        let request = LanguageModelRequest(messages: [.user("Hello"), changes([inline(), ["type": "tool_removal", "toolName": "old"]])], toolChoice: ["type": "auto"], providerOptions: ["anthropic": ["disableParallelToolUse": true]])
        let unary = try call(request), streamed = try call(request, stream: true)
        #expect(unary.body["messages"] == streamed.body["messages"])
        #expect(unary.body["messages"]?[1]?["content"]?[0]?["tool"] == ["type": "tool_definition", "definition": ["name": "weather", "input_schema": schema]])
        #expect(unary.body["tools"] == nil)
        #expect(unary.body["tool_choice"] == ["type": "auto", "disable_parallel_tool_use": true])
        #expect(unary.betas.contains("inline-tools-2026-09-15"))
        #expect(!unary.betas.contains("mid-conversation-tool-changes-2026-07-01"))
        #expect(!unary.betas.contains("fine-grained-tool-streaming-2025-05-14"))
    }

    @Test func ignoredComputerInlineCannotReplaceDeclaredProviderMapping() throws {
        let ignored: JSONValue = ["type": "tool_addition", "tool": AnthropicTools.computer_20251124(displayWidthPx: 100, displayHeightPx: 100)]
        let request = LanguageModelRequest(messages: [.user("Hello"), changes([ignored])], tools: ["desktop": AnthropicTools.computerToolset_20260801()])
        let result = try call(request)
        #expect(result.toolNameMapping.toCustomToolName("computer") == "desktop")
        #expect(result.body["messages"]?.arrayValue?.count == 1)
        #expect(result.warnings.contains { $0.message?.contains("cannot be added by value") == true })
        #expect(!result.betas.contains("inline-tools-2026-09-15"))
    }

    @Test func declaredProviderToolKeepsItsResponseNameWhenInlineProviderNameCollides() throws {
        var inlineObject = AnthropicTools.webSearch_20250305().objectValue ?? [:]; inlineObject["name"] = "inline_search"
        let inlineTool = JSONValue.object(inlineObject)
        let result = try call(.init(messages: [.user("Hello"), changes([["type": "tool_addition", "tool": inlineTool]])], tools: ["declared_search": AnthropicTools.webSearch_20250305()]))
        #expect(result.toolNameMapping.toCustomToolName("web_search") == "declared_search")
    }

    @Test func jsonFallbackDoesNotAllowAnInlineAliasToBypassSelectedSDKTool() throws {
        var object = AnthropicTools.webSearch_20250305().objectValue ?? [:]
        object["name"] = "inline_search"
        let request = LanguageModelRequest(messages: [.user("Hi"), changes([["type": "tool_addition", "tool": .object(object)]])],
            responseFormat: .json(schema: ["type": "object", "additionalProperties": true]),
            tools: ["declared_search": AnthropicTools.webSearch_20250305()], toolChoice: ["type": "tool", "toolName": "declared_search"])
        #expect(throws: AIError.self) { try call(request) }
    }

    @Test func openResponseSchemasUseJSONToolAndRespectCallerRestrictions() throws {
        let openSchema: JSONValue = ["type": "object", "additionalProperties": true]
        for choice: JSONValue in [["type": "none"], ["type": "tool", "toolName": "weather"], ["type": "auto"], ["type": "required"]] {
            let result = try call(.init(messages: [.user("Hello")], responseFormat: .json(schema: openSchema, name: nil, description: nil), tools: ["weather": schema, "other": schema], toolChoice: choice), model: "claude-sonnet-5-5")
            #expect(result.body["output_config"]?["format"] == nil)
            let names = Set(result.body["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
            let type = choice["type"]?.stringValue
            #expect(names == (type == "none" ? ["json"] : type == "tool" ? ["weather", "json"] : ["weather", "other", "json"]))
        }
    }

    @Test func forcedFallbackDisablesMCPAndRejectsConflictingInlineDefinitions() throws {
        var request = LanguageModelRequest(messages: [.user("Hello"), changes([inline("other")])], tools: ["weather": schema], toolChoice: ["type": "tool", "toolName": "weather"], providerOptions: ["anthropic": ["mcpServers": [["type": "url", "url": "https://tools.test", "name": "tools"]]]])
        #expect(throws: AIError.self) { try call(request, model: "claude-opus-5-5") }
        request.messages = [.user("Hello")]
        let valid = try call(request, model: "claude-opus-5-5")
        #expect(valid.body["mcp_servers"]?[0]?["tool_configuration"]?["enabled"] == false)
        #expect(valid.body["tool_choice"]?["type"] == "auto")
        #expect(valid.body["tools"]?.arrayValue?.count == 1)
    }

    @Test func initialInlineChangesAreIgnoredBeforeConflictValidation() throws {
        let result = try call(.init(messages: [changes([inline("other")]), .user("Hello")], tools: ["weather": schema], toolChoice: ["type": "tool", "toolName": "weather"]), model: "claude-opus-5-5")
        #expect(result.warnings.contains { $0.message?.contains("initial system message") == true })
    }

    @Test func nativeOutputWithoutStrictToolsDoesNotEnableStrictBeta() throws {
        let result = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hello")], responseFormat: .json(schema: schema, name: nil, description: nil), tools: ["weather": schema], providerOptions: ["anthropic": ["structuredOutputMode": "outputFormat"]]), modelID: "claude-sonnet-4-5", providerID: "anthropic.messages", supportsNativeStructuredOutput: true, supportsStrictTools: false)
        #expect(result.body["output_config"]?["format"] != nil)
        #expect(!result.betas.contains("structured-outputs-2025-11-13"))
    }

    @Test(arguments: ["google", "vertex", "googleVertex"]) func foreignEmptyTextKeepsCacheOnVisiblePrefill(namespace: String) throws {
        let message = AIMessage(role: .assistant, content: [.text("Answer  "), .text("", providerMetadata: [namespace: ["thoughtSignature": "opaque"]])], providerMetadata: ["anthropic": ["cacheControl": ["type": "ephemeral"]]])
        let result = try call(.init(messages: [.user("Hello"), message]))
        let content = try #require(result.body["messages"]?[1]?["content"]?.arrayValue)
        #expect(content.count == 1)
        #expect(content[0]["text"] == "Answer")
        #expect(content[0]["cache_control"] == ["type": "ephemeral"])
    }

    @Test func legacyVertexNamespaceIsAnAlternativeAndJSONInputsStayObjects() throws {
        let legacy = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")], providerOptions: ["vertex": ["effort": "high", "labels": ["not": "wire"]]]), modelID: "claude-sonnet-4-6", providerID: "googleVertex.anthropic.messages")
        #expect(legacy.body["output_config"]?["effort"] == "high")
        #expect(legacy.body["labels"] == nil)
        let canonical = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hi")], providerOptions: ["googleVertex": [:], "vertex": ["effort": "high"]]), modelID: "claude-sonnet-4-6", providerID: "googleVertex.anthropic.messages")
        #expect(canonical.body["output_config"]?["effort"] == nil)
        #expect(anthropicToolArguments(#"{"city":"Tokyo"}"#) == ["city": "Tokyo"])
        #expect(anthropicToolArguments("{") == ["rawInvalidInput": "{"])
    }
}
