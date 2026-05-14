import CryptoKit
import Foundation
import LinnaeusEngineClientSdkApple
import ProvinodeRoomContracts
import Security

protocol EngineRoomAuthorityClientProtocol: Sendable {
    func startPairing(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse
    func getActivePairing(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse
    func confirmPairing(
        endpoint: PairingEndpoint,
        requestBody: PairingConfirmRequest
    ) async throws -> PairingConfirmResult
    func importCapturedRoomAsset(
        endpoint: PairingEndpoint,
        contentType: String,
        payload: Data
    ) async throws -> EngineRoomAuthorityImportResponse
}

struct EngineRoomAuthorityImportResponse: Sendable {
    let data: Data
    let rawResponse: HTTPURLResponse
}

actor EngineRoomAuthorityClient: EngineRoomAuthorityClientProtocol {
    private enum Route {
        static let roomId = "default-room"
        static let startPairing = "/engine/v1/production-space/rooms/\(roomId)/authority/pairing/start"
        static let activePairing = "/engine/v1/production-space/rooms/\(roomId)/authority/pairing/active"
        static let confirmPairing = "/engine/v1/production-space/rooms/\(roomId)/authority/pairing/confirm"
        static let importCapturedAsset = "/engine/v1/production-space/rooms/\(roomId)/authority/captured-assets/import"
    }

    private let transport: any PairingRequestTransport
    private let traceparentProvider: @Sendable () -> String

    init(
        transport: any PairingRequestTransport = URLSessionPairingRequestTransport(),
        traceparentProvider: @escaping @Sendable () -> String = { ScanTraceContext.makeTraceparent() }
    ) {
        self.transport = transport
        self.traceparentProvider = traceparentProvider
    }

    func startPairing(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        let response = try await send(
            endpoint: endpoint,
            method: "POST",
            path: Route.startPairing,
            outputSafetyMode: "safe")
        return try ClientPairingCore.decodeSessionStatusResponse(from: response)
    }

    func getActivePairing(endpoint: PairingEndpoint) async throws -> PairingSessionStatusResponse {
        let response = try await send(
            endpoint: endpoint,
            method: "GET",
            path: Route.activePairing,
            outputSafetyMode: "safe")
        return try ClientPairingCore.decodeSessionStatusResponse(from: response)
    }

    func confirmPairing(
        endpoint: PairingEndpoint,
        requestBody: PairingConfirmRequest
    ) async throws -> PairingConfirmResult {
        let requestData = try JSONEncoder().encode(requestBody)
        let response = try await send(
            endpoint: endpoint,
            method: "POST",
            path: Route.confirmPairing,
            contentType: "application/json",
            body: requestData)
        return try ClientPairingCore.decodeConfirmResult(from: response)
    }

    func importCapturedRoomAsset(
        endpoint: PairingEndpoint,
        contentType: String,
        payload: Data
    ) async throws -> EngineRoomAuthorityImportResponse {
        let response = try await send(
            endpoint: endpoint,
            method: "POST",
            path: Route.importCapturedAsset,
            contentType: contentType,
            body: payload)
        return EngineRoomAuthorityImportResponse(data: response.data, rawResponse: response.response)
    }
}

private extension EngineRoomAuthorityClient {
    func send(
        endpoint: PairingEndpoint,
        method: String,
        path: String,
        outputSafetyMode: String? = nil,
        contentType: String? = nil,
        body: Data? = nil
    ) async throws -> PairingTransportResponse {
        var request = try ClientPairingCore.makeRequest(
            endpoint: endpoint,
            method: method,
            path: path,
            traceparent: traceparentProvider(),
            outputSafetyMode: outputSafetyMode)
        if let contentType, !contentType.isEmpty {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        return try await transport.send(
            request,
            pinnedFingerprintSha256: ClientPairingCore.validatedPinnedFingerprint(from: endpoint))
    }
}

final class URLSessionPairingRequestTransport: PairingRequestTransport {
    func send(_ request: URLRequest, pinnedFingerprintSha256: String) async throws -> PairingTransportResponse {
        let session = URLSession(
            configuration: .ephemeral,
            delegate: PinnedTlsDelegate(expectedFingerprintSha256: pinnedFingerprintSha256),
            delegateQueue: nil)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PairingError.serverRejected(nil)
        }

        return PairingTransportResponse(data: data, response: httpResponse)
    }
}

private final class PinnedTlsDelegate: NSObject, URLSessionDelegate {
    private let expectedFingerprintSha256: String

    init(expectedFingerprintSha256: String) {
        self.expectedFingerprintSha256 = expectedFingerprintSha256
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certData = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(expectedFingerprintSha256) == .orderedSame else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
