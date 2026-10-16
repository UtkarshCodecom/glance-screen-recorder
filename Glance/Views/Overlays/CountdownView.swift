import SwiftUI

struct CountdownView: View {
    let model: CountdownModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().strokeBorder(Theme.brandGradient, lineWidth: 5)
                Text("\(model.remaining)")
                    .font(.system(size: 92, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.remaining)
            }
            .frame(width: 180, height: 180)
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)

            Button("Cancel") { app.coordinator.cancelCountdown() }
                .buttonStyle(.borderedProminent)
                .tint(.black.opacity(0.55))
                .controlSize(.large)
            Text("Press Esc or \(GlobalHotKeys.toggleDescription) to cancel")
                .font(.caption).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.45)))
        }
        .frame(width: 300, height: 300)
    }
}
