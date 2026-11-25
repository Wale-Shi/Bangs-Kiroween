import BangsCore
import SwiftUI

struct PillButton: View {
    /// `danger` is outlined rather than filled, for going ahead with something flagged: it reads as a choice, not the
    /// default.
    enum Style { case plain, primary, warn, danger }
    let title: String
    let style: Style
    /// A keyboard shortcut that does the same, shown faintly after the title.
    var hint: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: style == .plain ? .regular : .semibold)).lineLimit(1).fixedSize()
                if let hint { Text(hint).font(.system(size: 10, weight: .medium)).opacity(0.55) }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .overlay { if style == .danger { Capsule().strokeBorder(Palette.danger, lineWidth: 1.5) } }
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .plain: Palette.ink
        case .primary: Palette.inverse
        case .warn: .black
        case .danger: Palette.danger
        }
    }

    private var fill: Color {
        switch style {
        case .plain: Palette.wash(hovering ? 0.17 : 0.1)
        case .primary: Palette.ink.opacity(hovering ? 0.88 : 1)
        case .warn: Palette.warn.opacity(hovering ? 0.88 : 1)
        case .danger: Palette.danger.opacity(hovering ? 0.14 : 0)
        }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
