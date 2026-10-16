import SwiftUI

struct LevelMeter: View {
    var level: Float
    var segments = 22
    var height: CGFloat = 6

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let threshold = Float(index) / Float(segments)
                RoundedRectangle(cornerRadius: height / 3, style: .continuous)
                    .fill(color(for: index))
                    .opacity(level > threshold ? 1 : 0.15)
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(for index: Int) -> Color {
        let fraction = Double(index) / Double(segments)
        if fraction > 0.85 { return .red }
        if fraction > 0.65 { return .yellow }
        return .green
    }
}
