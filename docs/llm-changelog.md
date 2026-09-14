# Luna implementation history for LLMs

This log starts with the September 13, 2026 editor changes. Earlier shipped features are summarized in `CHANGELOG.md`; earlier implementation details have not been backfilled. Entries describe verified behavior and decisions, with files as navigation points rather than a diff transcript.





## 2026-09-13 — Remove private examples from published documentation history

**Request:** Remove private note content from README history so it is no longer exposed through repository history.

**Cleanup:** Removed `README.md` from every historical commit on main and release tags, sanitized a matching personal label in calculation test fixtures throughout history, and restored the reviewed promotional README with sample-only screenshots. Sanitized the copied user guide before publication. No screenshot files were present in the previously published history. Existing untracked personal assets were excluded. Application behavior and existing signed release archives are unchanged.

**Verification:** All 12 rewritten historical revisions contain no README and no matching personal label. The new README and guide use generic samples. Release source trees differ only in removal of README and the fixture label. Current documentation links resolve; all 9 calculation tests passed after building the sanitized source.

**Status:** Prepared for history replacement on GitHub main and all 11 release tags. Server verification follows. Old commit caches and independent clones are outside a Git push’s control; GitHub Support may need to remove cached views. Historical commit hashes mentioned in earlier log entries refer to pre-cleanup history.

## 2026-09-13 — Hero screenshot recapture only

**Request:** The first README image still appeared washed out; retry only that image.

**Correction:** Recaptured the normal notes view from the composited desktop with the editor focused, preserving the existing wallpaper and 80/60 px padding. Saved a lossless PNG as `docs/screenshots/luna-notes-desktop.png` and changed only the first README image reference. A fresh filename also avoids reusing a cached copy of the old image; caching was not confirmed as the cause. Removed the superseded hero JPEG. Markdown and presentation images were left unchanged.

**Verification:** Visually inspected the actual saved PNG for saturated wallpaper, readable text, complete window and shadows. PNG header confirms 1260 × 860 dimensions. README points to the new file. `git diff --check` passed. No application code or preferences changed.

**Release status:** Local documentation/assets correction only; not committed, pushed, or released. The native capture indicator remains visible.

## 2026-09-13 — Screenshot correction: desktop glass and padding

**Request:** Fix the washed-out, tightly cropped promotional screenshots; capture against the current desktop wallpaper with space around the window.

**Correction:** Replaced all three `docs/screenshots/luna-*.jpg` images with actual desktop-region captures, including wallpaper, window shadows, and 80 px horizontal / 60 px vertical padding. The previous window-only capture omitted the desktop compositing behind the glass and produced a gray appearance. Native `screencapture` of the display region preserves the wallpaper through the translucent window. Read the sample window’s current Core Graphics bounds for each capture. No synthetic background, retouching, or app appearance changes. Updated the README screenshot caption. This supersedes the original entry’s window-only capture method and dimensions.

**Verification:** Visually inspected notes, Markdown preview, and presentation captures; each is 1260 × 860 and shows the complete window with padding, readable content, and the desktop wallpaper. Sample-only recovery workspace retained; original notes untouched. `git diff --check` passed. Documentation/assets only; no application build or tests needed.

**Release status and limits:** Local changes only; no commit, push, or release. The macOS capture indicator remains visible in the title bar. The temporary capture helper and intermediate screenshots are outside the repository.

## 2026-09-13 — Promotional README and app screenshots

**Request:** Promote Luna in the README, explain its benefits, compare it with Apple Notes and popular note apps (correcting the initial terminal-app comparison), and take actual app screenshots.

**Result:** `README.md` leads with scratch notes, direct file editing, calculations, presentation, media, and appearance benefits, includes three screenshots, and compares workflows with Apple Notes, Bear, Obsidian, and Notion. Download, signing, privacy, platform, and build information remain. Competitor descriptions cite official documentation checked September 13, 2026 and acknowledge Apple Notes math, Bear’s native implementation, and Obsidian’s local storage. Prior detailed README content is preserved in `docs/user-guide.md`, with relative links adjusted and repository-root command context added.

**Screenshots:** `docs/screenshots/luna-notes.jpg`, `luna-markdown.jpg`, and `luna-presentation.jpg` are unedited native-window captures of installed Luna 0.7.0. A temporary copied app uses a distinct bundle identifier and `LUNA_RECOVERY_DIR` pointing to sample-only records; the actual recovery workspace was not modified. Captures show the notes shelf, Markdown preview, and presentation mode. Temporary sample app lives outside the repository at `/tmp/luna-readme-demo`.

**Verification:** Visually inspected all three final captures and confirmed content via accessibility state. All local Markdown links in the README and user guide resolve. File inspection confirms three 1100 × 740 JPEGs. The capture API returned JPEG bytes; initial .png names were corrected to .jpg before completion. `git diff --check` passed. No application source changed; no build or runtime unit tests were needed for this documentation-only change.

**Limitations and release status:** Implemented locally; not committed, pushed, or released. No performance superiority claims or exhaustive competitor matrix. Images reflect macOS window materials and include the system capture indicator. Competitor features and plans may change. No release entry added to `CHANGELOG.md` because no app release was requested.

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

**Release status:** Published [Luna 0.7.0](https://github.com/elishaterada/luna/releases/tag/v0.7.0), tag commit `2a269f1`, build `20260914032538`. Local preflight passed 71 Swift tests, 4 release-tool tests, version ordering, and stable packaging. The first GitHub run stalled during XCTest without an assertion failure and was cancelled before publication. Attempt 2 on a fresh runner passed all 71 Swift tests and all 4 release-tool tests using the unchanged tag and original checks; the initial stall's cause remains unconfirmed. [Release job](https://github.com/elishaterada/luna/actions/runs/34802177412) completed successfully and verified the public latest-release endpoint, highlights, signed appcast, and ZIP byte-for-byte against the signed artifacts. The installed `/Applications/Luna.app` updated from 0.6.0 through Sparkle's Install and Relaunch flow; its plist reports 0.7.0 / `20260914032538`. All three existing recovery-note text fingerprints matched before and after the update.
