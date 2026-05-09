import AppKit

/// Renders the SynoWatch menu bar icon for every possible app state.
///
/// The icon consists of a NAS chassis (inspired by the Synology DSM visual language)
/// with a small status badge in the bottom-right corner.
/// All drawing is done in points; the system scales to @2x automatically.
enum IconRenderer {

    /// Total image size in points. The NAS body occupies the left portion;
    /// the badge extends into the right margin.
    static let imageSize = NSSize(width: 22, height: 16)

    /// Returns a fully composited menu bar icon for the given state.
    static func image(for state: AppState) -> NSImage {
        let image = NSImage(size: imageSize, flipped: false) { _ in
            drawChassis()
            if let badge = badgeSpec(for: state) {
                drawBadge(badge)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Chassis

    /// The NAS body is a 16×14 pt Synology-blue rounded rectangle with
    /// white drive-bay slots and a green status LED.
    private static let chassisRect = NSRect(x: 0, y: 1, width: 16, height: 14)

    private static func drawChassis() {
        // Body
        let bodyPath = NSBezierPath(roundedRect: chassisRect, xRadius: 2.5, yRadius: 2.5)
        NSColor(red: 0.10, green: 0.42, blue: 0.82, alpha: 1).setFill()   // Synology blue
        bodyPath.fill()

        // Front panel — slightly lighter inset
        let panelRect = NSRect(x: 1, y: 2, width: 14, height: 10)
        let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 1.5, yRadius: 1.5)
        NSColor(red: 0.13, green: 0.48, blue: 0.90, alpha: 1).setFill()
        panelPath.fill()

        // Drive bay slots (white horizontal bars)
        NSColor(white: 1, alpha: 0.80).setFill()
        for i in 0..<3 {
            let y = chassisRect.minY + 3.0 + CGFloat(i) * 3.2
            let slot = NSRect(x: 2.5, y: y, width: 9, height: 1.5)
            NSBezierPath(roundedRect: slot, xRadius: 0.5, yRadius: 0.5).fill()
        }

        // Status LED (top-right of chassis)
        NSColor(red: 0.22, green: 0.87, blue: 0.45, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 13, y: chassisRect.maxY - 3.5, width: 2, height: 2)).fill()
    }

    // MARK: - Badge

    private struct BadgeSpec {
        let symbol: String
        let color: NSColor
    }

    private static func badgeSpec(for state: AppState) -> BadgeSpec? {
        switch state {
        case .upToDate:
            return BadgeSpec(symbol: "checkmark", color: NSColor(red: 0.15, green: 0.75, blue: 0.30, alpha: 1))
        case .updatesAvailable:
            return BadgeSpec(symbol: "arrow.down", color: .systemOrange)
        case .otpRequired:
            return BadgeSpec(symbol: "lock.fill", color: .systemYellow)
        case .error:
            return BadgeSpec(symbol: "exclamationmark", color: .systemRed)
        case .unconfigured:
            return BadgeSpec(symbol: "gearshape", color: NSColor(white: 0.55, alpha: 1))
        case .checking:
            return nil
        }
    }

    /// Draws a small filled circle badge with a white SF Symbol centered inside it.
    private static func drawBadge(_ spec: BadgeSpec) {
        let center = NSPoint(x: 17.5, y: 3.5)
        let radius: CGFloat = 4.5

        // White outer ring for contrast against the chassis and menu bar background
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius - 1,
            y: center.y - radius - 1,
            width: (radius + 1) * 2,
            height: (radius + 1) * 2
        )).fill()

        // Colored badge circle
        spec.color.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )).fill()

        // White SF Symbol clipped to badge bounds
        let symbolSize = NSSize(width: radius * 1.4, height: radius * 1.4)
        let symbolRect = NSRect(
            x: center.x - symbolSize.width / 2,
            y: center.y - symbolSize.height / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )

        if let white = whiteSymbol(named: spec.symbol, size: symbolSize) {
            white.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// Returns an NSImage containing the named SF Symbol rendered in white.
    ///
    /// This is achieved by filling a same-size rect with white and then using
    /// the `destinationIn` composite operation, which masks the fill to the
    /// symbol's opaque pixels.
    private static func whiteSymbol(named name: String, size: NSSize) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size.height * 0.9, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }

        return NSImage(size: size, flipped: false) { rect in
            // 1. Fill with white
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            // 2. Composite the symbol using destinationIn:
            //    keeps the white fill only where the symbol is opaque.
            symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }
}
