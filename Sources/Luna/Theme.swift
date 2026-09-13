import AppKit

enum Theme {
    static let background = color(0x202526)
    static let panel = color(0x1A1F20)
    static let text = color(0xE1E6E2)
    static let muted = color(0x8B9A96)
    static let mint = color(0x9DE3C2)
    static let peach = color(0xEFC394)
    static let blue = color(0x9DCBEA)
    static let pink = color(0xDFABC8)
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
    static func button(_ symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: target, action: action)
        button.bezelStyle = .texturedRounded; button.isBordered = false
        button.contentTintColor = text; button.toolTip = label; button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }
}

final class Surface: NSView {
    init(_ color: NSColor, radius: CGFloat = 0) {
        super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = color.cgColor; layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class NoteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.mint.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
    }
}
