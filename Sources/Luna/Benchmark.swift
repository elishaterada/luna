import AppKit
import LunaCore

/// Opt-in local benchmark. Uses an isolated recovery directory supplied by the
/// runner and never touches user documents. Times synchronous work separately
/// from the event-loop wait used to let AppKit settle its first layout.
func runBenchmark(_ workspace: Workspace, started: TimeInterval, reportPath: String) {
    var results: [String: Double] = [:]
    results["app_initialization_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
    DispatchQueue.main.async {
        results["first_runloop_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let line = "const scenario = { member: true, total: 120, city: \"Chicago\" };\n"
        let sample = String(repeating: line, count: 10 * 1024 * 1024 / line.utf8.count)
        let begin = ProcessInfo.processInfo.systemUptime
        workspace.loading = true
        workspace.editor.string = sample
        workspace.loading = false
        workspace.updateFont()
        workspace.highlighter.configure("JavaScript")
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        results["install_10mb_ms"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        results["textkit2_active"] = workspace.editor.textLayoutManager != nil ? 1 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            var begin = ProcessInfo.processInfo.systemUptime
            workspace.highlighter.highlight(workspace.editor)
            results["highlight_viewport_ms"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            begin = ProcessInfo.processInfo.systemUptime
            workspace.editor.setSelectedRange(NSRange(location: 0, length: 0))
            workspace.editor.insertText("// edited\n", replacementRange: workspace.editor.selectedRange())
            results["edit_10mb_ms"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            begin = ProcessInfo.processInfo.systemUptime
            workspace.editor.scrollToEndOfDocument(nil)
            results["scroll_to_end_10mb_ms"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            begin = ProcessInfo.processInfo.systemUptime
            workspace.flushRecovery()
            results["recovery_10mb_ms"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            }
            NSApp.terminate(nil)
        }
    }
}
