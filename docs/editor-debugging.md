# Debugging Luna's editor

Use this guide for caret, list, selection, focus, and undo bugs. The dated evidence and superseded decisions are in [llm-changelog.md](llm-changelog.md); release verification follows [releasing.md](releasing.md).

## Current editor: ProseMirror Live View

Saved Live View now runs the shared engine in `Editor/ProseMirror`, through
`MediaNoteView.swift`. Native Source remains `EditorView.swift`. Use
`ProseMirrorEditorTests.swift` for saved-editor regressions. The old DOM marker,
custom caret, and native contenteditable Undo implementation has been removed.
The historical traps below explain past failures; do not restore their repair code
or construct new fixtures against `.text`, `.list-marker`, or `#text-caret`.

For a current fixture, wait for `window.lunaEditor.view`, set model selection with
`lunaEditor.select(from,to)`, and inspect `lunaEditor.state`, `lunaEditor.source`,
and `lunaEditor.history`. Use actual AppKit keys to verify browser caret movement,
composition, and responder routing. ProseMirror owns history and selection. Node
views own previews and native media; metadata must never create transactions.

In native test fixtures, establish the window responder before setting model/DOM
selection; keep the WK content responder while it owns focus. Wait for actual
model changes after sending a key instead of treating a fixed sleep as delivery.
Inject a native word as one event batch when asserting one-word Undo, so runner
scheduling does not create artificial gaps beyond the history grouping interval.

Exercise immediate native commands followed by typing, not only commands separated
by sleeps: the native adapter queues commands and startup input in order. Include
pending edits followed by Source, New Note, Save, and termination snapshots. A new
page identity must reject old replies/input. Verify rich node counts after reopening,
not just source equality: `[Bookmark](url)` on a line without surrounding blank lines
must reopen as a card. Preserve original Markdown on load/Undo and untouched blocks
on edits, including blank rows and reference definitions. Changed blocks may normalize
equivalent Markdown spelling and inline-to-block boundary spaces.

## Establish the actual editing surface

1. Identify the opened bundle's `CFBundleVersion`, executable path, and executable UUID from the current worktree. Local development builds (`LUNA_DEVELOPMENT_BUILD=1`) show that ID in the footer; compare it with the screenshot. Regular releases omit the footer ID, so read their bundle metadata instead. Enumerate running Luna copies; an installed copy can coexist with `dist/Luna.app` despite sharing a bundle identifier.
2. Identify the note language and surface. New private notes default to Markdown Live View. Plain Text and Markdown Source are literal native text editors. File-backed notes and oversized prose can use different paths. Test the surface the user actually used.
3. Preserve the latest recovery records before relaunching. Use a private backup and compare note IDs plus text/language fingerprints afterward. Create disposable notes for destructive keyboard tests; remove only those notes after verification. Keep backups until preservation is confirmed.

Completion: the running build, editing surface, and protected user-note baseline are known.

## Reproduce the visible symptom

- Copy the user's layout into an isolated fixture, including lines above/below the caret, empty rows, rich blocks, original list markers, and invisible anchors. A freshly loaded DOM and one produced by native typing can differ: WebKit creates DIV/P/BR trees during editing.
- Type letters individually and inspect screenshots after each letter. Include native AppKit keyboard events in regression tests; synthetic DOM key events alone do not prove native editing or focus works.
- Live View now uses the native browser caret. Inspect its model selection and DOM range geometry without adding a second drawn caret. `LUNA_DEVELOPMENT_BUILD=1` identifies the opened bundle in the footer; the former Control–Option–D custom-caret guide no longer applies.
- Measure the actual selection node/offset, visual glyph edge, and drawn caret independently. A caret after the correct character can still have wrong geometry. Compare screenshots with measurements rather than assuming either is authoritative.
- For a suspicious marker gap, select it and press Backspace in the disposable note, then inspect exact source and DOM text. A highlighted gap can contain a real separator; visual appearance alone did not distinguish it during the October 11 investigation. Confirm which surface renders it before adjusting spacing.
- Build a fast regression that fails on the reported symptom before changing behavior. Minimize one variable at a time; record which prior checks passed despite the bug. Label speculative defensive changes separately from verified causes.

Completion: the old code fails a repeatable native or DOM regression and the visible failure matches the user's example.

## Historical traps in the replaced DOM editor

| Trap | Lesson and regression seam |
| --- | --- |
| Trailing U+200B in the same text node as a letter | WebKit can divide the letter's advance between it and the zero-width anchor. Both a collapsed range and a range selecting only the letter report the wrong edge, making comparisons between them falsely pass. Include the trailing anchors in the shaped glyph measurement. Draw using a cloned range advanced past anchors while retaining the editing selection. Cover same-node, separate-node, and span anchors at multiple font sizes. |
| Caret at offset zero beside a styled marker or link | WebKit can type inside the previous inline element and inherit its style. Place body typing after a normal text anchor. Repair missing anchors after cross-line deletion and restored-prefix Undo. |
| Hiding every terminal BR | CSS can preserve an empty row’s visual height while removing its native caret stop. Leave its sole BR in layout; hide only redundant trailing BRs. Verify native Up/Down through one and consecutive blank rows, after a list and in plain prose, plus typing on the expected row. |
| Empty paragraph with no range rectangle | Fall back to the actual empty paragraph's line box; verify several consecutive empty paragraphs and a visible text-height caret. |
| Selection changes after window blur | Track window focus and cancel pending frames so late events cannot revive the caret. Native caret remains available during composition. |
| Replacing the whole paragraph tree to indent lists | Native paragraph boundaries can duplicate blank lines and save a trailing row. Limit the editing transaction to touched prefixes and intervening content; flatten inserted boundaries where needed. Verify geometry and exact source through indent, outdent, continuation, empty-item exit, and numbering. |
| Removing an empty styled prefix | WebKit can carry bullet font size or centered alignment into later typing. Insert a normal body anchor and verify subsequent body font/alignment. Backspace must skip a leftover anchor so the next press joins lines immediately. |
| JavaScript insertion immediately after a native key | A fixed sleep does not prove WebKit has reached the intended editing state. Wait for exact source and caret prefix, then insert in the same JavaScript turn without repositioning the caret. Fail if the native key never reaches that state; retain the original native-input, geometry, and source assertions. |
| Native undo history persists across fixture edits | Assigning DOM text does not reset WebKit's undo history. Use fresh pages for independent undo scenarios. Consecutive deletions may coalesce differently across OS/WebKit versions; isolate prefix-removal undo from last-letter deletion while retaining assertions for both. Prove the revised regression still fails when the actual marker-caret correction is removed. |
| Undo restores a selected marker | Typing may replace the marker with enlarged letters. Collapse selections consisting solely of an intact restored marker into its body anchor; preserve ordinary selections. |
| Comparing whole-note selection strings | Layout/Undo can change a selected trailing newline while boundaries stay identical. Track a live Range and compare endpoints. Cover leading text and leading bookmark notes. |
| Repositioning the caret after the first replacement character | Moving to an element boundary can split native typing's Undo group. Retain the native text-node caret; one Undo should restore all original text and rich blocks after typing a word. |
| Reloading the page to clear or replace content | The next typed character can disappear as focus/loading changes. Use editing transactions in the existing page. New-note loading uses page-identity guarded focus/input replay; exercise typing immediately after New Note and attachment insertion during loading. |
| Cmd+A or Save in link fields | Select All belongs to the focused input, and Save must restore body typing outside the link. Exercise both fields, Tab/Shift+Tab, Save, immediate typing, and list continuation. |
| Selection toolbar disappears when its URL field takes focus | WebKit collapses the document selection when an input gains focus. Retain the saved editor range while the form is open, including selection highlighting and viewport positioning. Wait across selectionchange/animation-frame updates before entering and submitting a URL; a synchronous click/fill/submit test can pass before the form disappears. |
| Edit Link flashes closed for a long title or URL | Focusing or typing in overflowing inputs emits internal horizontal scroll events. A document capture listener sees those events too. Ignore scroll targets inside the link popover when dismissing menus for note scrolling. Short input fixtures can pass while long-field focus fails; verify both fields across event boundaries, field Select All, saving, and real note scrolling. |

The replaced editor used invisible anchors and marker metadata. ProseMirror uses document nodes and list attributes instead. Preserve `-`, `*`, `+`, and legacy literal `•` identity in portable source; the rendered circle is presentation. Literal Source intentionally exposes the Markdown separator; Live View uses layout spacing.

## Exercise a complete writing sequence

Use fresh and reopened notes, both single text blocks and text mixed with bookmarks/mentions. Check:

- New Note followed immediately by typing; Source/Live switching; Plain Text literal syntax and pasted URLs.
- Bullets with `-`, `*`, and `+`; numbers through at least 3; empty-item exit; a new list afterward; Return after converting a pasted URL to Mention.
- Backspace through every body character, then prefix removal, then line joining. Undo/Redo and continued typing must retain normal body size.
- Tab/Shift+Tab on current and selected items, with one Undo restoring a multi-item change.
- Shift+Up selection/deletion, then typing. Cmd+A deletion/replacement/cut/paste, then immediate typing and one-step Undo/Redo, including a note beginning with a bookmark.
- Exact literal Source and saved recovery text, marker/content alignment, absence of saved anchors and extra blank rows, and caret position on each individual letter.

Completion: the original fixture and native keyboard sequence pass visibly; the relevant regressions and required suite pass; debug probes are removed; current bundle identity and preserved notes are verified. Record findings, follow-up corrections, remaining coverage limits, and release status in the implementation log.
