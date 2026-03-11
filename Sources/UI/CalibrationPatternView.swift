import SwiftUI
import UIKit
import ProvinodeRoomContracts

struct CalibrationPatternView: View {
    @Environment(\.dismiss) private var dismiss

    let phoneAnchorSession: PhoneAnchorSessionSnapshot?
    let boardImageData: Data?
    let detail: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 12) {
            Text(phoneAnchorSession == nil ? "Calibration Pattern" : "Phone Anchor")
                .font(.headline)

            Text(detailText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let image = boardImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(12)
                    .background(Color.gray.opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.5), lineWidth: 1))
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(0..<64, id: \.self) { index in
                        Rectangle()
                            .fill((index / 8 + index % 8).isMultiple(of: 2) ? Color.white : Color.black)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .padding(12)
                .background(Color.gray.opacity(0.2))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.5), lineWidth: 1))
            }

            if let phoneAnchorSession {
                VStack(spacing: 4) {
                    Text(phoneAnchorSession.anchor_label)
                        .font(.subheadline.weight(.semibold))
                    Text(displayTargetLabel(phoneAnchorSession.display_target))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let surface = phoneAnchorSession.display_surface {
                        Text(surfaceLabel(surface))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let revision = phoneAnchorSession.board_revision, !revision.isEmpty {
                        Text("Board \(revision)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let sha = phoneAnchorSession.board_image_sha256, !sha.isEmpty {
                        Text("Hash \(String(sha.prefix(12)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if phoneAnchorSession.observation_count > 0 || phoneAnchorSession.relationship_count > 0 {
                        Text("Observations \(phoneAnchorSession.observation_count) • Relationships \(phoneAnchorSession.relationship_count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Anchor expires \(phoneAnchorSession.expires_at_utc)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Done") {
                dismiss()
            }
            .padding(.top, 8)
        }
        .padding(20)
        .background(Color(white: 0.95))
    }

    private var boardImage: UIImage? {
        guard let boardImageData else { return nil }
        return UIImage(data: boardImageData)
    }

    private var detailText: String {
        if let detail, !detail.isEmpty {
            return detail
        }

        if phoneAnchorSession != nil {
            return "Hold the phone so one or more desktop cameras can observe the anchor board."
        }

        return "Hold the phone so the desktop webcam can detect this board."
    }

    private func displayTargetLabel(_ target: MarkerDisplayTarget) -> String {
        switch target {
        case .desktopDisplay:
            return "Display anchor board"
        case .phoneScreen:
            return "Phone anchor board"
        }
    }

    private func surfaceLabel(_ surface: MarkerDisplaySurfaceSnapshot) -> String {
        let widthMm = Int((surface.width_meters * 1000).rounded())
        let heightMm = Int((surface.height_meters * 1000).rounded())
        let label = surface.display_label?.isEmpty == false ? surface.display_label! : "Anchor surface"
        return "\(label) • \(widthMm)×\(heightMm) mm"
    }
}

struct PhoneAnchorDisplayView: View {
    let session: PhoneAnchorSessionSnapshot?
    let boardImageData: Data?
    let detail: String?

    var body: some View {
        CalibrationPatternView(
            phoneAnchorSession: session,
            boardImageData: boardImageData,
            detail: detail)
    }
}
