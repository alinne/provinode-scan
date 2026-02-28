import SwiftUI

struct CalibrationPatternView: View {
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 12) {
            Text("Calibration Pattern")
                .font(.headline)
            Text("Hold the phone so the desktop webcam can detect this board.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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

            Button("Done") {
                dismiss()
            }
            .padding(.top, 8)
        }
        .padding(20)
        .background(Color(white: 0.95))
    }
}
