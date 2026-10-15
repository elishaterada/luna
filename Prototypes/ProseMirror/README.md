# ProseMirror trial — throwaway prototype

Question: Does ProseMirror provide predictable native keyboard editing in Luna's
WKWebView without Luna's marker anchors, selection normalization, custom caret,
or special whole-note Undo bookkeeping? The current iteration also evaluates the
complete URL paste → Mention/Bookmark/Embed → conversion → Undo → Markdown reopen workflow.

This separate, memory-only trial remains available alongside the saved Live View
migration documented in [Editor/ProseMirror](../../Editor/ProseMirror/README.md). The app opens it through **View → Try ProseMirror…** in a local
development build. All edits stay in memory in a separate window. The copy tab
receives a string copy of the active note; it has no reference to Luna's recovery
store or note model. Resetting an example or closing the window discards its edits.

## Run

The committed `Sources/Luna/Resources/ProseMirrorPrototype.html` bundles its scripts
and styles and can be opened directly. In Luna, a small native bridge supplies
metadata fetching, embed discovery, browser/clipboard actions, and file dialogs.
URL previews and embedded websites require access to the pasted site. To try the
complete workflow in the real macOS app:

```sh
LUNA_DEVELOPMENT_BUILD=1 Scripts/build.sh
open dist/Luna.app
```

Choose **View → Try ProseMirror…**. The prototype footer shows the app's build ID.
The standard editor and its saved notes remain in the main Luna window.

To rebuild the HTML after changing this prototype's source:

```sh
npm --prefix Editor/ProseMirror ci
npm --prefix Editor/ProseMirror run build
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
- Paste a URL or iframe snippet, choose any of the five display styles, and keep typing.
- Edit the link title/URL, open the original, copy the URL, or remove the link.
- Metadata arriving without changing selection or adding an Undo step.
- Reopen Markdown, or explicitly export a separate file and import it again.

## URL workflow

The shared `Editor/ProseMirror/note-model.js` owns the schema and portable Markdown conversion. Mentions are
inline atom nodes, Bookmark/Embed items are block atom nodes, and normal links use
ProseMirror link marks. Display changes use one transaction with a valid body
selection; inserting a block splits the surrounding paragraph through ProseMirror.
Native Undo/Redo restores each conversion separately from later typing.

The shared `Editor/ProseMirror/links.js` owns the paste/display plugin, node views and popover. Metadata lives in
a URL-keyed view cache, outside document attributes and Undo history. Swift reuses
Luna's existing `LinkMetadata` and `EmbedResolver`; replies carry a page-session
identifier and subframes cannot call the native bridge. Node views render titles,
descriptions, favicons, preview images, and sandboxed iframe players. An explicit
Open original action remains available when a website declines embedding.

The serializer preserves Luna's `[URL](...)`, `[Mention](...)`, `[Bookmark](...)`,
and `[Embed](...)` conventions; legacy `[Preview]` imports as a Bookmark. Copying
nodes preserves display syntax. Ordinary URLs pasted into code stay literal, and
Command–Shift–V bypasses conversion. Invalid/credential-bearing URLs and iframe
scripts/attributes are not imported. File export/import only uses paths chosen
in native dialogs; it never saves to the original note automatically.

## Current limits

The trial shares the saved editor's schema and link workflow, but retains its own
example UI and command setup. It has no recovery writes, local attachment serving,
or startup input queue. Use the main Live View for slash commands, tasks, saved
notes, and attachments. Third-party iframe availability depends on the provider.
The standalone HTML has no native metadata or file-dialog bridge.

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
native clipboard paste did. The trial itself remains a diagnostic surface; the saved integration is separate.

The URL iteration additionally passed an agent-run check over 20 combinations of
paragraph/heading/list placement and display choice, conversions in both
directions, conversion Undo/Redo, whole-note paste Undo across a Bookmark, Markdown
reopening, metadata/history isolation, and URL/iframe validation. Native checks
confirmed actual URL paste, Mention/Bookmark metadata, body typing, separate Undo
steps, an interactive iframe, link field shortcuts and title/URL editing, and
native Markdown export/import restoring the Embed and surrounding text.

Handoff build: `20261015133747`, with the matching ID visible in both Luna
footers. All 166 existing Swift tests pass. Native iframe field Select All stays
inside the frame; late metadata does not add history. A public Bookmark's title,
favicon and preview image were verified. Wait for the trial's editor to appear
before typing/pasting; this prototype has no input buffering during initial load.
