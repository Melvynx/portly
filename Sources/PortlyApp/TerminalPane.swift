import AppKit
import SwiftUI
import SwiftTerm

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
        private weak var current: NSView?

        func embed(_ view: NSView) {
            guard current !== view else { return }
            current?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
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
