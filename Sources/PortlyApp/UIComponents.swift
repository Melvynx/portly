import PortlyCore
import SwiftUI

extension ServerState {
    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .unhealthy: return "Unhealthy"
        case .restarting: return "Restarting"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .stopped: return .secondary
        case .starting, .restarting: return .orange
        case .running: return .green
        case .unhealthy: return .yellow
        case .failed: return .red
        }
    }
}

/// The standard macOS status dot: a filled circle, nothing more.
struct StatusDot: View {
    let state: ServerState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(state.color)
            .frame(width: size, height: size)
            .overlay(
                Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .help(state.label)
    }
}

extension Color {
    init(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        var int: UInt64 = 0
        Scanner(string: value).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension Date {
    /// "3m", "2h 14m": compact enough for a sidebar row.
    var compactUptime: String {
        let seconds = Int(Date().timeIntervalSince(self))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 { return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
