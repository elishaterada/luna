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

## Keyboard policy

`exampleSetup` supplies the upstream schema keymap, platform base keymap, input
rules, and history. Backspace, Delete, arrows, selection, ordinary Return,
Shift-Return, list splitting/joining/lifting, and input-rule Undo use those defaults.
There are no Luna deletion or caret-navigation commands.

The intentional additions are limited to:

| Addition | Purpose and scope |
| --- | --- |
| Tab / Shift-Tab | Aliases for the stock `sinkListItem` / `liftListItem` commands. Outside a list they fall through to browser focus navigation; Tab does not insert spaces. The upstream list shortcuts remain available. |
| Return in a task | Call stock `splitListItem` with the new task unchecked. Ordinary lists and empty-item exit fall through to the upstream Enter chain. |
| Cmd-K | Open Luna's link UI. |
| Slash and link UI keys | Plain arrows/Return/Escape operate the visible menu or form. Modified Enter and selection keys belong to the editor; composition is left to the input method. |

The existing bullet/task input rules preserve Luna's marker and task attributes;
other Markdown input rules stay upstream. Their Undo is upstream as well.

Backspace on an empty second item first joins it into the preceding item as an
empty paragraph; a second Backspace joins to the preceding text end. Return on an
empty item exits the list. Typing after only the first Backspace continues a
paragraph **inside** the previous item. This is stock ProseMirror behavior, replacing
the former Luna rule that immediately lifted that line into standalone prose.
An empty paragraph inside a list follows the upstream Markdown serializer, which
can omit that transient trailing paragraph from Source until it contains text.

`MediaNoteView` retains ordered native menu-command/startup-input delivery. Queued
Enter/Backspace/Delete are dispatched through the editor's actual DOM handlers,
including the UI, input-rule Undo, schema/base keymaps, and browser integration.
If a synthetic deletion is unhandled, WebKit performs the native deletion and
ProseMirror observes it before replay continues. Queued text runs `handleTextInput`
before its standard insertion transaction, so input rules also work during startup.
Shift is retained. The bridge has no separate list/deletion algorithm, grapheme
index calculation, private ProseMirror calls, or DOM repair pass. Real IME input
and ordinary navigation remain native browser events.

AppKit still owns documented app shortcuts (including Cmd-Delete to delete the
selected note and Cmd-number to switch notes) and menu delivery for formatting,
Select All, paste, and Undo/Redo. These commands call ProseMirror commands through
the ordered bridge. Focused link fields and iframes retain their own editing.

Keep this list small: a new editing override needs an explicit product behavior
that the upstream commands cannot provide, with native/queued regression coverage.
An upstream-compatible behavior should be implemented by removing an override,
not by adding a corrective branch around it.

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
