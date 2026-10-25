import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities
public final class AnthropicSkillsClient: AISkillsClient, @unchecked Sendable {
    public let providerID: String
    private let providerReferenceKey: String
    private let config: AnthropicModelConfiguration

    public init(providerID: String, providerReferenceKey: String, config: AnthropicModelConfiguration) {
        self.providerID = providerID
        self.providerReferenceKey = providerReferenceKey
        self.config = config
    }

    public func uploadSkill(_ request: SkillUploadRequest) async throws -> SkillUploadResult {
        var form = MultipartFormData()
        if let displayTitle = request.displayTitle {
            form.appendField(name: "display_title", value: displayTitle)
        }
        for file in request.files {
            form.appendFile(name: "files[]", fileName: file.path, mimeType: file.mediaType, data: file.data)
        }

        let headers = request.headers.mergingHeaders(["anthropic-beta": "skills-2025-10-02"])
        let response = try await config.transport.send(config.rawRequest(
            path: "/skills",
            modelID: "",
            body: form.finalize(),
            contentType: "multipart/form-data; boundary=\(form.boundary)",
            headers: headers,
            abortSignal: request.abortSignal
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw apiCallError(provider: providerID, response: response)
        }

        let raw = try response.jsonValue()
        let versionMetadata = try await fetchVersionMetadata(
            skillID: raw["id"]?.stringValue,
            version: raw["latest_version"]?.stringValue,
            headers: headers,
            abortSignal: request.abortSignal
        )
        let metadata = anthropicSkillMetadata(from: raw)

        return SkillUploadResult(
            providerReference: [providerReferenceKey: raw["id"]?.stringValue ?? ""],
            displayTitle: raw["display_title"]?.stringValue,
            name: versionMetadata.name ?? raw["name"]?.stringValue,
            description: versionMetadata.description ?? raw["description"]?.stringValue,
            latestVersion: raw["latest_version"]?.stringValue,
            providerMetadata: metadata.isEmpty ? [:] : [providerReferenceKey: .object(metadata)],
            requestMetadata: skillUploadRequestMetadata(request, includeDisplayTitle: true),
            responseMetadata: aiResponseMetadata(from: raw, response: response),
            warnings: [],
            rawValue: raw
        )
    }

    private func fetchVersionMetadata(skillID: String?, version: String?, headers: [String: String], abortSignal: AIAbortSignal?) async throws -> (name: String?, description: String?) {
        guard let skillID, let version else {
            return (nil, nil)
        }
        let encodedSkillID = anthropicSkillPathSegment(skillID)
        let encodedVersion = anthropicSkillPathSegment(version)
        let response = try await config.transport.send(AIHTTPRequest(
            method: "GET",
            url: try requireURL("\(withoutTrailingSlash(config.baseURL))/skills/\(encodedSkillID)/versions/\(encodedVersion)"),
            headers: config.headers.mergingHeaders(headers),
            body: nil,
            abortSignal: abortSignal
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw apiCallError(provider: providerID, response: response)
        }
        let raw = try response.jsonValue()
        return (raw["name"]?.stringValue, raw["description"]?.stringValue)
    }
}
private func anthropicSkillPathSegment(_ value: String) -> String {
    encodePathSegment(value)
}
private func anthropicSkillMetadata(from raw: JSONValue) -> [String: JSONValue] {
    var metadata: [String: JSONValue] = [:]
    if let source = raw["source"] {
        metadata["source"] = source
    }
    if let createdAt = raw["created_at"] {
        metadata["createdAt"] = createdAt
    }
    if let updatedAt = raw["updated_at"] {
        metadata["updatedAt"] = updatedAt
    }
    return metadata
}
