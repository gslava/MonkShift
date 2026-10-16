import AppKit

/// A solid vector silhouette of a monk in a lotus pose, with no internal cutouts.
@MainActor enum MonkIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.75, y: 12.75, width: 4.5, height: 4.5)).fill()

            let robe = NSBezierPath()
            robe.move(to: NSPoint(x: 7.5, y: 11.75))
            robe.curve(to: NSPoint(x: 5.5, y: 9.5), controlPoint1: NSPoint(x: 6.5, y: 11.5), controlPoint2: NSPoint(x: 5.9, y: 10.7))
            robe.line(to: NSPoint(x: 4.2, y: 6.5))
            robe.curve(to: NSPoint(x: 1, y: 4.5), controlPoint1: NSPoint(x: 2.4, y: 6.5), controlPoint2: NSPoint(x: 1, y: 5.8))
            robe.curve(to: NSPoint(x: 4, y: 1.5), controlPoint1: NSPoint(x: 1, y: 2.9), controlPoint2: NSPoint(x: 2.5, y: 1.5))
            robe.line(to: NSPoint(x: 14, y: 1.5))
            robe.curve(to: NSPoint(x: 17, y: 4.5), controlPoint1: NSPoint(x: 15.5, y: 1.5), controlPoint2: NSPoint(x: 17, y: 2.9))
            robe.curve(to: NSPoint(x: 13.8, y: 6.5), controlPoint1: NSPoint(x: 17, y: 5.8), controlPoint2: NSPoint(x: 15.6, y: 6.5))
            robe.line(to: NSPoint(x: 12.5, y: 9.5))
            robe.curve(to: NSPoint(x: 10.5, y: 11.75), controlPoint1: NSPoint(x: 12.1, y: 10.7), controlPoint2: NSPoint(x: 11.5, y: 11.5))
            robe.close()

            robe.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MonkShift, a monk seated in the lotus pose"
        return image
    }
}
