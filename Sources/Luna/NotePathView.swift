import AppKit

/// Each directory owns its hover and keyboard focus, independently of separators.
final class NotePathView: NSStackView {
    struct Segment: Equatable {
        let title: String
        let url: URL?
    }
    static func segments(for path: String) -> [Segment] {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let components = file.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var result = [Segment(title: "/", url: current)]
        for (index, component) in components.dropFirst().enumerated() {
            current.appendPathComponent(component)
            result.append(Segment(title: component, url: index == components.count - 2 ? nil : current))
        }
        return result
    }
    init() {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 0
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    private var displayedPath: String?
    func show(path: String?) {
        isHidden = path == nil
        guard path != displayedPath else { return }
        displayedPath = path
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        guard let path else { return }
        for (index, segment) in Self.segments(for: path).enumerated() {
            if index > 1 { addArrangedSubview(Theme.label("/", size: 11, color: .white)) }
            if let url = segment.url { addArrangedSubview(DirectoryButton(title: segment.title, url: url)) }
            else {
                let filename = Theme.label(segment.title, size: 11, color: .white)
                filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                filename.toolTip = segment.title
                addArrangedSubview(filename)
            }
        }
    }
}

final class DirectoryButton: NSButton {
    let url: URL
    private var tracking: NSTrackingArea?
    private(set) var hovered = false
    init(title: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.title = title; font = .systemFont(ofSize: 11); isBordered = false
        setButtonType(.momentaryChange)
        target = self; action = #selector(openDirectory)
        toolTip = "Open \(url.path) in Finder"
        setAccessibilityLabel("Open \(title) in Finder")
        refreshTitle()
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshTitle() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshTitle() }
    private func refreshTitle() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white,
            .underlineStyle: hovered ? NSUnderlineStyle.single.rawValue : 0
        ])
    }
    @objc private func openDirectory() { NSWorkspace.shared.open(url) }
}
