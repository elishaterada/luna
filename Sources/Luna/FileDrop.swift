import AppKit
import WebKit

/// Read file URLs without imposing an extension filter; Open owns format validation.
enum FileDrop {
    static func urls(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// Receives drops over window chrome and otherwise unregistered content.
final class FileDropView: NSView {
    var onFileDrop: (([URL]) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDrop != nil && !FileDrop.urls(in: sender.draggingPasteboard).isEmpty ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = FileDrop.urls(in: sender.draggingPasteboard)
        guard !files.isEmpty, let onFileDrop else { return false }
        onFileDrop(files)
        return true
    }
}

/// Prevents WebKit from navigating to dropped files in live and Markdown previews.
class FileDropWebView: WKWebView {
    var onFileDrop: (([URL]) -> Void)? {
        didSet { registerForDraggedTypes([.fileURL]) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onFileDrop != nil, !FileDrop.urls(in: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if onFileDrop != nil, !FileDrop.urls(in: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if onFileDrop != nil, !FileDrop.urls(in: sender.draggingPasteboard).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = FileDrop.urls(in: sender.draggingPasteboard)
        guard !files.isEmpty, let onFileDrop else { return super.performDragOperation(sender) }
        onFileDrop(files)
        return true
    }
}
