import SwiftUI

enum Theme {
    static let accent = Color(red: 0.13, green: 0.39, blue: 0.35)
    static let ink = Color(red: 0.13, green: 0.19, blue: 0.18)
    static let muted = Color(red: 0.44, green: 0.49, blue: 0.47)
    static let background = Color(red: 0.97, green: 0.975, blue: 0.96)
    static let sidebar = Color(red: 0.93, green: 0.95, blue: 0.93)
    static let line = Color(red: 0.87, green: 0.90, blue: 0.87)
    static let pale = Color(red: 0.88, green: 0.94, blue: 0.90)
    static let amber = Color(red: 0.62, green: 0.42, blue: 0.18)
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 12)
            .foregroundStyle(.white).background(Theme.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 11))
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(Theme.accent).background(configuration.isPressed ? Theme.pale : .white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
    }
}

extension View {
    func panel() -> some View {
        self.background(.white, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(Theme.line.opacity(0.7), lineWidth: 1))
    }
}
