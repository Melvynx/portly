import PortlyCore
import SwiftUI

/// A compact type system for Portly's dense, utility-first interface.
/// Rounded system faces keep the chrome friendly while technical values stay
/// monospaced and easy to scan.
enum PortlyTypography {
    static let body = Font.system(size: 13, weight: .regular, design: .rounded)
    static let bodyMedium = Font.system(size: 13, weight: .medium, design: .rounded)
    static let project = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let title = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let label = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let metadata = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    static let metric = Font.system(size: 12, weight: .medium, design: .monospaced)
}

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
            .shadow(color: state.color.opacity(state == .stopped ? 0 : 0.34), radius: 3)
            .help(state.label)
    }
}

/// Consistent compact status treatment used in server chrome.
struct StatusBadge: View {
    let state: ServerState

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(state: state, size: 8)
            Text(state.label)
                .font(PortlyTypography.bodyMedium)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background {
            Capsule(style: .continuous)
                .fill(state.color.opacity(0.1))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(state.color.opacity(0.2), lineWidth: 0.75)
        }
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
