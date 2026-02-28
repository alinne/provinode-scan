import SwiftUI

struct ContentView: View {
    @StateObject private var vm = CaptureViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Device policy") {
                    Text("iOS 17.0+ and LiDAR-capable iPhone Pro required")
                        .font(.footnote)
                    #if targetEnvironment(simulator)
                    Text("Simulator mode: synthetic capture data is used for M1/M2 end-to-end testing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #endif
                }

                Section("QR pairing") {
                    #if !targetEnvironment(simulator)
                    Button("Scan Desktop QR") {
                        vm.isQrScannerPresented = true
                    }
                    #else
                    Text("Simulator cannot use camera scanning. Paste QR payload JSON below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #endif

                    TextEditor(text: $vm.pairingQrPayloadJson)
                        .frame(minHeight: 110)
                        .font(.system(.footnote, design: .monospaced))
                    Button("Import QR payload") {
                        vm.applyPairingQrPayload(vm.pairingQrPayloadJson)
                    }

                    Button("Show calibration pattern") {
                        vm.isCalibrationPatternPresented = true
                    }
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
                    TextField("QUIC port", text: $vm.manualQuicPort)
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
        .sheet(isPresented: $vm.isQrScannerPresented) {
            QrScannerView { value in
                vm.onQrScanResult(value)
            }
        }
        .sheet(isPresented: $vm.isCalibrationPatternPresented) {
            CalibrationPatternView()
        }
        .task {
            await vm.startDiscovery()
        }
        .onDisappear {
            vm.stopDiscovery()
        }
    }
}
