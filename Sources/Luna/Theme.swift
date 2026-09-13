import AppKit

enum Theme {
    enum Layout {
        static let sidebarWidth: CGFloat = 248
        static let inset: CGFloat = 24
        static let rowHeight: CGFloat = 36
        static let compactRowHeight: CGFloat = 28
    }

    // Sora's Panda palette, with contrast-safe light counterparts.
    static func adaptive(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            color(appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? light : dark)
        }
    }
    static let background = adaptive(light: 0xF7F8FA, dark: 0x292A2B)
    static let panel = adaptive(light: 0xECEEF1, dark: 0x232425)
    static let text = adaptive(light: 0x242833, dark: 0xCCCCCC)
    static let muted = adaptive(light: 0x606773, dark: 0xA0A4AA)
    static let mint = adaptive(light: 0x00796B, dark: 0x19F9D8)
    static let peach = adaptive(light: 0x8A4B00, dark: 0xFFB86C)
    static let blue = adaptive(light: 0x0969AD, dark: 0x45A9F9)
    static let pink = adaptive(light: 0xB42349, dark: 0xFF2C6D)
    static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static func label(_ text: String, size: CGFloat = 12, color: NSColor = muted, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    static func button(_ symbol: String, label: String, target: AnyObject, action: Selector, title: String = "", width: CGFloat = 32) -> ChromeButton {
        let button = ChromeButton(title: title, target: target, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.isBordered = false
        button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }


}

final class Surface: NSView {
    private let fill: NSColor
    var fillOpacity: CGFloat = 1 { didSet { refreshFill() } }
    init(_ color: NSColor, radius: CGFloat = 0) {
        fill = color
        super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = color.cgColor; layer?.cornerRadius = radius
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFill()
    }
    private func refreshFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.withAlphaComponent(fill.alphaComponent * fillOpacity).cgColor }
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class NoteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.mint.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
    }
}

/// Native NSButton interaction with explicit icon/text layout and a real 32/36 pt hit area.
/// AppKit's image-leading cell distributes spare width between image and title;
/// drawing the two as one group keeps their optical gap stable at every width.
final class ChromeButton: NSButton {
    var contentAlignment: NSTextAlignment = .center
    var showsBaseFill = false
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
        let active = state == .on
        let color = (active ? Theme.mint : Theme.text).withAlphaComponent(isEnabled ? 1 : 0.35)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        if active || showsBaseFill || (isEnabled && (hovered || isHighlighted)) {
            (active ? Theme.mint : Theme.text).withAlphaComponent(isHighlighted ? 0.16 : (hovered || active ? 0.10 : 0.05)).setFill()
            shape.fill()
        }
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let iconSize: CGFloat = image == nil ? 0 : (contentAlignment == .left ? 18 : 16)
        let gap: CGFloat = image == nil || title.isEmpty ? 0 : (contentAlignment == .left ? 12 : 8)
        let contentWidth = iconSize + gap + (title.isEmpty ? 0 : textSize.width)
        let startX = contentAlignment == .left ? 12 : (bounds.width - contentWidth) / 2
        if let symbol = image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))?
            .withSymbolConfiguration(.init(paletteColors: [color])) {
            let scale = min(iconSize / symbol.size.width, iconSize / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: startX + (iconSize - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if !title.isEmpty {
            (title as NSString).draw(at: NSPoint(x: startX + iconSize + gap, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        }
        if window?.firstResponder === self {
            Theme.mint.setStroke(); shape.lineWidth = 1.5; shape.stroke()
        }
    }
}
