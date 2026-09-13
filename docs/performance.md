# Release performance — September 12, 2026

Measured on the development Apple Silicon Mac, macOS 26, with Xcode 26.6 and Swift 6.3.3. Three sequential release runs before Sparkle integration, with no external dependencies at that time. The current app adds Sparkle and defers updater initialization until after the first window; these historical timings do not measure the current update-enabled build. The locally signed app bundle was approximately 736 KB at measurement time (size varies as the implementation changes).

| Operation | Observed range |
| --- | ---: |
| In-process app initialization | 174–277 ms |
| First main-loop turn after showing window | 238–356 ms |
| Install ~10 MB text and configure layout | 4.3–6.8 ms |
| Insert text into 10 MB document, including model/UI update | 6.9–10.9 ms |
| Highlight viewport plus bounded context | 1.2–1.8 ms |
| Issue scroll-to-end | 0.46–0.52 ms |
| Synchronous 10 MB recovery flush | 217–219 ms |

All runs verified that `textLayoutManager` remained present, so TextKit 2 was active. The research's provisional <250 ms warm-launch median has **not** been demonstrated: this sample's first-loop median is 319 ms, and first-loop timing is not first-visible-frame timing. Scroll timings measure the command, not sustained frame rate. This is a small microbenchmark, not a comparative claim against TextEdit or VS Code.

An initial run exposed 4.5-second edits. Instrumentation isolated almost all of this delay to repeatedly deriving the sidebar title by splitting the whole 10 MB document into lines. Reading only a bounded title prefix reduced edits to the range above. This matters more than selecting an engine by reputation.

Read operations run off the main thread. Syntax patterns are compiled once per language, and coloring is restricted to at most 32,768 UTF-16 units surrounding the viewport. Recovery uses a 400 ms debounce and serial background writes. The normal close/quit flush is intentionally synchronous for correctness. On large files it adds measurable latency. Line counting stops scanning after a 200,000-unit cursor offset, where the status bar reports character position instead.

Further validation before broad distribution: cold-launch first-frame instrumentation; sustained scrolling frame times; edit p95 over long sessions; 50–100 MB and megabyte-long-line cases; IME, bidirectional text and VoiceOver; many-note restoration; macOS 14/15 material fallback; low-disk and permission failure UX. TextKit 2 has known upstream limitations, documented in the engine research.
