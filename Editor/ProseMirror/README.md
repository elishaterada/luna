# Luna Live View

The saved Markdown Live View uses an unmodified ProseMirror runtime in WKWebView.
The native Source editor, file handling, recovery store, notes shelf, presentation
window, and split Markdown preview remain Swift/AppKit features.

## Build

```sh
npm --prefix Editor/ProseMirror ci
npm --prefix Editor/ProseMirror run build
LUNA_DEVELOPMENT_BUILD=1 Scripts/build.sh
```

Exact dependencies and esbuild are pinned in `package-lock.json`. Generated editor
HTML and runtime licenses are committed under `Sources/Luna/Resources`, so normal
Swift builds and release packaging do not fetch JavaScript dependencies. The same
build also bundles the separate development trial in `Prototypes/ProseMirror`.

## Implementation

- `note-model.js`: schema, Markdown parsing and serialization. Mentions are inline
  atoms, Bookmark/Embed and standalone attachments are block atoms, and formatting
  uses marks. Task state lives in list-item attributes. Opening a note and Undo
  back to its original document preserve the exact source. Untouched top-level
  blocks retain their original spelling. Edited blocks serialize as Markdown,
  retaining bullet identity, link display syntax, and task conventions.
- `editor.js`: saved-editor state, transactions/history, input rules, list commands,
  slash menu, selection toolbar, add-link form, media node views, and native command
  replay. The browser paints its caret. There are no hidden anchors, DOM-to-source
  reconstruction, selection repair loops, or special bookmark Undo stacks.
- `links.js`: URL paste, five display choices, edit/copy/open/remove actions, and
  link node views. Metadata stays outside the document/history. Embeds are sandboxed
  frames with an Open original fallback. Only iframe `src` is imported from HTML.
- `MediaNoteView.swift`: page lifetime and main-frame-only bridge, ordered startup
  input/native commands, attachment URL serving, metadata/embed resolution, recovery
  callbacks, and a source snapshot before termination. Replies and edits are guarded
  by the current page identity; a closed or replaced page cannot update another note.

The native bridge serializes menu commands with subsequent typing. Pending edits
finish before switching notes, changing surfaces, saving, or closing. Native title
and URL fields retain their own selection/history, and focused iframe shortcuts
remain inside the iframe.

Luna's line-oriented conventions are preserved: an unindented line after a list
is ordinary prose, and numbered lists can begin above 1 after a heading line.
The parser uses virtual separators for these cases; it never adds those separators
to source. Blank writing rows are editable paragraphs. Legacy literal `•`, `☐`,
and `☑` are recognized alongside Markdown list/task syntax.

## Verification and limits

`ProseMirrorEditorTests.swift` exercises the saved document/command interface and
native AppKit → WKWebView keys. It replaces old tests that depended on invisible
marker spans, custom caret geometry, native DOM Undo, and DOM range repair. Source,
file/recovery, navigation, media, and native editor tests remain in the Swift suite.

Changed blocks can normalize equivalent Markdown syntax (for example emphasis
spelling or escaping). Converting inline content into a block can normalize boundary
spaces. Third-party embeds depend on the site's framing policy. Real marked-text
IME input-method switching still needs manual coverage; Unicode paste and normal
native typing are covered. Markdown tables and raw HTML are not executable editor
content; Source remains available for literal editing.
