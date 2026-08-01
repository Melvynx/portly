import AppKit
import SwiftUI
import SwiftTerm

/// The terminal's colours, in one place.
///
/// SwiftTerm paints its own background rather than setting `layer.backgroundColor`,
/// so the chrome around it cannot discover the colour by reading the view — it has
/// to be told. Both the terminal and its surrounding surface read from here so the
/// padding around the text is genuinely the same black as the text sits on.
enum TerminalTheme {
    static let background = NSColor(srgbRed: 0.043, green: 0.051, blue: 0.071, alpha: 1)
    static let foreground = NSColor(srgbRed: 0.84, green: 0.86, blue: 0.9, alpha: 1)

    /// A deliberate hairline, a few steps lighter than the surface. Fixed rather
    /// than semantic: it has to sit on the terminal's own black in both
    /// appearances, not on the window's.
    static let border = NSColor(srgbRed: 0.2, green: 0.23, blue: 0.29, alpha: 1)

    static let surfaceInset: CGFloat = 10
    static let textInset: CGFloat = 12
    static let cornerRadius: CGFloat = 10
}

/// Hosts the server's live terminal. The view itself is owned by the runtime, so
/// scrollback and keyboard focus survive switching servers or closing the window.
struct TerminalPane: NSViewRepresentable {
    let runtime: ServerRuntime

    func makeNSView(context: Context) -> NSView {
        let container = ContainerView()
        container.embed(runtime.terminalView())
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? ContainerView else { return }
        container.embed(runtime.terminalView())
    }

    /// A plain container so swapping servers is a view swap, not a rebuild.
    final class ContainerView: NSView {
        private let surface = NSView()
        private weak var current: NSView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configureSurface()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configureSurface()
        }

        private func configureSurface() {
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.wantsLayer = true
            surface.layer?.cornerRadius = TerminalTheme.cornerRadius
            surface.layer?.cornerCurve = .continuous
            surface.layer?.masksToBounds = true
            surface.layer?.backgroundColor = TerminalTheme.background.cgColor
            surface.layer?.borderWidth = 1
            surface.layer?.borderColor = TerminalTheme.border.cgColor
            addSubview(surface)

            let inset = TerminalTheme.surfaceInset
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                surface.topAnchor.constraint(equalTo: topAnchor, constant: inset),
                surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            ])
        }

        func embed(_ view: NSView) {
            guard current !== view else { return }
            current?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.wantsLayer = true
            view.layer?.cornerRadius = 0
            // Belt and braces: SwiftTerm draws this colour, but setting the layer
            // too means a live resize never flashes the window colour through.
            view.layer?.backgroundColor = TerminalTheme.background.cgColor
            surface.addSubview(view)

            let inset = TerminalTheme.textInset
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset),
                view.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
                view.topAnchor.constraint(equalTo: surface.topAnchor, constant: inset),
                view.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -inset),
            ])
            current = view
            window?.makeFirstResponder(view)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let current { window?.makeFirstResponder(current) }
        }
    }
}
