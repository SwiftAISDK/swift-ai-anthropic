import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
@testable import SwiftAIAnthropic

private actor WeeklyExtractionTransport: AITransport {
    private var sent: [AIHTTPRequest] = []
    func requests() -> [AIHTTPRequest] { sent }
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        sent.append(request)
        let body = try decodeJSONBody(request.body!)
        let prompt = try decodeJSONBody(Data(body["messages"]![0]!["content"]![0]!["text"]!.stringValue!.utf8))
        let fields = prompt["fields"]!.objectValue!
        let values = fields.mapValues { value -> JSONValue in
            .number(Double(value["id"]!.stringValue!.split(separator: " ").last!)!)
        }
        let text = String(decoding: try encodeJSONBody(.object(values)), as: UTF8.self)
        let raw: JSONValue = ["type": "message", "role": "assistant", "id": "msg", "content": [["type": "text", "text": .string(text)]], "stop_reason": "end_turn", "usage": ["input_tokens": 1, "output_tokens": 2]]
        return .init(statusCode: 200, body: try encodeJSONBody(raw))
    }
}

@Suite struct Weekly20261114ExtractionTests {
    @Test func messagesExtractionSplitsFieldsAtSixteenAndRetainsProviderIdentity() async throws {
        let transport = WeeklyExtractionTransport()
        let provider = try AnthropicProvider(configuration: .init(apiKey: "key", transport: transport, name: "custom.messages"))
        let model = try provider.extractionModel("claude-sonnet-5-5")
        let fields = Dictionary(uniqueKeysWithValues: (0..<17).map { ("price \($0)", AIExtractionField(type: .number)) })
        let result = try await model.doExtract(.init(state: [.text("Prices")], fields: fields))
        #expect(model.providerID == "custom.extraction")
        #expect(provider.supportedCapabilities.contains(.extraction))
        #expect(result.answers.count == 17)
        #expect(result.answers["price 0"]?.value == 0)
        #expect(result.answers["price 16"]?.value == 16)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        let bodies = try requests.map { try decodeJSONBody($0.body!) }
        #expect(bodies.compactMap { $0["output_config"]?["format"]?["schema"]?["properties"]?.objectValue?.count }.sorted() == [1, 16])
        #expect(requests.allSatisfy { $0.url.path == "/v1/messages" || $0.url.path == "/messages" })
    }

    @Test func fableFiveTwoGetsTheSameAdaptiveAndForcedToolPolicyAsFiveOne() throws {
        let capabilities = anthropicModelCapabilities("claude-fable-5-2")
        #expect(capabilities.isKnownModel)
        #expect(capabilities.maxOutputTokens == 128000)
        #expect(capabilities.rejectsThinkingDisabled)
        #expect(capabilities.rejectsBudgetThinking)
        #expect(capabilities.rejectsForcedToolUse)
        #expect(capabilities.supportsXhighEffort)
        let forced = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hello")], tools: ["lookup": ["type": "object", "properties": [:]]], toolChoice: ["type": "required"]), modelID: "claude-fable-5-2", providerID: "anthropic.messages")
        #expect(forced.body["tool_choice"] == ["type": "auto"])
        let thinking = try AnthropicLanguageModel.body(for: .init(messages: [.user("Hello")], providerOptions: ["anthropic": ["thinking": ["type": "disabled"], "effort": "xhigh"]]), modelID: "claude-fable-5-2", providerID: "anthropic.messages")
        #expect(thinking.body["thinking"] == nil)
        #expect(thinking.body["max_tokens"] == 128000)
        #expect(thinking.body["output_config"]?["effort"] == "xhigh")
        #expect(thinking.warnings.contains { $0.feature == "providerOptions.anthropic.thinking" })
    }

    @Test func datedBaseFableFiveDoesNotInheritFiveTwoForcedToolRestrictions() {
        for id in ["claude-fable-5", "anthropic.claude-fable-5-20260601-v1:0", "us.anthropic.claude-fable-5-20260601-v1:0"] {
            #expect(!anthropicModelCapabilities(id).rejectsForcedToolUse)
        }
        for id in ["claude-fable-5-1", "claude-fable-5-2", "us.anthropic.claude-fable-5-1-20261101-v1:0", "anthropic.claude-fable-5-2-20261110-v1:0"] {
            #expect(anthropicModelCapabilities(id).rejectsForcedToolUse)
        }
    }
}
