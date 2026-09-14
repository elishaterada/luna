# Luna implementation history for LLMs

This log starts with the September 13, 2026 editor changes. Earlier shipped features are summarized in `CHANGELOG.md`; earlier implementation details have not been backfilled. Entries describe verified behavior and decisions, with files as navigation points rather than a diff transcript.

## 2026-09-13 — 0.7.0: editor interactions and persistent agent history

**Request:** Remove the sidebar tagline; make directories clickable in Finder; format lists without selecting Markdown or Preview; show modification time; offer four URL paste formats; use cover sizing for background photos. Follow-ups requested white directory segments with independent hover underlines, fetched preview titles, minute precision, and clicks below the note that place the caret on its last line. Also establish this ongoing LLM log.

**Behavior and implementation:**

- `Workspace.swift`: removed the sidebar tagline and added a visible localized modification date/time with minute precision. `LunaCore/Note.swift` initializes an opened file's modification date from its disk timestamp. Normal edits still update `modified`; recovery and explicit file saving retain their existing semantics.
- `NotePathView.swift`: displays the full absolute path as separate white directory buttons, each opening its own URL through Finder. Only the hovered button is underlined; separators and the final filename remain plain text. This replaces the initial implementation that linked the whole subtitle to its parent folder.
- `NoteLists.swift` and `EditorView.swift`: plain-text and Markdown editing convert list prefixes into portable Unicode bullets and checkboxes; ordered `n)` becomes `n.`. Enter continues numbering or an unchecked task; Enter on an empty list item ends the list. Checkbox markers toggle on click. Syntax highlighting adds hanging indentation. Other language modes retain literal input; conversion avoids fenced code with a bounded context scan. These are text transformations, not an attributed-document storage format.
- `MediaNoteView.swift`: matching list input/continuation behavior in editable text blocks. The source/live-view boundary and media attachment storage remain in place.
- `URLPasteChoice.swift` and `NoteEmbeds.swift`: URL pasting explicitly chooses plain text, linked text, preview chip, or iframe embedding. Persistent link syntax is `[label](url)`, `[Preview](url)`, or `[Embed](url)` on its own line. Bare URLs no longer automatically become embeds when reopening a note. HTML iframe pastes extract the URL and use the same chooser.
- `LinkMetadata.swift`: preview chips asynchronously fetch Open Graph, Twitter, or HTML document titles in that order; decode common HTML entities; cache successful titles in memory; retain the domain when unavailable. Fetches use an ephemeral session, 12-second timeout, and a 512 KB read limit. Page scripts are not executed for metadata. `MediaNoteView` inserts title text via `textContent` and rejects stale-page responses; metadata does not change note source or its timestamp.
- `SkinBackground.swift`: photos always use aspect-fill/cover, matching video sizing. Removed the softened-edge fit setting from `SkinSettingsView.swift`; the legacy stored configuration field remains readable.
- `MediaNoteView.swift`: blank-background mousedown below the final block focuses the last editable line and collapses selection to its end, without inserting line breaks. Body covers the viewport. Link/media controls and clicks above the end retain their behavior. The regular native editor already received blank-area clicks; the reproduced failure was in the live view.
- `AGENTS.md`: directs future agents to consult and maintain this log for each completed change and to record verified release status.

**Verification:** 71 Swift tests passed after the interaction fixes, including `BlankEditorClickTests`, `NoteRefinementsTests`, and expanded `EditorBehaviorTests`. The blank-click test failed before the fix, then passed and confirmed typing appends on the last line without added newlines. Directory tests check per-button hover styling and parent URL mapping. Metadata tests cover priority, entities, fallback, and safe display. A live fetch of `https://example.com` returned `Example Domain`. Ad-hoc development build completed and was reopened for user testing.

**Limits to preserve:** Sites may block iframe embedding. Metadata can be absent or inaccessible and is not persisted for offline relaunches. List markers are saved as Unicode text; this is not a full Markdown WYSIWYG editor. The native code-fence scan is bounded to preceding 32 KB. Public distribution uses the existing ad-hoc signing plus Sparkle signatures, not Apple notarization.

**Release status:** Preparing 0.7.0. Public release and updater verification pending.
