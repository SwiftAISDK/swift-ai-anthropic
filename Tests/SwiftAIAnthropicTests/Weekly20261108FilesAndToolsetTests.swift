import Foundation
import Testing
@testable import SwiftAIAnthropic
import SwiftAIProvider
import SwiftAITransport

@Suite struct Weekly20261108FilesAndToolset {
    @Test func filesExposeManagementMetadataAndMinimalUploadResponses() async throws {
        let transport = RecordingTransport(responses: [
            jsonResponse(#"{"id":"file_1","filename":"test.pdf","mime_type":"application/pdf","size_bytes":123,"created_at":"2025-04-14T12:00:00Z","expires_at":"2026-12-01T00:00:00Z","downloadable":true}"#),
            jsonResponse(#"{"id":"file_2"}"#),
            jsonResponse(#"{"id":"file_3","type":"file_deleted"}"#)
        ])
        let files = try AIProviders.anthropic(configuration: .init(apiKey: "key", transport: transport)).files()
        #expect(files.supportedFileOperations == [.upload, .getMetadata, .download, .delete])
        let metadata = try await files.getFileMetadata(.init(file: ["anthropic": "folder/id? #"], headers: ["Anthropic-Beta": "custom-beta"]))
        #expect(metadata.byteSize == 123)
        #expect(metadata.createdAt != nil && metadata.expiresAt != nil)
        #expect(metadata.providerMetadata["anthropic"]?["expiresAt"] == "2026-12-01T00:00:00Z")
        let upload = try await files.uploadFile(.init(data: Data([1]), mediaType: "application/pdf", filename: "supplied.pdf"))
        #expect(upload.providerReference == ["anthropic": "file_2"])
        #expect(upload.filename == "supplied.pdf" && upload.mediaType == "application/pdf")
        #expect(upload.byteSize == nil && upload.createdAt == nil)
        #expect(upload.providerMetadata["anthropic"] == .object([:]))
        let deleted = try await files.deleteFile(.init(file: ["anthropic": "file_3"]))
        #expect(deleted.deleted && deleted.providerReference == ["anthropic": "file_3"])
        let requests = await transport.requests()
        #expect(requests.map(\.method) == ["GET", "POST", "DELETE"])
        #expect(requests[0].url.absoluteString == "https://api.anthropic.com/v1/files/folder%2Fid%3F%20%23")
        #expect(requests[0].headers["anthropic-beta"] == "custom-beta")
        #expect(requests[2].headers["anthropic-beta"] == "files-api-2025-04-14")
    }

    @Test func fileDownloadsStreamBytesWithMediaTypeAndValidateReference() async throws {
        let transport = RecordingTransport(response: AIHTTPResponse(statusCode: 200, headers: ["content-type": "text/plain; charset=utf-8"], body: Data("content".utf8)))
        let files = try AIProviders.anthropic(configuration: .init(apiKey: "key", transport: transport)).files()
        await #expect(throws: AIError.self) { try await files.getFileMetadata(.init(file: ["anthropic": "   "])) }
        #expect(await transport.requests().isEmpty)
        let result = try await files.downloadFile(.init(file: ["anthropic": "file_1"]))
        var bytes = Data()
        for try await chunk in result.content { bytes.append(chunk) }
        #expect(bytes == Data("content".utf8))
        #expect(result.mediaType == "text/plain")
        #expect(await transport.requests().first?.url.absoluteString == "https://api.anthropic.com/v1/files/file_1/content")
    }

    @Test func filesRefreshCredentialsForEachManagementOperationAndPreserveErrors() async throws {
        actor Credentials { var count = 0; func key() -> String { count += 1; return "token-\(count)" } }
        let credentials = Credentials()
        let response = AIHTTPResponse(statusCode: 404, headers: [:], body: Data(#"{"type":"error","error":{"type":"not_found_error","message":"File not found","details":{"error_code":"missing"}}}"#.utf8))
        let transport = RecordingTransport(response: response)
        let files = try AIProviders.anthropic(configuration: .init(transport: transport, authTokenProvider: { await credentials.key() })).files()
        await #expect(throws: AIError.self) { try await files.getFileMetadata(.init(file: ["anthropic": "missing"])) }
        await #expect(throws: AIError.self) { try await files.downloadFile(.init(file: ["anthropic": "missing"])) }
        await #expect(throws: AIError.self) { try await files.deleteFile(.init(file: ["anthropic": "missing"])) }
        #expect(await credentials.count == 3)
        #expect(await transport.requests().map { $0.headers["authorization"] } == ["Bearer token-1", "Bearer token-2", "Bearer token-3"])
    }

    @Test func computerToolsetSchemaAndResponsesExcludeDisabledOrUnknownMembers() async throws {
        let tool = AnthropicTools.computerToolset_20260801(configs: ["screenshot": ["enabled": false]])
        #expect(tool["inputSchema"]?["properties"]?["action"]?["enum"]?.arrayValue?.contains("screenshot") == false)
        let wire: [JSONValue] = [["type": "computer_toolset_20260801", "configs": ["screenshot": ["enabled": false]]]]
        for name in ["screenshot", "unknown"] {
            #expect(throws: AIError.self) { try anthropicValidateToolsetBlocks([["type": "tool_use", "toolset_name": "computer", "name": .string(name), "input": [:]]], tools: wire, providerID: "anthropic") }
        }
        #expect(throws: AIError.self) { try anthropicValidateToolsetBlocks([["type": "tool_use", "toolset_name": "computer", "name": "scroll", "input": []]], tools: wire, providerID: "anthropic") }
        let valid: JSONValue = ["type": "tool_use", "id": "tool_1", "toolset_name": "computer", "name": "scroll", "input": ["action": "spoof", "scroll_amount": 2]]
        try anthropicValidateToolsetBlocks([valid], tools: wire, providerID: "anthropic")
        #expect(anthropicToolCall(from: valid)?.arguments.contains("scroll") == true)
    }

    @Test(arguments: ["{", "null", "[]", "1", "\"text\""]) func streamedComputerToolsetRejectsNonObjectInput(input: String) {
        var calls = AnthropicStreamingToolCalls(providerID: "anthropic")
        _ = calls.apply(event: ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "tool_1", "toolset_name": "computer", "name": "scroll", "input": [:]]])
        _ = calls.apply(event: ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": .string(input)]])
        let parts = calls.apply(event: ["type": "content_block_stop", "index": 0])
        #expect(calls.validationError != nil)
        #expect(!parts.contains { if case .toolCall = $0 { true } else { false } })
    }

    @Test(arguments: [false, true]) func continuationValidatesToolsetAndPreservesTheReturnedAction(streaming: Bool) async throws {
        let block: JSONValue = ["type": "tool_use", "id": "tool_1", "toolset_name": "computer", "name": "screenshot", "input": ["action": "wait", "duration": 0]]
        let response: AIHTTPResponse
        if streaming {
            let events: [JSONValue] = [
                ["type": "message_start", "message": ["id": "one", "usage": ["input_tokens": 1]]],
                ["type": "content_block_start", "index": 0, "content_block": block],
                ["type": "content_block_stop", "index": 0],
                ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 1]],
                ["type": "message_stop"]
            ]
            response = sseResponse(try events.map { "data: " + String(decoding: try encodeJSONBody($0), as: UTF8.self) }.joined(separator: "\n\n"))
        } else {
            response = jsonResponse(String(decoding: try encodeJSONBody(["content": [block], "stop_reason": "tool_use", "usage": ["input_tokens": 1, "output_tokens": 1]]), as: UTF8.self))
        }
        let transport = RecordingTransport(response: response)
        let model = try AIProviders.anthropic(configuration: .init(apiKey: "key", transport: transport)).languageModel("claude-opus-5-5")
        let request = LanguageModelRequest(messages: [.user("Next")], tools: ["desktop": AnthropicTools.computerToolset_20260801(configs: ["wait": ["enabled": false]])], providerOptions: ["anthropic": ["thread": ["type": "continue", "previousMessageId": "previous"]]])
        let calls: [AIToolCall]
        if streaming {
            var found: [AIToolCall] = []
            for try await part in model.stream(request) { if case let .toolCall(call) = part { found.append(call) } }
            calls = found
        } else { calls = try await model.generate(request).toolCalls }
        let call = try #require(calls.first)
        #expect(call.name == "desktop")
        #expect(try decodeJSONBody(Data(call.arguments.utf8))["action"] == "screenshot")
        let body = try decodeJSONBody(try #require(await transport.requests().first?.body))
        #expect(body["tools"] == nil)
    }
}
