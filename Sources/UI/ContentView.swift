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
                        Task { await vm.applyPairingQrPayload(vm.pairingQrPayloadJson) }
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
                    TextField("Manual QUIC host (optional)", text: $vm.manualQuicHost)
                        .textInputAutocapitalization(.never)
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
                    LabeledContent("Capture state", value: vm.captureState.rawValue)
                    LabeledContent("Safe to stop", value: vm.safeToStop ? "yes" : "no")
                    LabeledContent("Guidance", value: vm.captureCoaching)
                    LabeledContent("Samples", value: "\(vm.metrics.emittedSamples)")
                    LabeledContent("Drops", value: "\(vm.metrics.droppedSamples)")
                    LabeledContent("Keyframes", value: "\(vm.metrics.keyframeCount)")
                    LabeledContent("Depth", value: "\(vm.metrics.depthCount)")
                    LabeledContent("Mesh", value: "\(vm.metrics.meshCount)")
                    LabeledContent("Duration", value: String(format: "%.1fs", vm.metrics.captureDurationSeconds))
                    LabeledContent("Pose confidence", value: String(format: "%.2f", vm.metrics.poseConfidence))
                    LabeledContent("Avg keyframe fps", value: String(format: "%.2f", vm.metrics.avgKeyframeFps))
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

                Section("Recorded sessions") {
                    HStack {
                        Button("Refresh session library") {
                            Task { await vm.refreshSessionLibrary() }
                        }
                        Button("Export all filtered") {
                            vm.exportAllSessions()
                        }
                        Spacer()
                        Text("\(vm.filteredRecordedSessions.count) shown / \(vm.recordedSessions.count) total")
                            .foregroundStyle(.secondary)
                    }

                    TextField("Filter sessions", text: $vm.sessionLibraryFilter)
                        .textInputAutocapitalization(.never)
                    Text("Export root: \(vm.exportRootPath.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if vm.filteredRecordedSessions.isEmpty {
                        Text("No recorded sessions yet")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Selected session", selection: $vm.selectedRecordedSessionId) {
                            ForEach(vm.filteredRecordedSessions, id: \.sessionId) { session in
                                Text("\(session.sessionId) (\(session.integrityStatus))")
                                    .tag(session.sessionId)
                            }
                        }

                        if let session = vm.selectedRecordedSessionSummary {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Selected: \(session.sessionId)")
                                    .font(.footnote.monospaced())
                                Text("device \(session.sourceDeviceId)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("samples \(session.sampleCount) | blobs \(session.blobCount) | duration \(session.durationSummary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("integrity \(session.integrityStatus) | exported \(session.exported ? "yes" : "no")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let exportPath = session.exportPath {
                                    Text(exportPath.path)
                                        .font(.caption2.monospaced())
                                        .textSelection(.enabled)
                                }
                                Button("Export selected session") {
                                    vm.exportSession(sessionId: session.sessionId)
                                }
                            }
                        }

                        ForEach(vm.filteredRecordedSessions.prefix(5), id: \.sessionId) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.sessionId)
                                    .font(.footnote.monospaced())
                                Text("samples \(session.sampleCount) | blobs \(session.blobCount) | duration \(session.durationSummary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("integrity \(session.integrityStatus) | exported \(session.exported ? "yes" : "no")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Export this session") {
                                    vm.exportSession(sessionId: session.sessionId)
                                }
                            }
                        }
                    }
                }

                Section("Trusted desktops") {
                    HStack {
                        Button("Refresh trust") {
                            Task { await vm.refreshTrustRecords() }
                        }
                        Button("Reset trust") {
                            Task { await vm.resetTrustedDesktops() }
                        }
                    }

                    TextField("Filter trusted desktops", text: $vm.trustFilter)
                        .textInputAutocapitalization(.never)

                    if vm.filteredTrustedPeers.isEmpty {
                        Text("No trusted desktops yet")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Selected desktop", selection: $vm.selectedTrustDeviceId) {
                            ForEach(vm.filteredTrustedPeers, id: \.peer_device_id) { peer in
                                Text("\(peer.peer_display_name) (\(peer.status))")
                                    .tag(peer.peer_device_id)
                            }
                        }

                        Button("Revoke selected desktop") {
                            Task { await vm.revokeTrustedDesktop() }
                        }

                        if let peer = vm.selectedTrustRecord {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Selected: \(peer.peer_display_name)")
                                Text(peer.peer_device_id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("fingerprint \(peer.peer_cert_fingerprint_sha256)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text("status \(peer.status) | last seen \(peer.last_seen_at_utc)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(vm.filteredTrustedPeers.prefix(5), id: \.peer_device_id) { peer in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(peer.peer_display_name)
                                Text(peer.peer_device_id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("fingerprint \(peer.peer_cert_fingerprint_sha256.prefix(12))... | last seen \(peer.last_seen_at_utc)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
