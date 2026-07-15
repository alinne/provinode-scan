import CryptoKit
import Foundation
import LinnaeusEngineClientSdkApple
import ProvinodeRoomContracts
import Security

actor FinalizedCaptureSyncClient {
    struct Progress: Sendable {
        let uploadedFiles: Int
        let totalFiles: Int
    }

    func sync(
        session: RecordedSessionSummary,
        sourceDeviceId: String,
        endpoint: PairingEndpoint,
        pinnedFingerprintSha256: String,
        clientIdentity: ScanClientTlsIdentityMaterial,
        progress: @escaping @Sendable (Progress) async -> Void
    ) async throws -> FinalizedCaptureUploadCompleted {
        let files = try RecordedSessionLibrary.syncFiles(for: session)
        let delegate = try PinnedMutualTlsDelegate(
            expectedServerFingerprintSha256: pinnedFingerprintSha256,
            clientIdentity: clientIdentity)
        let urlSession = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { urlSession.finishTasksAndInvalidate() }

        let createRequest = FinalizedCaptureUploadCreateRequest(
            schema_version: RoomContractVersions.finalizedCaptureUpload,
            session_id: session.sessionId,
            source_device_id: sourceDeviceId,
            files: files.map(\.descriptor),
            auto_reconstruct: true,
            traceparent: ScanTraceContext.makeTraceparent(),
            correlation_id: UUID().uuidString.lowercased())
        var request = try makeRequest(endpoint: endpoint, path: "/capture-sync/uploads", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(createRequest)
        let created: FinalizedCaptureUploadCreated = try await send(request, using: urlSession)

        for (index, file) in files.enumerated() {
            let uploadId = try pathComponent(created.upload_id)
            let fileId = try pathComponent(file.descriptor.file_id)
            var uploadRequest = try makeRequest(
                endpoint: endpoint,
                path: "/capture-sync/uploads/\(uploadId)/files/\(fileId)",
                method: "PUT")
            uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue(String(file.descriptor.byte_size), forHTTPHeaderField: "Content-Length")
            let (_, response) = try await urlSession.upload(for: uploadRequest, fromFile: file.url)
            try validate(response: response, data: Data())
            await progress(Progress(uploadedFiles: index + 1, totalFiles: files.count))
        }

        let uploadId = try pathComponent(created.upload_id)
        let completeRequest = try makeRequest(
            endpoint: endpoint,
            path: "/capture-sync/uploads/\(uploadId)/complete",
            method: "POST")
        return try await send(completeRequest, using: urlSession)
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        using session: URLSession
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw NSError(
                domain: "FinalizedCaptureSyncClient",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: detail ?? "The desktop rejected the finalized capture."])
        }
    }

    private func makeRequest(endpoint: PairingEndpoint, path: String, method: String) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = endpoint.pairingScheme
        components.host = endpoint.host
        components.port = endpoint.port
        components.path = path
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60 * 30
        return request
    }

    private func pathComponent(_ value: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else {
            throw URLError(.badURL)
        }
        return encoded
    }
}

private final class PinnedMutualTlsDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedServerFingerprintSha256: String
    private let identity: SecIdentity
    private let certificateChain: [SecCertificate]

    init(
        expectedServerFingerprintSha256: String,
        clientIdentity: ScanClientTlsIdentityMaterial
    ) throws {
        self.expectedServerFingerprintSha256 = expectedServerFingerprintSha256
        var items: CFArray?
        let options: NSDictionary = [kSecImportExportPassphrase as String: clientIdentity.password]
        let status = SecPKCS12Import(clientIdentity.pkcs12Data as CFData, options, &items)
        guard status == errSecSuccess,
              let importedItems = items as? [[String: Any]],
              let first = importedItems.first,
              let rawIdentity = first[kSecImportItemIdentity as String]
        else {
            throw NSError(domain: "FinalizedCaptureSyncClient", code: 5201, userInfo: [NSLocalizedDescriptionKey: "The paired scanner identity could not be loaded."])
        }
        identity = rawIdentity as! SecIdentity
        certificateChain = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let serverTrust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let leaf = chain.first
            else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let certData = SecCertificateCopyData(leaf) as Data
            let digest = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(expectedServerFingerprintSha256) == .orderedSame else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))

        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(
                .useCredential,
                URLCredential(identity: identity, certificates: certificateChain, persistence: .forSession))

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
