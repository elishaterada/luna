# Luna editor engine decision

Research date: September 12, 2026. This is an architectural recommendation, not a claim that comparative benchmarks have already passed.

## Recommendation

Start with a small AppKit application and an `NSTextView` explicitly initialized with TextKit 2 (`NSTextView(usingTextLayoutManager: true)`). Keep the document/session model and highlighting service independent of the view so that a measured engine defect can justify a replacement without rewriting recovery or file operations.

Luna's primary workloads are small configuration files, notes, and readable meeting scenarios. Native text behavior and minimal startup work matter more than IDE features. TextKit 2 offers viewport-oriented layout, while AppKit lets Luna customize window materials, typography, text insets, selection color, line spacing, and toolbars independently of the editor engine. Choosing this engine does not require a TextEdit-like design.

Apple explains that TextKit 2 always uses noncontiguous layout and recommends querying layout within the viewport. Accessing the old `layoutManager` property can switch an `NSTextView` permanently into TextKit 1 compatibility mode for that instance; avoid that API even in utilities such as line numbering. Full-document layout requests can defeat viewport benefits. [Apple, Meet TextKit 2](https://developer.apple.com/videos/play/wwdc2021/10061/)

## Alternatives assessed

| Engine | Strengths for Luna | Tradeoff and decision |
| --- | --- | --- |
| NSTextView + TextKit 2 | System editing integration; viewport layout; no third-party editor dependency; flexible native surrounding UI | Test long lines, selections, IME, and attribute updates on target macOS versions. Selected initial engine. |
| NSTextView + TextKit 1 | Mature editing behavior and familiar layout APIs; optional noncontiguous layout | Easier to accidentally perform expensive document-wide layout; keep only as a deliberate measured fallback, not an accidental mode switch. [Apple](https://developer.apple.com/videos/play/wwdc2021/10061/) |
| STTextView | AppKit TextKit 2 replacement; configurable font/colors/line spacing; line numbers, find, plugins, and syntax-highlighting integration | Adds dependency and replacement text-view behavior. Maintainer documents TextKit issues, including long-line/attribute-update problems. Good second candidate if stock NSTextView has a reproducible blocker. Bug list is maintainer evidence, not proof every issue remains on current macOS. [Project README](https://github.com/krzyzanowskim/STTextView/blob/main/README.md) |
| CodeEditTextView | Native Swift NSView editor optimized for line-oriented code; project advertises fast initial layout and large documents | Its own documentation warns about RTL and system-text-view parity. Syntax functionality lives in the parent CodeEditSourceEditor package. Less suitable for general notes and multilingual meeting text. Performance claims require local validation. [Project](https://github.com/CodeEditApp/CodeEditTextView) |
| Runestone | Incremental Tree-sitter highlighting and line-oriented performance design | UIKit/iOS implementation rather than an AppKit macOS drop-in. Porting would increase scope substantially. [Project](https://github.com/simonbs/Runestone), [TextView implementation](https://github.com/simonbs/Runestone/blob/main/Sources/Runestone/TextView/Core/TextView.swift) |
| CodeMirror/Monaco in a web view | Broad language support and flexible web styling | Extra web-view/JavaScript integration for a native single-file tool. Reject for initial scope, not because web editors inherently cannot handle large files: CodeMirror explicitly virtualizes rendering around its viewport. No unmeasured launch-time comparison is asserted. [CodeMirror system guide](https://codemirror.net/docs/guide/) |

## Keep startup and editing work bounded

The following are Luna design recommendations and acceptance criteria, not performance guarantees from the sources.

- Create the window and a usable editing surface before optional work. Load the selected session document first, and restore other note bodies lazily. Do not initialize a project index, language server, extension host, or web runtime.
- Read/decode files and write recovery snapshots away from the main thread. Coalesce rapid recovery writes, serialize them, and flush pending content on close/termination. Atomic replacement should prevent a partial write from destroying the last valid snapshot.
- Make highlighting a cancellable, revision-tagged job. Apply results only if the document revision still matches. Plain readable text must be available before all coloring finishes.
- Bound highlighting work to changed regions and visible content where practical. Do not rescan and restyle a multi-megabyte document synchronously on every keystroke. Multiline comments and strings require lexical state propagation; a simplistic changed-line regex can produce incorrect colors.
- For an initial lightweight lexer, clearly document supported languages and gracefully reduce highlighting above a measured size/line-length threshold. If language accuracy or edit cost becomes problematic, adopt incremental Tree-sitter grammars rather than growing an ad hoc parser indefinitely. Tree-sitter's stated design is incremental parsing suitable for editor updates. [Tree-sitter project](https://github.com/tree-sitter/tree-sitter)
- Keep full-window blur stable; place expensive material effects in small chrome areas where possible. Draw only invalidated regions and avoid synchronous layout of the whole text merely to compute a gutter or status indicator.

Apple recommends keeping discrete interaction work below roughly 100 ms and continuous interaction within a display refresh interval (8–17 ms), moving non-UI work away from the main thread, and minimizing invalidated drawing. These are responsiveness limits, not a claim that a 100 ms keystroke is desirable. [Apple, Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)

## Performance validation plan

Use optimized Release builds on the actual target Mac. Record hardware, OS, build configuration, file size, line count, wrapping, and highlighting state. Compare stock TextKit 2 against alternatives only when measurements reveal an unmet requirement.

| Scenario | Measurement | Initial target |
| --- | --- | --- |
| Launch blank note / reopen last note | External launch request to first editable content; 20 launches; median and p95 | Warm median <250 ms; cold target <500 ms, subject to hardware validation |
| Open 5 KB shell config | Request to usable text and separately to completed highlighting | No spinner needed; usable text <100 ms after app is running |
| Open 1 MB / 10 MB / 50 MB text | Read/decode, main-thread attachment, first paint, highlight duration, peak memory | 10 MB usable <1 s; no claim of unlimited file size |
| Continuous scroll | Instruments frame/hitch trace, both wrapped/unwrapped | Consistent display cadence without repeated >17 ms stalls at 60 Hz |
| Type/paste/undo at beginning, middle, end | Main-thread duration and input-to-visible change; highlighting on/off | Typical edits <16 ms; no repeated >100 ms stalls |
| Pathological single long line | Open, horizontal scroll, wrap toggle, edit, selection | Remains interactive; reduce highlighting if required |
| Recovery during typing | Snapshot time, main-thread stalls, forced-quit restore, exact content comparison | No main-thread disk I/O; last completed atomic snapshot restores exactly |

Fixture matrix: shell/.env, YAML, Markdown, JavaScript, large plain text, a 1 MB single line, emoji/composed characters, Japanese input, RTL notes, LF/CRLF, and documents without a trailing newline. Verify text fidelity independently of colors. Include live font resizing and presentation mode because larger glyphs change layout costs.

Measure launch externally as well as with internal timestamps: `applicationDidFinishLaunching` alone excludes important startup time and is not proof the user can edit. Use Instruments App Launch/Time Profiler and signposts around file load, first editor readiness, highlighting, and recovery. Cold and warm starts are distinct; OS cache state affects results. [Apple, Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)

If TextKit 2 exhibits a correctness or responsiveness failure, keep the same fixtures and compare STTextView first. Select a replacement from measured results rather than repository claims. A custom Core Text engine is justified only if both fail requirements; maintaining selection, accessibility, IME, undo, and Unicode behavior is a substantial product commitment.
