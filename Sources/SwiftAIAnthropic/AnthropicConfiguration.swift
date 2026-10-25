import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

/// Anthropic authentication and Messages, Files, Skills and Batch options.
public struct AnthropicProviderSettings: Sendable {
    public var apiKey: String?
    public var authToken: String?
    public var baseURL: String?
    public var headers: [String: String]
    public var queryParams: [String: String]
    public var environment: [String: String]?
    public var transport: any AITransport
    public var transformRequestBody: (@Sendable ([String: JSONValue]) -> [String: JSONValue])?
    public var batchResultDownloads: AIBatchResultDownloadSettings?
    public var name: String?

    public init(apiKey: String? = nil, authToken: String? = nil, baseURL: String? = nil,
                headers: [String: String] = [:], queryParams: [String: String] = [:],
                environment: [String: String]? = nil, transport: any AITransport = URLSessionTransport.shared,
                transformRequestBody: (@Sendable ([String: JSONValue]) -> [String: JSONValue])? = nil,
                batchResultDownloads: AIBatchResultDownloadSettings? = nil, name: String? = nil) {
        self.apiKey = apiKey; self.authToken = authToken; self.baseURL = baseURL
        self.headers = headers; self.queryParams = queryParams; self.environment = environment
        self.transport = transport; self.transformRequestBody = transformRequestBody
        self.batchResultDownloads = batchResultDownloads; self.name = name
    }

    public func environmentValue(_ names: [String]) -> String? {
        let values = environment ?? ProcessInfo.processInfo.environment
        return names.compactMap { values[$0] }.first
    }
}

public extension AIProviders {
    static func anthropic(configuration: AnthropicProviderSettings = .init()) throws -> AnthropicProvider {
        try AnthropicProvider(configuration: configuration)
    }
}

/// The Messages wire adapter used by Anthropic and compatible hosting services.
/// Authentication and endpoint selection are supplied by the hosting provider.
public struct AnthropicModelConfiguration: Sendable {
    public var baseURL: String
    public var http: AIProviderHTTPClient
    public var transformRequestBody: (@Sendable ([String: JSONValue]) -> [String: JSONValue])?
    public var requestPolicy: (@Sendable (String) -> AnthropicRequestPolicy)?
    public var batchResultMaxLineBytes: Int?

    public init(baseURL: String, http: AIProviderHTTPClient,
                transformRequestBody: (@Sendable ([String: JSONValue]) -> [String: JSONValue])? = nil,
                batchResultMaxLineBytes: Int? = nil) {
        self.baseURL = withoutTrailingSlash(baseURL); self.http = http
        self.transformRequestBody = transformRequestBody; self.batchResultMaxLineBytes = batchResultMaxLineBytes
    }

    public init(providerID: String, baseURL: String, headers: [String: String], transport: any AITransport,
         queryParams: [String: String],
         transformRequestBody: (@Sendable ([String: JSONValue]) -> [String: JSONValue])?, batchResultMaxLineBytes: Int?) {
        let baseURL = withoutTrailingSlash(baseURL)
        self.init(baseURL: baseURL, http: AIProviderHTTPClient(
            providerID: providerID, headers: headers, transport: transport,
            url: { _, path in try providerURL("\(baseURL)\(path)", queryParams: queryParams) }
        ), transformRequestBody: transformRequestBody, batchResultMaxLineBytes: batchResultMaxLineBytes)
    }

    public var providerID: String { http.providerID }
    public var headers: [String: String] { http.headers }
    public var transport: any AITransport { http.transport }
    public var url: @Sendable (String, String) throws -> URL { http.url }
    public func withProviderID(_ providerID: String) -> Self { var copy = self; copy.http.providerID = providerID; return copy }
    public func request(path: String, modelID: String, body: JSONValue, headers: [String: String] = [:], abortSignal: AIAbortSignal? = nil) throws -> AIHTTPRequest {
        try http.request(path: path, modelID: modelID, body: body, headers: headers, abortSignal: abortSignal)
    }
    public func rawRequest(path: String, modelID: String, body: Data, contentType: String?, headers: [String: String] = [:], abortSignal: AIAbortSignal? = nil) throws -> AIHTTPRequest {
        try http.rawRequest(path: path, modelID: modelID, body: body, contentType: contentType, headers: headers, abortSignal: abortSignal)
    }
    public func streamRequest(_ request: AIHTTPRequest) async throws -> AIHTTPStreamResponse { try await http.streamRequest(request) }
}

/// Optional Messages wire differences for a hosting provider. Anthropic defaults
/// remain independent of the provider that supplies this policy.
public struct AnthropicRequestPolicy: Sendable {
    public var metadataNamespace: String = "anthropic"
    public var maximumTemperature: Double = 1
    public var supportsSamplingWithThinking: Bool = false
    public var prepareRequest: (@Sendable (LanguageModelRequest, String, inout [AIWarning]) throws -> LanguageModelRequest)?
    public var userMediaContent: (@Sendable (AIContentPart) throws -> JSONValue?)?
    public init() {}
}
