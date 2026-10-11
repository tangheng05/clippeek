import AppKit

/// clippeek's mark in the menu bar: the ⇧⌘4 selection corners, with what's happening in the middle.
enum MenuBarIcon {
    enum Center: Equatable {
        case none, arrow(rise: CGFloat), check, exclamation
    }

    static func image(_ center: Center) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            func stroke(_ path: NSBezierPath) {
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                NSColor.black.setStroke()
                path.stroke()
            }
            let corners = NSBezierPath()
            let low: CGFloat = 2.5, high: CGFloat = 15.5, arm: CGFloat = 4.5
            for (x, y, dx, dy) in [(low, high, 1.0, -1.0), (high, high, -1, -1), (low, low, 1, 1), (high, low, -1, 1)] {
                corners.move(to: NSPoint(x: x, y: y + dy * arm))
                corners.line(to: NSPoint(x: x, y: y))
                corners.line(to: NSPoint(x: x + dx * arm, y: y))
            }
            stroke(corners)
            let mark = NSBezierPath()
            switch center {
            case .none:
                return true
            case .arrow(let rise):
                mark.move(to: NSPoint(x: 9, y: 5.5 + rise))
                mark.line(to: NSPoint(x: 9, y: 12.5 + rise))
                mark.move(to: NSPoint(x: 6.2, y: 9.7 + rise))
                mark.line(to: NSPoint(x: 9, y: 12.5 + rise))
                mark.line(to: NSPoint(x: 11.8, y: 9.7 + rise))
            case .check:
                mark.move(to: NSPoint(x: 5.8, y: 9.2))
                mark.line(to: NSPoint(x: 8.1, y: 6.9))
                mark.line(to: NSPoint(x: 12.4, y: 11.4))
            case .exclamation:
                mark.move(to: NSPoint(x: 9, y: 12.8))
                mark.line(to: NSPoint(x: 9, y: 8.6))
            }
            stroke(mark)
            if center == .exclamation {
                // A stroked dot comes out lighter than the other marks; a filled one matches them.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 7.85, y: 4.6, width: 2.3, height: 2.3)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
