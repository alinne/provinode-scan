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
