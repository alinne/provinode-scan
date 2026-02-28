import SwiftUI

struct ContentView: View {
    @StateObject private var vm = CaptureViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Device policy") {
                    Text("iOS 17.0+ and LiDAR-capable iPhone Pro required")
                        .font(.footnote)
                }

                Section("Desktop endpoint") {
                    if vm.discoveredEndpoints.isEmpty {
                        Text("No desktop receiver discovered")
                            .foregroundStyle(.secondary)
                    }

                    Picker("Receiver", selection: $vm.selectedEndpoint) {
                        ForEach(vm.discoveredEndpoints, id: \.self) { endpoint in
                            Text("\(endpoint.displayName) (\(endpoint.host):\(endpoint.port))")
                                .tag(Optional(endpoint))
                        }
                    }

                    TextField("Manual host (e.g. 192.168.1.10)", text: $vm.manualHost)
                        .textInputAutocapitalization(.never)
                    TextField("Pairing port", text: $vm.manualPort)
                        .keyboardType(.numberPad)
                    TextField("Manual pairing cert fingerprint (sha256)", text: $vm.manualPairingFingerprintSha256)
                        .textInputAutocapitalization(.never)

                    TextField("Pairing code", text: $vm.pairingCode)
                        .keyboardType(.numberPad)
                    TextField("Pairing nonce", text: $vm.pairingNonce)
                        .textInputAutocapitalization(.never)

                    Button("Pair") {
                        Task { await vm.pair() }
                    }
                }

                Section("Capture") {
                    if vm.isCapturing {
                        Button("Stop capture") {
                            Task { await vm.stopCapture() }
                        }
                        .tint(.red)
                    } else {
                        Button("Start capture") {
                            Task { await vm.startCapture() }
                        }
                    }

                    LabeledContent("Status", value: vm.status)
                    LabeledContent("Samples", value: "\(vm.metrics.emittedSamples)")
                    LabeledContent("Drops", value: "\(vm.metrics.droppedSamples)")
                    LabeledContent("Keyframes", value: "\(vm.metrics.keyframeCount)")
                    LabeledContent("Depth", value: "\(vm.metrics.depthCount)")
                    LabeledContent("Mesh", value: "\(vm.metrics.meshCount)")
                }

                if let session = vm.lastSessionDirectory {
                    Section("Last recording") {
                        Text(session.path)
                            .font(.footnote)
                            .textSelection(.enabled)
                        Button("Export package") {
                            vm.exportLastSession()
                        }
                    }
                }

                if let exportPath = vm.lastExportPath {
                    Section("Last export") {
                        Text(exportPath.path)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Provinode Scan")
        }
        .task {
            await vm.startDiscovery()
        }
        .onDisappear {
            vm.stopDiscovery()
        }
    }
}
