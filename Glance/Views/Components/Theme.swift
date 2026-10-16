import SwiftUI

enum Theme {
    static let record = Color(red: 1.0, green: 0.27, blue: 0.33)
    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.27, blue: 0.95), Color(red: 0.62, green: 0.25, blue: 0.86), Color(red: 0.98, green: 0.36, blue: 0.48)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardCorner: CGFloat = 14
}

/// Rounded, softly outlined container used for inspector sections and cards.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.brandGradient))
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, systemImage: String) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

/// Small "label: control" row for inspector forms.
struct FieldRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.callout)
            Spacer(minLength: 8)
            control
        }
    }
}

struct PrimaryRecordButtonStyle: ButtonStyle {
    var tint: Color = Theme.record

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(tint.gradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .shadow(color: tint.opacity(0.35), radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Round icon button used on the floating control bar and bubble.
struct OverlayIconButtonStyle: ButtonStyle {
    var tint: Color = .primary
    var filled = false
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(filled ? Color.white : tint)
            .frame(width: size, height: size)
            .background(Circle().fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08))))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Circle())
    }
}
