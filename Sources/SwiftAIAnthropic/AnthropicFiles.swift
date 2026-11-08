import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

/// Anthropic Files upload, metadata, download and deletion. Uploads use buffered data.
public final class AnthropicFileClient: AIFileClient, Sendable {
    public let providerID: String
    private let providerReferenceKey: String
    private let config: AnthropicModelConfiguration

    public init(providerID: String = "anthropic.messages", config: AnthropicModelConfiguration) {
        self.providerID = providerID
        self.providerReferenceKey = "anthropic"
        self.config = config
    }

    /// Uses Anthropic's upload wire format for a hosting provider's namespace.
    public init(providerID: String, providerReferenceKey: String, config: AnthropicModelConfiguration) {
        self.providerID = providerID
        self.providerReferenceKey = providerReferenceKey
        self.config = config
    }

    public var supportedFileOperations: Set<AIFileOperation> { [.upload, .getMetadata, .download, .delete] }

    public func getFileMetadata(_ request: FileMetadataRequest) async throws -> FileMetadataResult {
        let path = try filePath(request.file)
        let headers = try await resolvedFileHeaders(request.headers)
        let (_, response) = try await getFromAPI(url: config.url("", path), transport: config.transport, headers: headers, abortSignal: request.abortSignal)
        guard (200..<300).contains(response.statusCode) else { throw anthropicHTTPStatusError(provider: providerID, response: response) }
        let raw = try response.jsonValue()
        let id = try responseFileID(raw)
        return FileMetadataResult(providerReference: [providerReferenceKey: id], filename: raw["filename"]?.stringValue, mediaType: raw["mime_type"]?.stringValue,
            byteSize: fileInteger(raw["size_bytes"]), createdAt: isoFileDate(raw["created_at"]), expiresAt: isoFileDate(raw["expires_at"]),
            providerMetadata: [providerReferenceKey: anthropicFileMetadata(raw)], rawValue: raw,
            requestMetadata: AIRequestMetadata(headers: request.headers), responseMetadata: aiResponseMetadata(from: raw, response: response))
    }

    public func downloadFile(_ request: FileDownloadRequest) async throws -> FileDownloadResult {
        let path = try filePath(request.file) + "/content"
        let headers = try await resolvedFileHeaders(request.headers)
        let (_, response) = try await getBinaryStreamFromAPI(url: config.url("", path), transport: config.transport, providerID: providerID, headers: headers, abortSignal: request.abortSignal, trustedOrigin: config.baseURL, credentialedOrigin: config.baseURL)
        let mediaType = response.headerValue("content-type")?.split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileDownloadResult(content: response.body, mediaType: mediaType?.isEmpty == false ? mediaType : nil,
            requestMetadata: AIRequestMetadata(headers: request.headers), responseMetadata: AIResponseMetadata(timestamp: Date(), headers: response.headers))
    }

    public func deleteFile(_ request: FileDeleteRequest) async throws -> FileDeleteResult {
        let path = try filePath(request.file)
        let headers = try await resolvedFileHeaders(request.headers)
        let httpRequest = AIHTTPRequest(method: "DELETE", url: try config.url("", path), headers: headers, abortSignal: request.abortSignal)
        try request.abortSignal?.throwIfAborted()
        let response = try await config.transport.send(httpRequest)
        guard (200..<300).contains(response.statusCode) else { throw anthropicHTTPStatusError(provider: providerID, response: response) }
        let raw = try response.jsonValue()
        return FileDeleteResult(providerReference: [providerReferenceKey: try responseFileID(raw, deleted: true)], deleted: true, rawValue: raw,
            requestMetadata: AIRequestMetadata(headers: request.headers), responseMetadata: aiResponseMetadata(from: raw, response: response))
    }

    private func filePath(_ file: [String: String]) throws -> String {
        guard let id = file[providerReferenceKey], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidArgument(argument: "file", message: "file reference is missing an '\(providerReferenceKey)' file id.")
        }
        return "/files/\(encodePathSegment(id))"
    }

    private func resolvedFileHeaders(_ headers: [String: String]) async throws -> [String: String] {
        var requestHeaders = normalizeHeaders(headers)
        requestHeaders["anthropic-beta"] = requestHeaders["anthropic-beta"] ?? "files-api-2025-04-14"
        return try await config.http.resolvedHeaders(requestHeaders)
    }

    private func responseFileID(_ raw: JSONValue, deleted: Bool = false) throws -> String {
        let expectedType = deleted ? "file_deleted" : "file"
        let strings = ["filename", "mime_type", "created_at", "expires_at"]
        guard strings.allSatisfy({ raw[$0] == nil || raw[$0] == .null || raw[$0]?.stringValue != nil }),
              raw["type"] == nil || raw["type"] == .null || raw["type"]?.stringValue == expectedType,
              raw["size_bytes"] == nil || raw["size_bytes"] == .null || raw["size_bytes"]?.doubleValue != nil,
              raw["downloadable"] == nil || raw["downloadable"] == .null || raw["downloadable"]?.boolValue != nil else {
            throw AIError.invalidResponse(provider: providerID, message: "Invalid Anthropic file metadata response.")
        }
        guard let id = raw["id"]?.stringValue else {
            throw AIError.invalidResponse(provider: providerID, message: "Invalid Anthropic file response: missing id.")
        }
        return id
    }

    private func isoFileDate(_ value: JSONValue?) -> Date? {
        guard let string = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }

    private func anthropicFileMetadata(_ raw: JSONValue) -> JSONValue {
        let keys = ["filename": "filename", "mime_type": "mimeType", "size_bytes": "sizeBytes", "created_at": "createdAt", "expires_at": "expiresAt", "downloadable": "downloadable"]
        return .object(Dictionary(uniqueKeysWithValues: keys.compactMap { key, mapped in
            guard let value = raw[key], value != .null else { return nil }
            return (mapped, value)
        }))
    }

    public func uploadFile(_ request: FileUploadRequest) async throws -> FileUploadResult {
        do {
            if request.fileData.isStream { throw unsupportedStreamingFileUpload(providerID: providerID) }
            let filename = request.filename ?? "blob"
            var form = MultipartFormData()
            form.appendFile(name: "file", fileName: filename, mimeType: request.mediaType, content: request.fileData)
            for (key, value) in request.extraBody.sorted(by: { $0.key < $1.key }) {
                if let scalar = jsonScalarString(value) { form.appendField(name: key, value: scalar) }
            }
            var headers = normalizeHeaders(request.headers)
            headers["anthropic-beta"] = headers["anthropic-beta"] ?? "files-api-2025-04-14"
            try request.abortSignal?.throwIfAborted()
            let response = try await config.transport.send(config.rawRequest(
                path: "/files", modelID: "", body: form.finalize(),
                contentType: "multipart/form-data; boundary=\(form.boundary)", headers: headers, abortSignal: request.abortSignal
            ))
            guard (200..<300).contains(response.statusCode) else { throw apiCallError(provider: providerID, response: response) }
            let raw = try response.jsonValue()
            return FileUploadResult(
                providerReference: [providerReferenceKey: try responseFileID(raw)],
                filename: raw["filename"]?.stringValue ?? request.filename,
                mediaType: raw["mime_type"]?.stringValue ?? request.mediaType,
                byteSize: fileInteger(raw["size_bytes"]), createdAt: isoFileDate(raw["created_at"]), expiresAt: isoFileDate(raw["expires_at"]),
                metadata: fileMetadata(from: raw), rawValue: raw,
                warnings: multipartFileUploadWarnings(request, includePurpose: false),
                providerMetadata: [providerReferenceKey: anthropicFileMetadata(raw)],
                requestMetadata: multipartFileUploadRequestMetadata(request, includePurpose: false, defaultFilename: filename, options: .init()),
                responseMetadata: aiResponseMetadata(from: raw, response: response)
            )
        } catch {
            await request.fileData.cancelStream()
            throw error
        }
    }
}
