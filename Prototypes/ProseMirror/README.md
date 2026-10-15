# ProseMirror trial — throwaway prototype

Question: Does ProseMirror provide predictable native keyboard editing in Luna's
WKWebView without Luna's marker anchors, selection normalization, custom caret,
or special whole-note Undo bookkeeping?

This experiment lives on `codex/prosemirror-prototype`. It is not a production
editor migration. The app opens it through **View → Try ProseMirror…** in a local
development build. All edits stay in memory in a separate window. The copy tab
receives a string copy of the active note; it has no reference to Luna's recovery
store or note model. Resetting an example or closing the window discards its edits.

## Run

The committed `Sources/Luna/Resources/ProseMirrorPrototype.html` is a self-contained
offline demo and can be opened directly. Its scripts and styles are bundled; no
network or server is required. To try it in the real macOS app:

```sh
LUNA_DEVELOPMENT_BUILD=1 Scripts/build.sh
open dist/Luna.app
```

Choose **View → Try ProseMirror…**. The prototype footer shows the app's build ID.
The standard editor and its saved notes remain in the main Luna window.

To rebuild the HTML after changing this prototype's source:

```sh
npm --prefix Prototypes/ProseMirror ci
npm --prefix Prototypes/ProseMirror run build
```

`build.mjs` bundles the pinned packages and their licenses into the app resources.
Swift packaging uses the committed output and does not need Node or npm.

## What to compare

- Left from the next empty bullet; typing and Undo at the previous item's end.
- Native Return continuation, Tab/Shift–Tab, prefix deletion, and blank lines.
- Selection and replacement across a bookmark, with one Undo restoring it.
- Formatting, copy/paste, Command–A, Command–Z, and Command–Shift–Z.
- Wrapped text, emoji, Japanese composition, and switching focus.
- The live Markdown output and optional document/selection state readout.

## Current limits

The parser/serializer uses ProseMirror's CommonMark schema plus a small atomic
bookmark/embed placeholder. It normalizes Markdown spacing and some syntax; exact
source preservation is not implemented. Legacy `•`/checkbox syntax is ordinary
text. Cards and images are placeholders, with no remote media loading or metadata
fetches. Luna's slash menu, link forms, file/media importing, recovery integration,
and full application command routing are outside this trial. Standard formatting,
selection, Undo/Redo, and plain-paste commands are routed in the prototype window.

## Verdict

Native checks in development build `20261015051955` passed for Left from the empty
second bullet followed by typing at the prior body's end, native Return
continuation/empty-item exit, Tab/Shift–Tab, Command–Z/Shift–Command–Z, replacing a
whole document containing a bookmark with one-step Undo restoration, actual Edit
menu Undo, Bold via Command–B, and Japanese/emoji paste. Replacing the copied user
note left all three original saved note fingerprints unchanged.

One behavior to assess: default Backspace at the empty second item joins it into
the previous item as another paragraph. Two native Undos restore the subsequent
typing and the list structure separately. This differs from Luna's explicit
prefix-removal behavior. Native Return on an empty item exits the list.

The initial evidence supports continued evaluation of this engine. It does not
establish complete editing, exact Markdown, accessibility, input-method, or
attachment parity. Actual marked-text IME composition remains unverified;
automation's direct Unicode key injection did not insert those characters, while
native clipboard paste did. This trial is not ready to replace the saved editor.
