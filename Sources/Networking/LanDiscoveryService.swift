import Foundation
import Network

@MainActor
final class LanDiscoveryService: ObservableObject {
    @Published private(set) var endpoints: [PairingEndpoint] = []

    private var browser: NWBrowser?

    func start() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_provinode-room._udp", domain: nil)
        let parameters = NWParameters()
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("LAN browse failed: \(error.localizedDescription)")
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.endpoints = results.compactMap { result in
                    guard case let .service(name, _, domain, _) = result.endpoint else {
                        return nil
                    }

                    let deviceId = name
                    let port = 7447
                    let host = "\(name).\(domain)"

                    return PairingEndpoint(
                        host: host,
                        port: port,
                        displayName: name,
                        desktopDeviceId: deviceId)
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        endpoints = []
    }
}
