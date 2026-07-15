import SwiftUI

struct ContentView: View {
    @StateObject private var vm = CaptureViewModel()

    var body: some View {
        TabView {
            CaptureScreen(vm: vm)
                .tabItem { Label("Capture", systemImage: "viewfinder") }

            SessionLibraryScreen(vm: vm)
                .tabItem { Label("Rooms", systemImage: "square.stack.3d.up") }

            DesktopSetupScreen(vm: vm)
                .tabItem { Label("Desktop", systemImage: "desktopcomputer") }
        }
        .sheet(isPresented: $vm.isQrScannerPresented) {
            QrScannerView { value in vm.onQrScanResult(value) }
        }
        .sheet(isPresented: $vm.isCalibrationPatternPresented) {
            PhoneAnchorDisplayView(
                session: vm.phoneAnchorSession,
                boardImageData: vm.phoneAnchorBoardImageData,
                detail: vm.calibrationPatternDetail)
        }
        .task { await vm.startDiscovery() }
        .onDisappear { vm.stopDiscovery() }
    }
}

private struct CaptureScreen: View {
    @ObservedObject var vm: CaptureViewModel
    @State private var showDetails = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image = vm.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .ignoresSafeArea(edges: .top)
                } else {
                    ContentUnavailableView(
                        vm.isCapturing ? "Starting camera…" : "Ready to scan",
                        systemImage: "camera.viewfinder",
                        description: Text(vm.isCapturing
                            ? "Keep the phone steady while tracking initializes."
                            : "Move slowly around the room, including walls, corners, floor edges, and fixed furniture."))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 180)
                }
            }
            .overlay(alignment: .top) {
                CaptureStatusOverlay(vm: vm, showDetails: $showDetails)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            .overlay(alignment: .bottom) {
                CaptureControls(vm: vm)
                    .padding()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

private struct CaptureStatusOverlay: View {
    @ObservedObject var vm: CaptureViewModel
    @Binding var showDetails: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label(vm.isCapturing ? "Recording" : connectionLabel, systemImage: vm.isCapturing ? "record.circle.fill" : "desktopcomputer")
                    .foregroundStyle(vm.isCapturing ? .red : .white)
                Spacer()
                if vm.isCapturing {
                    Text(duration)
                        .monospacedDigit()
                }
                Button {
                    withAnimation { showDetails.toggle() }
                } label: {
                    Image(systemName: showDetails ? "chevron.up.circle.fill" : "info.circle.fill")
                        .font(.title3)
                }
            }

            if vm.isCapturing || vm.coverage.hasSpatialCoverage {
                HStack(spacing: 14) {
                    CoverageMap(snapshot: vm.coverage)
                        .frame(width: 82, height: 82)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(vm.safeToStop ? "Coverage is ready to review" : shortGuidance)
                            .font(.headline)
                            .lineLimit(2)
                        Text(coverageSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: min(1, vm.metrics.twinQualityScore / 100))
                            .tint(vm.safeToStop ? .green : .cyan)
                    }
                }
            }

            if showDetails {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.captureCoaching)
                    Text("Tracking \(Int(vm.metrics.poseConfidence * 100))% · \(vm.metrics.keyframeCount) views · \(vm.metrics.meshCount) mesh updates")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var connectionLabel: String {
        vm.trustedPeers.isEmpty ? "Local capture" : "Desktop paired"
    }

    private var duration: String {
        let seconds = Int(vm.metrics.captureDurationSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var shortGuidance: String {
        if vm.metrics.poseConfidence < 0.60 { return "Slow down—tracking needs detail" }
        if vm.metrics.meshCount < 4 { return "Scan walls and floor edges" }
        if vm.metrics.captureDurationSeconds < 20 { return "Walk the room perimeter" }
        return "Fill gaps in the coverage map"
    }

    private var coverageSummary: String {
        guard vm.coverage.hasSpatialCoverage else { return "Waiting for LiDAR surfaces" }
        return String(
            format: "%.1f m² observed · %.1f × %.1f m span",
            vm.coverage.observedSurfaceAreaSquareMeters,
            vm.coverage.widthMeters,
            vm.coverage.lengthMeters)
    }
}

private struct CoverageMap: View {
    let snapshot: CaptureCoverageSnapshot

    var body: some View {
        Canvas { context, size in
            let allCells = snapshot.observedCells.union(snapshot.visitedCells)
            guard let minX = allCells.map(\.x).min(), let maxX = allCells.map(\.x).max(),
                  let minZ = allCells.map(\.z).min(), let maxZ = allCells.map(\.z).max()
            else { return }

            let columns = max(1, maxX - minX + 1)
            let rows = max(1, maxZ - minZ + 1)
            let cellSize = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
            let xOffset = (size.width - CGFloat(columns) * cellSize) / 2
            let yOffset = (size.height - CGFloat(rows) * cellSize) / 2

            for cell in snapshot.observedCells {
                let rect = CGRect(
                    x: xOffset + CGFloat(cell.x - minX) * cellSize,
                    y: yOffset + CGFloat(cell.z - minZ) * cellSize,
                    width: max(1, cellSize - 1),
                    height: max(1, cellSize - 1))
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.cyan.opacity(0.72)))
            }

            for cell in snapshot.visitedCells {
                let center = CGPoint(
                    x: xOffset + (CGFloat(cell.x - minX) + 0.5) * cellSize,
                    y: yOffset + (CGFloat(cell.z - minZ) + 0.5) * cellSize)
                let marker = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: marker), with: .color(.white))
            }
        }
        .padding(5)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if !snapshot.hasSpatialCoverage {
                Image(systemName: "square.dashed")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Observed room coverage map")
    }
}

private struct CaptureControls: View {
    @ObservedObject var vm: CaptureViewModel

    var body: some View {
        VStack(spacing: 10) {
            if vm.isCapturing {
                Text(vm.safeToStop ? "The minimum capture checks pass. Stop when the room map looks complete." : "Keep scanning until the room outline and major surfaces are filled in.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                Task {
                    if vm.isCapturing { await vm.stopCapture() }
                    else { await vm.startCapture() }
                }
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 74, height: 74)
                    Circle()
                        .fill(vm.isCapturing ? .red : .cyan)
                        .frame(width: vm.isCapturing ? 38 : 62, height: vm.isCapturing ? 38 : 62)
                        .clipShape(vm.isCapturing ? AnyShape(RoundedRectangle(cornerRadius: 8)) : AnyShape(Circle()))
                }
            }
            .accessibilityLabel(vm.isCapturing ? "Stop capture" : "Start capture")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct SessionLibraryScreen: View {
    @ObservedObject var vm: CaptureViewModel
    @State private var reviewedSession: RecordedSessionSummary?

    var body: some View {
        NavigationStack {
            List {
                if vm.recordedSessions.isEmpty {
                    ContentUnavailableView("No captured rooms", systemImage: "square.stack.3d.up", description: Text("Completed captures will appear here for review and export."))
                } else {
                    ForEach(vm.recordedSessions) { session in
                        Button { reviewedSession = session } label: {
                            SessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Captured Rooms")
            .toolbar {
                Button { Task { await vm.refreshSessionLibrary() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(item: $reviewedSession) { session in
            SessionReviewScreen(vm: vm, session: session)
        }
    }
}

private struct SessionRow: View {
    let session: RecordedSessionSummary

    var body: some View {
        HStack(spacing: 12) {
            if let image = RecordedSessionLibrary.previewImage(for: session) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: 86, height: 64).clipped().cornerRadius(8)
            } else {
                Image(systemName: "cube.transparent").frame(width: 86, height: 64).background(.quaternary).cornerRadius(8)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.captureStartedAtUtc).lineLimit(1)
                Text("\(session.durationSummary) · \(session.roomSizeSummary)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(session.integrityStatus == "verified" ? "Integrity verified" : "Integrity \(session.integrityStatus)")
                    .font(.caption2).foregroundStyle(session.integrityStatus == "verified" ? .green : .orange)
            }
        }
    }
}

private struct SessionReviewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: CaptureViewModel
    let session: RecordedSessionSummary

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image = RecordedSessionLibrary.previewImage(for: session) {
                        Image(uiImage: image).resizable().scaledToFit().cornerRadius(14)
                    }
                    GroupBox("Capture summary") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow { Text("Duration"); Text(session.durationSummary) }
                            GridRow { Text("Room span"); Text(session.roomSizeSummary) }
                            GridRow { Text("Observed surfaces"); Text(String(format: "%.1f m²", session.observedSurfaceAreaSquareMeters)) }
                            GridRow { Text("Samples"); Text("\(session.sampleCount)") }
                            GridRow { Text("Integrity"); Text(session.integrityStatus) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("This is a capture review, not a reconstructed room model. Reconstruction and the authoritative room library run on the desktop engine host.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let syncStatus = vm.desktopSyncStatusBySessionId[session.sessionId] {
                        Label(syncStatus, systemImage: syncStatus.contains("reconstructed") ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                            .font(.footnote)
                    }
                    Button(vm.syncingSessionId == session.sessionId ? "Syncing…" : "Sync and reconstruct on desktop") {
                        Task { await vm.syncSessionToDesktop(sessionId: session.sessionId) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.syncingSessionId != nil)
                    Button("Export capture package") { vm.exportSession(sessionId: session.sessionId) }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Room Review")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct DesktopSetupScreen: View {
    @ObservedObject var vm: CaptureViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: vm.status)
                    if vm.trustedPeers.isEmpty {
                        Text("Start Provinode Room on the desktop, choose Start Pairing, then scan its QR code.")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Desktop trust established", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    }
                    #if !targetEnvironment(simulator)
                    Button("Scan desktop QR") { vm.isQrScannerPresented = true }
                    #endif
                    Button("Show calibration pattern") { Task { await vm.prepareCalibrationPattern() } }
                }

                Section("Discovered desktop") {
                    if vm.discoveredEndpoints.isEmpty {
                        Text("No Room host discovered on the local network").foregroundStyle(.secondary)
                    } else {
                        Picker("Receiver", selection: $vm.selectedEndpoint) {
                            ForEach(vm.discoveredEndpoints, id: \.self) { endpoint in
                                Text(endpoint.displayName).tag(Optional(endpoint))
                            }
                        }
                    }
                }

                Section("Manual endpoint") {
                    TextField("Desktop host", text: $vm.manualHost).textInputAutocapitalization(.never)
                    TextField("Pairing port", text: $vm.manualPort).keyboardType(.numberPad)
                    TextField("QUIC host (optional)", text: $vm.manualQuicHost).textInputAutocapitalization(.never)
                    TextField("QUIC port", text: $vm.manualQuicPort).keyboardType(.numberPad)
                    TextField("Pairing certificate SHA-256", text: $vm.manualPairingFingerprintSha256).textInputAutocapitalization(.never)
                    TextField("Pairing code", text: $vm.pairingCode).keyboardType(.numberPad)
                    TextField("Pairing nonce", text: $vm.pairingNonce).textInputAutocapitalization(.never)
                    Button("Pair") { Task { await vm.pair() } }
                }

                Section("QR payload diagnostics") {
                    TextEditor(text: $vm.pairingQrPayloadJson).frame(minHeight: 100).font(.caption.monospaced())
                    Button("Import QR payload") { Task { await vm.applyPairingQrPayload(vm.pairingQrPayloadJson) } }
                }

                if !vm.trustedPeers.isEmpty {
                    Section("Trusted desktops") {
                        ForEach(vm.trustedPeers, id: \.peer_device_id) { peer in Text(peer.peer_display_name) }
                        Button("Reset desktop trust", role: .destructive) { Task { await vm.resetTrustedDesktops() } }
                    }
                }
            }
            .navigationTitle("Desktop")
        }
    }
}
