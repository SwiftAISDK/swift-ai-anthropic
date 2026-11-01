import Foundation
import Testing
import SwiftAIProvider
import SwiftAITransport
@testable import SwiftAIAnthropic

private actor WeeklyTokenSupplier {
    var calls = 0
    func next() -> String { calls += 1; return "token-\(calls)" }
}

@Suite struct Weekly20261101AnthropicAuth {
    @Test func tokenSuppliersAreLazyRotateAndKeepBetaPrecedence() async throws {
        let tokens = WeeklyTokenSupplier()
        let transport = RecordingTransport(response: jsonResponse(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#))
        let provider = try AnthropicProvider(configuration: .init(headers: ["anthropic-beta": "provider-beta"], environment: [:], transport: transport, authTokenProvider: { await tokens.next() }))
        let model = try provider.languageModel("claude-3-haiku-20240307")
        #expect(await tokens.calls == 0)
        for _ in 0..<2 {
            _ = try await model.generate(.init(messages: [.user("Hi")], providerOptions: ["anthropic": ["anthropicBeta": ["feature-beta"]]], headers: ["anthropic-beta": "request-beta"]))
        }
        let requests = await transport.requests()
        #expect(await tokens.calls == 2)
        #expect(requests.map { $0.headers["authorization"] } == ["Bearer token-1", "Bearer token-2"])
        #expect(requests.allSatisfy { $0.headers["x-api-key"] == nil })
        #expect(requests.allSatisfy { Set(($0.headers["anthropic-beta"] ?? "").split(separator: ",").map(String.init)) == Set(["provider-beta", "request-beta", "feature-beta"]) })
    }

    @Test func eachStreamResolvesFreshToken() async throws {
        let tokens = WeeklyTokenSupplier()
        let transport = RecordingTransport(response: sseResponse("""
        data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}

        data: {"type":"message_stop"}
        """))
        let provider = try AnthropicProvider(configuration: .init(environment: [:], transport: transport, authTokenProvider: { await tokens.next() }))
        let model = try provider.languageModel("claude-3-haiku-20240307")
        for _ in 0..<2 { for try await _ in model.stream(.init(messages: [.user("Hi")])) {} }
        let requests = await transport.requests()
        #expect(requests.map { $0.headers["authorization"] } == ["Bearer token-1", "Bearer token-2"])
        #expect(requests.allSatisfy { $0.headers["anthropic-beta"] == nil })
    }

    @Test func filesAndSkillMetadataResolveIndependentTokens() async throws {
        let tokens = WeeklyTokenSupplier()
        let transport = RecordingTransport(responses: [jsonResponse(#"{"id":"file_1"}"#), jsonResponse(#"{"id":"skill_1","latest_version":"1"}"#), jsonResponse(#"{"name":"skill","description":"example"}"#)])
        let provider = try AnthropicProvider(configuration: .init(headers: ["anthropic-beta": "provider-beta"], environment: [:], transport: transport, authTokenProvider: { await tokens.next() }))
        _ = try await provider.files().uploadFile(.init(data: Data([1]), mediaType: "application/octet-stream", headers: ["anthropic-beta": "request-beta,files-api-2025-04-14"]))
        _ = try await provider.skills().uploadSkill(.init(files: [.init(path: "SKILL.md", data: Data("example".utf8))]))
        let requests = await transport.requests()
        #expect(requests.map { $0.headers["authorization"] } == ["Bearer token-1", "Bearer token-2", "Bearer token-3"])
        #expect(requests[0].headers["anthropic-beta"] == "request-beta,files-api-2025-04-14")
        #expect(requests[1].headers["anthropic-beta"] == "skills-2025-10-02")
        #expect(requests[2].headers["anthropic-beta"] == "skills-2025-10-02")
    }

    @Test func supplierErrorsPrecedeNetworkAndExplicitConflictsFail() async throws {
        enum TokenError: Error { case failed }
        let transport = RecordingTransport(response: jsonResponse("{}"))
        let provider = try AnthropicProvider(configuration: .init(environment: [:], transport: transport, authTokenProvider: { throw TokenError.failed }))
        await #expect(throws: TokenError.failed) {
            _ = try await provider.languageModel("claude-sonnet-4-6").generate(.init(messages: [.user("Hi")]))
        }
        #expect(await transport.requests().isEmpty)
        #expect(throws: (any Error).self) {
            _ = try AnthropicProvider(configuration: .init(apiKey: "key", authTokenProvider: { "token" }))
        }
    }
}
