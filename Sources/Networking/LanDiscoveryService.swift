import Foundation
import LinnaeusEngineClientSdkApple
import ProvinodeRoomContracts

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
        endpoints = ClientDiscoveryCore.rankEndpoints(Array(resolvedEndpointsByKey.values))
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
        let txtRecord = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        guard let endpoint = ClientDiscoveryCore.makeEndpoint(
            resolvedHost: sender.hostName,
            serviceName: sender.name,
            pairingPort: sender.port,
            txtRecord: txtRecord)
        else {
            return
        }

        resolvedEndpointsByKey[serviceKey] = endpoint
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
