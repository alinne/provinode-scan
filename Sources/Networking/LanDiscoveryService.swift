import Foundation

@MainActor
final class LanDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var endpoints: [PairingEndpoint] = []

    private let browser = NetServiceBrowser()
    private var servicesByKey: [String: NetService] = [:]
    private var resolvedEndpointsByKey: [String: PairingEndpoint] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        stop()
        browser.searchForServices(ofType: "_provinode-room._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        for service in servicesByKey.values {
            service.delegate = nil
            service.stop()
        }
        servicesByKey.removeAll()
        resolvedEndpointsByKey.removeAll()
        endpoints = []
    }

    private func key(for service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func refreshPublishedEndpoints() {
        endpoints = resolvedEndpointsByKey.values.sorted {
            if $0.displayName == $1.displayName {
                return $0.host < $1.host
            }
            return $0.displayName < $1.displayName
        }
    }

    private func txtValue(_ key: String, from record: [String: Data]) -> String? {
        guard let value = record[key], !value.isEmpty else {
            return nil
        }
        return String(data: value, encoding: .utf8)
    }
}

@MainActor extension LanDiscoveryService: @preconcurrency NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let serviceKey = key(for: service)
        servicesByKey[serviceKey] = service
        service.delegate = self
        service.resolve(withTimeout: 5.0)

        if !moreComing {
            refreshPublishedEndpoints()
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let serviceKey = key(for: service)
        servicesByKey[serviceKey]?.stop()
        servicesByKey.removeValue(forKey: serviceKey)
        resolvedEndpointsByKey.removeValue(forKey: serviceKey)

        if !moreComing {
            refreshPublishedEndpoints()
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        StructuredLog.emit(
            event: "lan_browse_failed",
            level: "error",
            fields: ["error": String(describing: errorDict)])
    }
}

@MainActor extension LanDiscoveryService: @preconcurrency NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let serviceKey = key(for: sender)

        guard var host = sender.hostName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }

        let pairingPort = sender.port > 0 ? sender.port : 7448
        let txtRecord = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let displayName = txtValue("display_name", from: txtRecord) ?? sender.name
        let desktopDeviceId = txtValue("device_id", from: txtRecord) ?? sender.name
        let quicPort = Int(txtValue("quic_port", from: txtRecord) ?? "") ?? 7447
        let pairingScheme = (txtValue("pairing_scheme", from: txtRecord) ?? "https").lowercased()
        let pairingCertFingerprintSha256 = txtValue("pairing_cert_fingerprint_sha256", from: txtRecord)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        resolvedEndpointsByKey[serviceKey] = PairingEndpoint(
            host: host,
            port: pairingPort,
            quicPort: quicPort,
            pairingScheme: pairingScheme,
            pairingCertFingerprintSha256: pairingCertFingerprintSha256,
            displayName: displayName,
            desktopDeviceId: desktopDeviceId)
        refreshPublishedEndpoints()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let serviceKey = key(for: sender)
        resolvedEndpointsByKey.removeValue(forKey: serviceKey)
        refreshPublishedEndpoints()
        StructuredLog.emit(
            event: "lan_service_resolve_failed",
            level: "error",
            fields: ["error": String(describing: errorDict)])
    }
}
