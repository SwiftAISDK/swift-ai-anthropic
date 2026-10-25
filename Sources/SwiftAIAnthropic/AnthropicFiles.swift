import Foundation
import SwiftAIProvider
import SwiftAITransport
import SwiftAIProviderUtilities

/// Anthropic Files upload. Streaming uploads and file management are not supported.
public final class AnthropicFileClient: AIFileClient, Sendable {
    public let providerID: String
    private let config: AnthropicModelConfiguration

    public init(providerID: String = "anthropic.messages", config: AnthropicModelConfiguration) {
        self.providerID = providerID
        self.config = config
    }

    public func getFileMetadata(_ request: FileMetadataRequest) async throws -> FileMetadataResult { throw unsupportedManagement() }
    public func downloadFile(_ request: FileDownloadRequest) async throws -> FileDownloadResult { throw unsupportedManagement() }
    public func deleteFile(_ request: FileDeleteRequest) async throws -> FileDeleteResult { throw unsupportedManagement() }
    private func unsupportedManagement() -> AIError {
        .invalidArgument(argument: "client", message: "The \(providerID) files client only supports file upload.")
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
            var headers = request.headers
            headers["anthropic-beta"] = headers["anthropic-beta"] ?? "files-api-2025-04-14"
            try request.abortSignal?.throwIfAborted()
            let response = try await config.transport.send(config.rawRequest(
                path: "/files", modelID: "", body: form.finalize(),
                contentType: "multipart/form-data; boundary=\(form.boundary)", headers: headers, abortSignal: request.abortSignal
            ))
            guard (200..<300).contains(response.statusCode) else { throw apiCallError(provider: providerID, response: response) }
            let raw = try response.jsonValue()
            return FileUploadResult(
                providerReference: ["anthropic": raw["id"]?.stringValue ?? raw["file"]?["id"]?.stringValue ?? ""],
                filename: raw["filename"]?.stringValue ?? request.filename,
                mediaType: raw["mime_type"]?.stringValue ?? request.mediaType,
                metadata: fileMetadata(from: raw), rawValue: raw,
                warnings: multipartFileUploadWarnings(request, includePurpose: false),
                providerMetadata: ["anthropic": fileProviderMetadata(from: raw)],
                requestMetadata: multipartFileUploadRequestMetadata(request, includePurpose: false, defaultFilename: filename, options: .init()),
                responseMetadata: aiResponseMetadata(from: raw, response: response)
            )
        } catch {
            await request.fileData.cancelStream()
            throw error
        }
    }
}
