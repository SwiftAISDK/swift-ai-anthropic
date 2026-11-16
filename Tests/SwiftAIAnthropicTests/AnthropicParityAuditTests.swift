@testable import SwiftAI
@testable import SwiftAIProvider
@testable import SwiftAIProviderUtilities
@testable import SwiftAITransport
import Foundation
import Testing
@testable import SwiftAIAnthropic

// Translations of `@ai-sdk/anthropic` `anthropic-language-model.test.ts` request-mapping
// cases that assert exact request bodies and complete warning arrays.

private let auditTextResponse = """
{"model":"claude-sonnet-4-5-20250929","id":"msg_01VdEjxAP5ahtHKrrRdNBteQ","type":"message","role":"assistant","content":[{"type":"text","text":"Hello! I'm doing well, thanks for asking. How are you doing today? Is there anything I can help you with?"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":12,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":29,"service_tier":"standard","inference_geo":"not_available"}}
"""

private let auditHelloMessages: JSONValue = [["role": "user", "content": [["type": "text", "text": "Hello"]]]]

private func auditGenerate(
    _ modelID: String,
    _ request: LanguageModelRequest
) async throws -> (body: JSONValue, warnings: [AIWarning], headers: [String: String]) {
    let transport = RecordingTransport(response: jsonResponse(auditTextResponse))
    let provider = try AIProviders.anthropic(configuration: AnthropicProviderSettings(apiKey: "test-api-key", transport: transport))
    let result = try await provider.languageModel(modelID).generate(request)
    let sent = try #require(await transport.requests().first)
    return (try decodeJSONBody(try #require(sent.body)), result.warnings, sent.headers)
}

private func auditRequest(
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    seed: Int? = nil,
    maxOutputTokens: Int? = nil,
    responseFormat: AIResponseFormat? = nil,
    reasoning: String? = nil,
    tools: [String: JSONValue] = [:],
    toolChoice: JSONValue? = nil,
    providerOptions: [String: JSONValue] = [:]
) -> LanguageModelRequest {
    LanguageModelRequest(
        messages: [.user("Hello")],
        temperature: temperature,
        topP: topP,
        topK: topK,
        seed: seed,
        maxOutputTokens: maxOutputTokens,
        responseFormat: responseFormat,
        reasoning: reasoning,
        tools: tools,
        toolChoice: toolChoice,
        providerOptions: providerOptions
    )
}

// "should pass thinking config; add budget tokens; clear out temperature, top_p, top_k; and return warnings"
@Test func anthropicAuditThinkingEnabledStripsSamplingInUpstreamOrder() async throws {
    let result = try await auditGenerate("claude-sonnet-4-5", auditRequest(
        temperature: 0.5, topP: 0.7, topK: 1, maxOutputTokens: 20_000,
        providerOptions: ["anthropic": ["thinking": ["type": "enabled", "budgetTokens": 1_000]]]
    ))
    #expect(result.body == [
        "max_tokens": 21_000,
        "messages": auditHelloMessages,
        "model": "claude-sonnet-4-5",
        "thinking": ["budget_tokens": 1_000, "type": "enabled"]
    ])
    #expect(result.warnings == [
        AIWarning(type: "unsupported", feature: "temperature", message: "temperature is not supported when thinking is enabled"),
        AIWarning(type: "unsupported", feature: "topK", message: "topK is not supported when thinking is enabled"),
        AIWarning(type: "unsupported", feature: "topP", message: "topP is not supported when thinking is enabled")
    ])
}

// "should use default thinking budget when it is not set"
@Test func anthropicAuditDefaultThinkingBudgetUsesModelMaxOutputTokens() async throws {
    let result = try await auditGenerate("claude-haiku-4-5", auditRequest(
        providerOptions: ["anthropic": ["thinking": ["type": "enabled"]]]
    ))
    #expect(result.body == [
        "max_tokens": 64_000,
        "messages": auditHelloMessages,
        "model": "claude-haiku-4-5",
        "thinking": ["budget_tokens": 1_024, "type": "enabled"]
    ])
    #expect(result.warnings == [
        AIWarning(type: "compatibility", feature: "extended thinking", message: "thinking budget is required when thinking is enabled. using default budget of 1024 tokens.")
    ])
}

// Top-level reasoning on a budget-thinking model without maxOutputTokens: the
// budget is added to the model default and then limited to the model maximum.
@Test func anthropicAuditTopLevelReasoningBudgetWithoutMaxOutputTokensUsesModelLimit() async throws {
    let result = try await auditGenerate("claude-sonnet-4-5", auditRequest(reasoning: "low"))
    #expect(result.body["max_tokens"] == 64_000)
    #expect(result.body["thinking"] == ["type": "enabled", "budget_tokens": 6_400])
    #expect(result.warnings.isEmpty)
}

// "should limit max output tokens to the model max and warn"
@Test func anthropicAuditLimitsMaxOutputTokensToModelMaximum() async throws {
    let result = try await auditGenerate("claude-haiku-4-5", auditRequest(maxOutputTokens: 999_999))
    #expect(result.body == ["max_tokens": 64_000, "messages": auditHelloMessages, "model": "claude-haiku-4-5"])
    #expect(result.warnings == [
        AIWarning(type: "unsupported", feature: "maxOutputTokens", message: "999999 (maxOutputTokens + thinkingBudget) is greater than claude-haiku-4-5 64000 max output tokens. The max output tokens have been limited to 64000.")
    ])
}

// "should not limit max output tokens for unknown models"
@Test func anthropicAuditDoesNotLimitUnknownModels() async throws {
    let result = try await auditGenerate("future-model", auditRequest(maxOutputTokens: 123_456))
    #expect(result.body == ["max_tokens": 123_456, "messages": auditHelloMessages, "model": "future-model"])
    #expect(result.warnings.isEmpty)
}

// "temperature clamping" (all three cases)
@Test func anthropicAuditClampsTemperatureLikeUpstream() async throws {
    let above = try await auditGenerate("claude-3-haiku-20240307", auditRequest(temperature: 1.5))
    #expect(above.body["temperature"] == 1)
    #expect(above.warnings == [AIWarning(type: "unsupported", feature: "temperature", message: "1.5 exceeds anthropic maximum of 1.0. clamped to 1.0")])

    let below = try await auditGenerate("claude-3-haiku-20240307", auditRequest(temperature: -0.5))
    #expect(below.body["temperature"] == 0)
    #expect(below.warnings == [AIWarning(type: "unsupported", feature: "temperature", message: "-0.5 is below anthropic minimum of 0. clamped to 0")])

    let valid = try await auditGenerate("claude-3-haiku-20240307", auditRequest(temperature: 0.7))
    #expect(valid.body["temperature"] == 0.7)
    #expect(valid.warnings.isEmpty)
}

// Upstream clamps before the model capability check and formats numbers like JavaScript,
// so an integral temperature prints without a fractional part.
@Test func anthropicAuditTemperatureWarningsFollowUpstreamOrder() async throws {
    let rejecting = try await auditGenerate("claude-opus-4-7", auditRequest(temperature: 2, seed: 1))
    #expect(rejecting.body["temperature"] == nil)
    #expect(rejecting.warnings == [
        AIWarning(type: "unsupported", feature: "seed"),
        AIWarning(type: "unsupported", feature: "temperature", message: "2 exceeds anthropic maximum of 1.0. clamped to 1.0"),
        AIWarning(type: "unsupported", feature: "temperature", message: "temperature is not supported by claude-opus-4-7 and will be ignored")
    ])

    let unknown = try await auditGenerate("future-model", auditRequest(temperature: 1.5))
    #expect(unknown.warnings == [
        AIWarning(type: "unsupported", feature: "temperature", message: "1.5 exceeds anthropic maximum of 1.0. clamped to 1.0"),
        AIWarning(type: "compatibility", feature: "maxOutputTokens", message: "The model \"future-model\" is unknown. The max output tokens have been limited to 4096. Set maxOutputTokens explicitly to override this limit.")
    ])
}

// "should strip unsupported sampling parameters with warnings" (forward-compatible defaults)
@Test func anthropicAuditUnknownClaudeModelStripsSamplingParameters() async throws {
    let result = try await auditGenerate("claude-future-9", auditRequest(temperature: 0.5, topP: 0.7, topK: 10, maxOutputTokens: 100))
    #expect(result.body["temperature"] == nil)
    #expect(result.body["top_p"] == nil)
    #expect(result.body["top_k"] == nil)
    #expect(result.warnings == [
        AIWarning(type: "unsupported", feature: "temperature", message: "temperature is not supported by claude-future-9 and will be ignored"),
        AIWarning(type: "unsupported", feature: "topK", message: "topK is not supported by claude-future-9 and will be ignored"),
        AIWarning(type: "unsupported", feature: "topP", message: "topP is not supported by claude-future-9 and will be ignored")
    ])
}

// The thinking option schema is a discriminated union: fields of other variants are stripped.
@Test func anthropicAuditThinkingOptionKeepsOnlyVariantFields() async throws {
    let adaptive = try await auditGenerate("claude-opus-4-6", auditRequest(
        providerOptions: ["anthropic": ["thinking": ["type": "adaptive", "budgetTokens": 5_000]]]
    ))
    #expect(adaptive.body["thinking"] == ["type": "adaptive"])
    #expect(adaptive.warnings.isEmpty)

    let enabled = try await auditGenerate("claude-sonnet-4-5", auditRequest(
        maxOutputTokens: 1_000,
        providerOptions: ["anthropic": ["thinking": ["type": "enabled", "budgetTokens": 2_000, "display": "summarized"]]]
    ))
    #expect(enabled.body["thinking"] == ["type": "enabled", "budget_tokens": 2_000])
}

// "agent skills": "should send request body with skills in container"
@Test func anthropicAuditSkillsContainerResolvesCustomProviderReferences() async throws {
    let result = try await auditGenerate("claude-3-haiku-20240307", auditRequest(
        tools: ["code_execution": AnthropicTools.codeExecution_20250825()],
        providerOptions: ["anthropic": ["container": [
            "id": "test-container-id",
            "skills": [
                ["type": "anthropic", "skillId": "pptx", "version": "latest"],
                ["type": "custom", "providerReference": ["anthropic": "skill_01Xud7kLMsjLfc7Aa6RvigZf"], "version": "1.0"]
            ]
        ]]]
    ))
    #expect(result.body == [
        "container": [
            "id": "test-container-id",
            "skills": [
                ["skill_id": "pptx", "type": "anthropic", "version": "latest"],
                ["skill_id": "skill_01Xud7kLMsjLfc7Aa6RvigZf", "type": "custom", "version": "1.0"]
            ]
        ],
        "max_tokens": 4_096,
        "messages": auditHelloMessages,
        "model": "claude-3-haiku-20240307",
        "tools": [["name": "code_execution", "type": "code_execution_20250825"]]
    ])
    #expect(result.warnings.isEmpty)
}

// "should add a warning when the code execution tool is not present"
@Test func anthropicAuditSkillsWithoutCodeExecutionWarns() async throws {
    let result = try await auditGenerate("claude-3-haiku-20240307", auditRequest(
        providerOptions: ["anthropic": ["container": [
            "id": "test-container-id",
            "skills": [
                ["type": "anthropic", "skillId": "pptx", "version": "latest"],
                ["type": "custom", "providerReference": ["anthropic": "skill_01Xud7kLMsjLfc7Aa6RvigZf"], "version": "1.0"]
            ]
        ]]]
    ))
    #expect(result.body["container"]?["skills"]?[1] == ["skill_id": "skill_01Xud7kLMsjLfc7Aa6RvigZf", "type": "custom", "version": "1.0"])
    #expect(result.body["tools"] == nil)
    #expect(result.warnings == [AIWarning(type: "other", message: "code execution tool is required when using skills")])
}

// "should include beta headers when skills are configured" and
// "should resolve custom skill provider references at the Anthropic boundary"
@Test func anthropicAuditSkillsBetaHeadersAndContainerWithoutID() async throws {
    let result = try await auditGenerate("claude-3-haiku-20240307", auditRequest(
        tools: ["code_execution": AnthropicTools.codeExecution_20250825()],
        providerOptions: ["anthropic": ["container": ["skills": [
            ["type": "custom", "providerReference": ["anthropic": "skill_01Xud7kLMsjLfc7Aa6RvigZf"]]
        ]]]]
    ))
    #expect(result.body["container"] == ["skills": [["skill_id": "skill_01Xud7kLMsjLfc7Aa6RvigZf", "type": "custom"]]])
    #expect(result.headers["anthropic-beta"] == "code-execution-2025-08-25,skills-2025-10-02,files-api-2025-04-14")
}

// "should throw when a custom skill provider reference does not include anthropic"
@Test func anthropicAuditSkillsMissingAnthropicProviderReferenceThrows() async throws {
    await #expect(throws: AINoSuchProviderReferenceError.self) {
        _ = try await auditGenerate("claude-3-haiku-20240307", auditRequest(
            providerOptions: ["anthropic": ["container": ["skills": [
                ["type": "custom", "providerReference": ["openai": "skill_abc"]]
            ]]]]
        ))
    }
}

// "should pass tools and toolChoice"
@Test func anthropicAuditPassesToolsAndNamedToolChoice() async throws {
    let schema: JSONValue = [
        "type": "object",
        "properties": ["value": ["type": "string"]],
        "required": ["value"],
        "additionalProperties": false,
        "$schema": "http://json-schema.org/draft-07/schema#"
    ]
    let result = try await auditGenerate("claude-3-haiku-20240307", auditRequest(
        tools: ["test-tool": schema],
        toolChoice: ["type": "tool", "toolName": "test-tool"]
    ))
    #expect(result.body == [
        "model": "claude-3-haiku-20240307",
        "messages": auditHelloMessages,
        "max_tokens": 4_096,
        "tools": [["name": "test-tool", "input_schema": schema]],
        "tool_choice": ["type": "tool", "name": "test-tool"]
    ])
}

// MARK: - convert-to-anthropic-prompt.test.ts translations

private func auditMessages(
    _ messages: [AIMessage],
    modelID: String = "claude-3-haiku-20240307",
    providerOptions: [String: JSONValue] = [:]
) async throws -> (body: JSONValue, warnings: [AIWarning], headers: [String: String]) {
    try await auditGenerate(modelID, LanguageModelRequest(messages: messages, providerOptions: providerOptions))
}

private let strawberryReasoning = "I need to count the number of \"r\"s in the word \"strawberry\"."
private let strawberryAnswer = "The word \"strawberry\" has 2 \"r\"s."

// "should convert assistant message reasoning parts with signature into thinking parts when sendReasoning is true"
@Test func anthropicAuditSignedReasoningPartBecomesThinking() async throws {
    let result = try await auditMessages([
        AIMessage(role: .assistant, content: [
            .reasoning(strawberryReasoning, providerMetadata: ["anthropic": ["signature": "test-signature"]]),
            .text(strawberryAnswer)
        ])
    ])
    #expect(result.body["messages"] == [[
        "role": "assistant",
        "content": [
            ["type": "thinking", "thinking": .string(strawberryReasoning), "signature": "test-signature"],
            ["type": "text", "text": .string(strawberryAnswer)]
        ]
    ]])
    #expect(result.warnings.isEmpty)
}

// "should ignore reasoning parts without signature into thinking parts when sendReasoning is true"
@Test func anthropicAuditUnsignedReasoningPartIsDroppedWithWarning() async throws {
    let result = try await auditMessages([
        AIMessage(role: .assistant, content: [.reasoning(strawberryReasoning), .text(strawberryAnswer)])
    ])
    #expect(result.body["messages"] == [[
        "role": "assistant",
        "content": [["type": "text", "text": .string(strawberryAnswer)]]
    ]])
    #expect(result.warnings == [AIWarning(type: "other", message: "unsupported reasoning metadata")])
}

// Redacted reasoning parts (from `redacted_thinking` responses) replay as `redacted_thinking`.
@Test func anthropicAuditRedactedReasoningPartReplaysAsRedactedThinking() async throws {
    let result = try await auditMessages([
        AIMessage(role: .assistant, content: [
            .reasoning("", providerMetadata: ["anthropic": ["redactedData": "abc123"]]),
            .text("answer")
        ]),
        .user("next")
    ])
    #expect(result.body["messages"]?[0]?["content"] == [
        ["type": "redacted_thinking", "data": "abc123"],
        ["type": "text", "text": "answer"]
    ])
    #expect(result.warnings.isEmpty)
}

// "should omit reasoning parts without signature when sendReasoning is false"
@Test func anthropicAuditReasoningOmittedWhenSendReasoningIsFalse() async throws {
    let result = try await auditMessages(
        [AIMessage(role: .assistant, content: [
            .reasoning(strawberryReasoning, providerMetadata: ["anthropic": ["signature": "test-signature"]]),
            .text(strawberryAnswer)
        ])],
        providerOptions: ["anthropic": ["sendReasoning": false]]
    )
    #expect(result.body["messages"]?[0]?["content"] == [["type": "text", "text": .string(strawberryAnswer)]])
    #expect(result.warnings == [AIWarning(type: "other", message: "sending reasoning content is disabled for this model")])
}

// "should preserve citations on assistant text"
@Test func anthropicAuditAssistantTextReplaysCitations() async throws {
    let citation: JSONValue = [
        "type": "web_search_result_location",
        "cited_text": "The Committee decided to maintain the rate.",
        "url": "https://example.com/fed-decision",
        "title": "Federal Reserve decision",
        "encrypted_index": "encrypted-index"
    ]
    let result = try await auditMessages([
        AIMessage(role: .assistant, content: [
            .text("The Federal Reserve held rates steady.", providerMetadata: ["anthropic": ["citations": [citation]]])
        ]),
        .user("What happened before that?")
    ])
    #expect(result.body["messages"] == [
        ["role": "assistant", "content": [["type": "text", "text": "The Federal Reserve held rates steady.", "citations": [citation]]]],
        ["role": "user", "content": [["type": "text", "text": "What happened before that?"]]]
    ])
}

// "should omit an assistant message that only contains an empty compaction block"
@Test func anthropicAuditEmptyCompactionAssistantKeepsUserMessagesSeparate() async throws {
    let result = try await auditMessages([
        .user("first user message"),
        AIMessage(role: .assistant, content: [.text("", providerMetadata: ["anthropic": ["type": "compaction"]])]),
        .user("second user message")
    ])
    #expect(result.body["messages"] == [
        ["role": "user", "content": [["type": "text", "text": "first user message"]]],
        ["role": "user", "content": [["type": "text", "text": "second user message"]]]
    ])
}

// "should replay signed compaction blocks and add the beta header"; unsigned blocks do not add the beta.
@Test func anthropicAuditCompactionBetaOnlyForSignedBlocks() async throws {
    let signed = try await auditMessages([
        AIMessage(role: .assistant, content: [
            .text("Summary of the conversation.", providerMetadata: ["anthropic": ["type": "compaction", "signature": "compaction-signature"]])
        ]),
        .user("Continue the conversation.")
    ])
    #expect(signed.body["messages"]?[0]?["content"] == [
        ["type": "compaction", "content": "Summary of the conversation.", "signature": "compaction-signature"]
    ])
    #expect(signed.headers["anthropic-beta"]?.contains("compact-2026-09-04") == true)

    let unsigned = try await auditMessages([
        AIMessage(role: .assistant, content: [
            .text("Summary of the conversation.", providerMetadata: ["anthropic": ["type": "compaction"]])
        ]),
        .user("Continue the conversation.")
    ])
    #expect(unsigned.body["messages"]?[0]?["content"] == [["type": "compaction", "content": "Summary of the conversation."]])
    #expect(unsigned.headers["anthropic-beta"] == nil)
}

// "should remove trailing whitespace from last assistant message ..." (upstream trims the final prefill part)
@Test func anthropicAuditTrimsFinalAssistantPrefill() async throws {
    let result = try await auditMessages([
        .user("user content"),
        AIMessage(role: .assistant, content: [.text("assistant "), .text("  content  ")])
    ])
    #expect(result.body["messages"]?[1]?["content"] == [
        ["type": "text", "text": "assistant "],
        ["type": "text", "text": "content"]
    ])
}

// Base64 PDF documents use the filename as the title (`metadata.title ?? part.filename`).
@Test func anthropicAuditPDFDocumentUsesFilenameTitle() async throws {
    let pdf = Data("%PDF-1.4".utf8)
    let result = try await auditMessages([
        AIMessage(role: .user, content: [.file(mimeType: "application/pdf", data: pdf, filename: "report.pdf")])
    ])
    #expect(result.body["messages"]?[0]?["content"] == [[
        "type": "document",
        "source": ["type": "base64", "media_type": "application/pdf", "data": .string(pdf.base64EncodedString())],
        "title": "report.pdf"
    ]])
    #expect(result.headers["anthropic-beta"] == "pdfs-2024-09-25")
}

// Upstream skips approval and reasoning-file parts instead of sending empty text blocks.
@Test func anthropicAuditSkipsApprovalPartsWithoutEmptyTextBlocks() async throws {
    let result = try await auditMessages([
        .user("Hello"),
        AIMessage(role: .assistant, content: [
            .text("Checking."),
            .toolApprovalRequest(AIToolApprovalRequest(id: "approval-1", toolName: "lookup", arguments: "{}", toolCallID: "call-1"))
        ]),
        .user("Next")
    ])
    #expect(result.body["messages"]?[1]?["content"] == [["type": "text", "text": "Checking."]])
}

// MARK: - streaming

// "should stream text deltas": the message ID and response model are reported as response metadata.
@Test func anthropicAuditStreamReportsMessageResponseMetadata() async throws {
    let transport = RecordingTransport(response: sseResponse("""
    data: {"type":"message_start","message":{"id":"msg_01KfpJoAEabmH2iHRRFjQMAG","type":"message","role":"assistant","content":[],"model":"claude-3-haiku-20240307","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":17,"output_tokens":1}}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    data: {"type":"content_block_stop","index":0}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":227}}

    data: {"type":"message_stop"}
    """))
    let provider = try AIProviders.anthropic(configuration: AnthropicProviderSettings(apiKey: "test-api-key", transport: transport))
    var metadata: [AIResponseMetadata] = []
    for try await part in try provider.languageModel("claude-sonnet-4-5").stream(LanguageModelRequest(messages: [.user("Hello")])) {
        if case let .responseMetadata(value) = part { metadata.append(value) }
    }
    let last = try #require(metadata.last)
    #expect(last.id == "msg_01KfpJoAEabmH2iHRRFjQMAG")
    #expect(last.modelID == "claude-3-haiku-20240307")
}

// "should throw an api error when the first stream chunk is ..." with an unrecognized error type:
// upstream uses `isRetryable ?? false`.
@Test func anthropicAuditUnknownFirstStreamErrorIsNotRetryable() async throws {
    let transport = RecordingTransport(response: sseResponse("""
    event: error
    data: {"type":"error","error":{"type":"mystery_error","message":"Something odd"}}
    """))
    let provider = try AIProviders.anthropic(configuration: AnthropicProviderSettings(apiKey: "test-api-key", transport: transport))
    do {
        for try await _ in try provider.languageModel("claude-3-haiku-20240307").stream(LanguageModelRequest(messages: [.user("Hello")])) {}
        Issue.record("Expected an API call error")
    } catch let AIError.apiCall(error) {
        #expect(error.statusCode == 500)
        #expect(error.isRetryable == false)
    }
}
