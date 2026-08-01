import SwiftUI

/// Portly's motion vocabulary.
///
/// A supervisor is something you glance at, so motion here exists to answer one
/// question faster ("what changed?") and never to decorate. Every curve is
/// asymmetric — steep start, gentle settle — because the built-in named curves
/// are too weak to read as intentional at these durations.
enum Motion {
    /// Server state changes: colour, badge, symbol swaps. Steep front-loaded
    /// curve so the change registers immediately and settles quietly.
    static let state = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.24)

    /// Hover feedback. Seen dozens of times a day, so it stays nearly instant.
    static let hover = Animation.easeOut(duration: 0.11)

    /// Banners that arrive asynchronously and push content around.
    static let banner = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.26)

    /// Full-pane content swaps (stopped placeholder to live terminal).
    static let paneSwap = Animation.easeOut(duration: 0.2)

    /// Sidebar rows changing position when a project starts or stops. Movement
    /// already on screen, so it accelerates and brakes like a real object.
    static let reorder = Animation.timingCurve(0.645, 0.045, 0.355, 1, duration: 0.28)

    /// The breathing cadence of a server that is still coming up.
    static let pulse = Animation.easeInOut(duration: 0.85).repeatForever(autoreverses: true)
}
