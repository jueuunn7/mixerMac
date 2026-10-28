import SwiftUI

struct ConsoleActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @SwiftUI.State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(LinearGradient(
                    colors: configuration.isPressed ? [Color(white: 0.035), Color(white: 0.13)]
                        : [Color(white: hovering ? 0.3 : 0.23), Color(white: hovering ? 0.08 : 0.035)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(configuration.isPressed ? Color(red: 0.25, green: 0.70, blue: 0.94)
                    : .black.opacity(0.6), lineWidth: 3))
                .shadow(color: .black.opacity(0.3), radius: 1, y: configuration.isPressed ? 0 : 1)
            configuration.label
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(Color(white: 0.13))
                .fixedSize()
        }
            .offset(y: configuration.isPressed ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
