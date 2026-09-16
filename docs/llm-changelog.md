# Luna implementation history for LLMs

This log starts with the September 13, 2026 editor changes. Earlier shipped features are summarized in `CHANGELOG.md`; earlier implementation details have not been backfilled. Entries describe verified behavior and decisions, with files as navigation points rather than a diff transcript.

## 2026-09-16 — Numbered note navigation and held-Command hints

**Request:** Switch notes with Command-number and show Warp-style inline reminders after holding Command for one second.

**Implementation:** `NoteShortcutWindow.swift` scopes ⌘1–⌘9 to each workspace window and schedules a one-second common-run-loop timer for Command alone. Hints reset on modifier release/change, key-window loss, and close; sheets suppress navigation and hint activation. `Workspace.swift` maps numbers to the current pinned/reordered shelf order, uses the existing recovery-aware selection path, preserves editor/list focus, and scrolls the selected row into view. `NoteListView.swift` displays muted inline labels in the existing action-button space for the first nine rows, restoring hover actions afterward. `CHANGELOG.md` adds an Unreleased highlight.

**Correction:** Added shortcut handling to the window's key-down event path as well as key equivalents after the first running-app check did not switch notes. Final rebuilt app successfully switched to the second row using ⌘2.

**Verification:** All 75 XCTest cases passed (60 Luna and 15 LunaCore). New `NoteNavigationTests.swift` coverage checks numbered selection, pinned order, unavailable numbers, recovered unsaved edits, label/action visibility, and hint reset. Development release build and nested code-signature verification passed. Gracefully quit and reopened `dist/Luna.app`; verified the running executable is this worktree's app and all four recovery-note text fingerprints remain unchanged. Native UI confirmed ⌘2 selects the second note. `git diff --check` passed.

**User review / release status:** User confirmed the feature works and authorized shipping as 0.9.0. Only the first nine notes have numeric shortcuts; hidden sidebars remain hidden. Release preflight passed: 75 Swift tests, 4 release-tool tests, stable version ordering, release build, nested signatures, and diff checks. Publication and installed-update verification are pending.

## 2026-09-15 — Hover note actions, shortcuts, and clean-file closing

**Request:** Reveal a three-dot actions button when hovering a note tab, show the same actions as the right-click menu, close already-saved files without an extra warning, and provide sensible keyboard shortcuts for every action.

**Implementation:** `Workspace.swift` now builds both the right-click and hover-button menus from one definition. `NoteListView.swift` adds a row-hover cell with an accessible ellipsis button. Actions target the hovered/right-clicked note while keyboard commands fall back to the selected note. A new Note application menu makes the shortcuts global: Pin ⌘⌃P, Duplicate ⌘D, Share ⌘⌃S, Open in New Window ⌘⇧O, and Delete/Close ⌘Delete. Clean files with a disk path close immediately and leave the file untouched; private notes and files with unsaved edits retain confirmation, with explicit data-loss wording for unsaved edits. `main.swift` adds the Note menu, `NoteNavigationTests.swift` covers the canonical menu, shortcut assignments, and confirmation policy, and `CHANGELOG.md` records the user-facing behavior.

**Verification:** The installed Xcode license remains pending, so the default build/test commands stop before compilation. With the previously verified explicit SDK/native-build workaround, the Xcode XCTest agent ran all 74 tests with zero failures, including the new note-actions test; two pre-existing tests emitted their known recovered layout-constraint warnings. The development release build and nested signature verification passed. Gracefully reopened `dist/Luna.app`, confirmed its running executable path belongs to this worktree, and confirmed all four recovery-note text fingerprints were unchanged across the final relaunch. Native UI review confirmed the new Note menu contains all five actions; automated coverage verifies their displayed key equivalents. The automation interface generates clicks rather than ordinary pointer motion, so it could not independently trigger the mouse-moved-only hover state; the row tracking implementation and accessible button were reviewed in code but the visual hover remains for user review in the open app.

**Release status:** Approved for inclusion in Luna 0.8.0 with the preceding Finder-drop and Open With improvements. Publication verification is pending.

## 2026-09-15 — Finder Open With registration; remote error remains unconfirmed

**Request:** Support assigning files to Luna through Finder Open With. User reports Finder error 2 for a Markdown file under `~/repos` on another Mac; the file opens through Luna’s picker.

**Diagnosis:** The affected directory does not exist on this Mac; user confirmed a different Mac. Native `NSWorkspace.setDefaultApplication(at:toOpenFileAt:completion:)` returned success for test files under this repo for both installed 0.7.1 and worktree builds. This API’s success alone does not prove the Finder preference persisted: a test file still displayed Cursor until assigned through Get Info. Independently exercised Finder Get Info → Open with → Luna 0.7.1 and closed the window successfully without error 2. Existing `.md` registration was already functional here. Do not claim the remote error was reproduced or fixed.

**Implementation:** `Resources/Info.plist` retains existing text/source types and adds explicit Markdown extensions (`md`, `markdown`, `mdown`, `mkd`) and a separate `public.data` fallback, all ranked Alternate. `CHANGELOG.md` describes this limited registration improvement. Refreshed only this worktree app’s Launch Services registration for local review; did not reset the system database or change existing file-type defaults. Association experiments touched only generated fixtures under `.build`.

**Corrections:** Initially tried `public.data` as a general fallback and then a legacy wildcard. The actual registered-app query still omitted `.ts` (classified by macOS as MPEG transport stream) and a dynamic unknown extension. Removed the wildcard and narrowed both implementation and user-facing claims. Final query offers the updated app for `.md`, `.txt`, Makefile, and `.env`; `.env` was absent before. Unknown dynamic types and `.ts` may still require Open With → Other → All Applications. File decoding remains UTF-8/UTF-16 text only, with the existing 100 MB limit.

**Verification:** `Scripts/build.sh` passed using the previous entry’s installed-toolchain/native-build workaround; app and nested signatures verified. Plist validation, 4 release-tool tests, and `git diff --check` passed. No Swift behavior changed, so did not rerun the 73 tests already passed in the preceding change. Gracefully reopened `dist/Luna.app`, confirmed its running executable path, and verified all four prior note-text fingerprints were unchanged. Prepared `dist/Luna-open-with-preview.zip` for optional transfer to the affected Mac. Preview retains development-build status; not a Sparkle release.

**Remaining limitation / release status:** The specific error 2 is unresolved without reproduction on the other Mac. No permission changes, file-content edits, forced defaults, installed-app replacement, commit, push, or release. The preview also includes the preceding Finder-drop changes. Apple’s declaration reference: https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/TP40009249-SW1

## 2026-09-15 — Open Finder file drops

**Request:** Drag any files from Finder into Luna to open them.

**Implementation:** File URLs now use the existing `Workspace.open` path instead of the media importer. The editor, live media view, Markdown preview, notes sidebar, and root content view accept file drops. Multiple files and arbitrary extensions are accepted; existing open files are selected without duplication, and existing note contents are preserved. Sidebar note reordering retains its internal move behavior. WebKit file drops no longer navigate the preview or insert attachments.

**Files:** `Sources/Luna/FileDrop.swift`, `EditorView.swift`, `MediaNoteView.swift`, `MarkdownPreview.swift`, `Workspace.swift`, `Tests/LunaTests/FileDropTests.swift`, and `CHANGELOG.md`.

**Verification:** All 73 XCTest tests passed, including two new tests covering pasteboard file extraction, non-file drags, multiple files, unusual extensions, content callbacks, duplicate selection, sidebar registration, and original-note recovery. Release build and nested code-signature verification passed. Default tools were blocked by a pending Xcode license and mismatched tool components; used the installed Xcode Swift binary with the native build system and macOS 26.5 SDK, plus explicit XCTest framework/overlay paths. SwiftPM discovered zero XCTest cases in this configuration, so ran the compiled bundle directly with Xcode’s `xctest` agent: 73 executed, zero failures. No system configuration changes or agreement acceptance. Gracefully quit/reopened `dist/Luna.app`; verified the running executable belongs to this worktree and matches the release binary. Accessibility confirms recovered notes, and all four preexisting note-text SHA-256 fingerprints match. `git diff --check` passed. Finder pointer-drag routing was not manually exercised; automated coverage checks extraction and destination callbacks.

**Limitations and release status:** Local implementation only; no publication. Open retains its UTF-8/UTF-16 and 100 MB limits; binary files and unsupported encodings show the existing error. Finder drops replace the former inline media-import gesture. Updated local development app is open for review.

## 2026-09-14 — Lead README with support and demo

**Request:** Put Buy Me a Coffee at the top and use the hero video as the first README visual.

**Correction:** Moved the support destination to a centered text link above the title, so a badge does not precede the hero. Moved the video poster and 18-second demo link into the hero position; moved the suggestion still into the calculation section and removed the duplicate lower video placement. The first image links to the H.264 MP4; playback requires clicking, not autoplay.

**Verification:** README local links resolve and the first image is the video poster. `git diff --check` passed. Asset bytes and application behavior unchanged. Required build passed; opened `dist/Luna.app` and verified the running executable belongs to this worktree. Existing notes were not edited.

**Publication:** Documentation follow-up for main; no application release or website deployment.

## 2026-09-14 — README desktop screenshots and demo

**Request:** Use the newly captured portfolio assets in README.md and push the update.

**Result:** Replaced the README hero, Markdown, and presentation images with the refreshed desktop captures. Added an accepted-answer image and a clickable video poster linking to the 18-second silent H.264 recording. Copied all six assets unchanged into `docs/screenshots/desktop/` so repository links are self-contained. Documented native 2674 × 1780 resolution, 57.75 fps average variable timing, isolated fictional 0.7.0 demo provenance, and the visible native capture indicator.

**Verification:** All README local links resolve; SHA-256 comparisons confirm every copied asset matches the reviewed portfolio original. The previous capture task reviewed all four screenshots, poster, and the complete 1,040-frame recording. `git diff --check` passed. No app behavior changed, so application tests were not rerun.

**Publication:** Prepared on top of origin/main after the 0.7.1 release commits, with unrelated local work preserved in the original checkout. Documentation-only push; no version tag, application release, or portfolio website deployment.

## 2026-09-14 — Portfolio desktop media refresh

**Request:** Replace gray window-only portfolio visuals and sampled demo with authentic desktop-composited screenshots, a smooth silent calculation-to-presentation recording, and a matching poster; preserve real notes/settings and do not change or deploy the website.

**Result:** Added four lossless WebP desktop screenshots, one lossless WebP video poster, and an 18.008-second H.264 MP4 under `/Users/elishaterada/repos/elishaterada-com/portfolio-handoffs/luna/assets/desktop/`. Updated that handoff’s `assets.md` with filenames, captions, alt text, dimensions, timing, provenance, and limitations. All assets are 2674 × 1780 native pixels. Video preserves variable timestamps, 1,040 frames, average 57.75 fps; no interpolation or upscaling.

**Implementation:** Native macOS desktop-region capture at 96,52,1337,890 logical points on the 2× display, around a fixed 1177 × 770 window with 80/60-point padding. Actual blue wallpaper influences the window materials; native shadow retained. Existing isolated 0.7.0 demo bundle and fictional workshop notes reused. No real user notes/settings, app source, or website implementation changed. Markdown preview captured at 16 pt to show the full table and quotation; demo font restored to 20 pt. Presentation uses its natural 26 pt.

**Corrections and verification:** First recording excluded the final transitions because tool round trips exceeded its duration; replaced with a timed continuous take and trimmed only start/end. First Markdown still clipped the table; recaptured through native font controls. Reviewed every screenshot/poster and all 1,040 video frames via sequential contact sheets, plus large state images. Blue materials remain visible, framing is stable, no unrelated windows/Dock/desktop icons/notifications/private content appear. WebPs decode at intended dimensions; first three are pixel-identical to source PNGs. Video fully decodes, H.264 with no audio. No application tests needed for media/documentation work.

**Remaining limitation and release status:** The native purple capture/privacy indicator and pointer remain visible, including in the hero reference; no retouching used. This does not satisfy an absolutely indicator-free requirement. VFR average is not constant 60/120 fps. Local handoff assets only; no commit, push, release, or website deployment. Existing unrelated changes preserved.

## 2026-09-13 — Portfolio handoff for elishaterada.com

**Request:** Prepare an evidence-backed portfolio story and real product visuals, without editing or deploying the website.

**Result:** Created /Users/elishaterada/repos/elishaterada-com/portfolio-handoffs/luna/ with portfolio-handoff.md, assets.md, a public release-metadata snapshot, six WebP images, and a 15-second silent MP4. Reviewed current documentation, relevant code, reachable commits, five accessible project tasks, and public release metadata. Distinguished confirmed facts, editorial interpretations, unknown adoption, and historical versus current verification. First-person drafts meet requested lengths; one proposed personal-learning statement is flagged for confirmation.

**Visuals:** Five new native captures show a fictional workshop calculation, acceptance, presentation, URL chooser, and Markdown guide. Reused the existing same-version desktop-composited screenshot as recommended cover. Used the pre-existing isolated README demo workspace; added only fictional demo notes. Demo executable matches installed 0.7.0 byte-for-byte. No real notes, product code, or website implementation changed.

**Verification:** All local handoff links resolve; images decode as WebP; video is H.264, 1268 × 768, 4 fps, 15 seconds, with no audio. Reviewed image composition and encoded demo states. Card/overview/story have 46/120/520 words. Confirmed public latest release is 0.7.0; recorded raw artifact download counts without treating them as users. App/release tests were not rerun for this documentation-only change.

**Limits and release status:** Local handoff only; no commit, push, app release, or deployment. Native capture returned 1267-pixel window images and a smaller dialog, below the preferred 1600 width; no artificial upscaling. New window captures show gray glass rather than desktop compositing; existing cover supplies authentic wallpaper context. Video is a 4-fps sampled interaction recording, not performance evidence. Personal takeaway, attribution preferences, external usage, and future direction need author confirmation. Existing unrelated changes were preserved.

## 2026-09-13 — GitHub Support purge request submitted

**Request:** Submit the prepared sensitive-data cleanup request to GitHub Support after explicit user authorization.

**Action and verification:** Submitted through the authenticated personal-account GitHub Support form. Included repository, first changed commit, old commit references, rewritten main and 11 tags, zero affected pull requests, no LFS objects, and the confirmed residual API access. The request explicitly asks to purge removed historical content, not delete the repository; it reproduces no private note content. GitHub displayed “Your message has been successfully submitted.”

**Status:** Submitted, awaiting Support review and server-side purge. The ticket portal initially reported that new tickets may take a few minutes to appear; no ticket number was available at submission time. This entry records submission, not completed removal of GitHub’s cached content. No application code or release artifacts changed.

## 2026-09-14 — Release 0.7.1 licensing and voluntary support

**Request:** User approved the direct menu support item and authorized publication.

**Implementation:** Versioned the MIT licensing, bundled license notices, README badge, Settings → About support page, and direct Luna → Buy Me a Coffee item as 0.7.1. Preserved all third-party license notices and free app functionality. Includes the instruction to open updated builds for review.

**Preflight:** All 71 Swift tests and 4 release-tool tests passed. Stable version-order check and `Scripts/build.sh` passed, including nested signing verification. The changed menu was exercised in the preceding entry. `git diff --check` passed.

**Release status:** Published [Luna 0.7.1](https://github.com/elishaterada/luna/releases/tag/v0.7.1), tag commit `b41c1b5`, build `20260914123653`. [Release workflow](https://github.com/elishaterada/luna/actions/runs/34843518372) attempt 3 passed all tests, signed packaging, and public latest-release/highlights/feed/ZIP verification, including byte-for-byte comparison with signed artifacts. Attempts 1 and 2 were cancelled after XCTest stopped progressing around the transition into skin tests without reporting an assertion failure. Attempt 3 passed with the same tag and unchanged checks; the intermittent hang's cause remains unconfirmed.

**Installed update verification:** Opened the installed 0.7.0 copy, used Check for Updates, reviewed the 0.7.1 highlights, and chose Install and Relaunch. Confirmed `/Applications/Luna.app` runs 0.7.1 / `20260914123653`, the direct Buy Me a Coffee menu item is present, and bundled Luna license/third-party notices match the repository byte-for-byte. All four pre-existing recovery files remain; three match their pre-update SHA-256 fingerprints and one note JSON changed during the review/update interval. Only whole-file hashes were recorded before the update, so text preservation for that changed JSON cannot be independently established from this check. No note contents were added to the log. Updated app remains open for review.

## 2026-09-14 — Direct support item in the Luna menu

**Follow-up request:** Make Buy Me a Coffee accessible in the app menu shown in the user's screenshot instead of requiring navigation into Settings.

**Implementation:** `Sources/Luna/main.swift` adds “Buy Me a Coffee” directly below Settings, targeting an app-delegate action that opens the confirmed https://buymeacoffee.com/elishaterada URL in the default browser. Existing Settings → About and README links remain available. Updated unreleased highlights in `CHANGELOG.md`.

**Verification:** Built the development app through `Scripts/build.sh`; compilation and nested signing verification passed. Gracefully quit and reopened Luna, confirmed the executable runs from this worktree, and opened the Luna menu. macOS accessibility reports “Buy Me a Coffee” present and enabled. Reviewed the action's exact destination; no payment interaction performed. `git diff --check` passed.

**Release status:** Updated local app opened for user review. Not committed, pushed, or released.

## 2026-09-14 — Open updated builds for user review

**Follow-up correction:** The user requested opening the app after every update. Added this preference to `AGENTS.md`, including preserving notes on relaunch and confirming the current-worktree build.

**Verification:** Built `dist/Luna.app` with `LUNA_DEVELOPMENT_BUILD=1`; build and nested code-signature verification passed. Confirmed bundled Luna license and third-party notices match the source files byte-for-byte. Gracefully quit the previously running app, opened this worktree's app, and confirmed its running executable path. Invoked the Settings menu for review; did not verify the About screen visually. `git diff --check` passed.

**Release status:** Local development app opened for review; nothing pushed or released.

## 2026-09-14 — Confirmed Buy Me a Coffee support links

**Follow-up request:** The user supplied and confirmed https://buymeacoffee.com/elishaterada as the public donation destination, resolving the account clarification in the previous entry.

**Implementation:** Added a modest linked Buy Me a Coffee badge under `README.md` → Support Luna. Added Settings → About in `Sources/Luna/CommandLineSettings.swift` with a native browser link and wording that Luna is fully usable for free, contributions help cover Apple Developer membership and AI-assisted maintenance, and support provides no feature unlocks or priority support. Updated `CHANGELOG.md` unreleased highlights. No automatic requests to the donation service are introduced in the app; the native link opens on user action.

**Verification:** `swift build` completed successfully and `git diff --check` passed. The exact user-provided URL returned HTTP 200 through a direct HTTP check after the web browsing tool could not open it. Reviewed the settings switch and link target. No payment was attempted; the native settings screen was not visually exercised. The README badge uses Shields.io with accessible link text.

**Release status:** Implemented locally; not committed, pushed, merged, or released. Donation URL clarification is resolved. Prior MIT and packaging changes remain in this worktree; no release archive was produced.

## 2026-09-14 — MIT licensing and voluntary support preparation

**Request:** License user-owned original code under MIT and add optional support, preferably Buy Me a Coffee, to help cover Apple Developer membership and AI-assisted maintenance. Keep Luna fully usable for free; no Pro implementation or publication authorized.

**Implementation:** Added the standard MIT text in `LICENSE`, attributed to Elisha Terada (2026). `README.md` scopes that license to original code and documentation, links the separate third-party notices, and explains voluntary support without feature gating or priority-support promises. `ThirdPartyNotices.txt` explicitly preserves component licenses. `Scripts/build.sh` now copies Luna's license and third-party notices into the app before signing, so future packaged apps carry them. Added unreleased highlights in `CHANGELOG.md`.

**Provenance review:** All 14 commits in the available all-ref history name Elisha Terada as author and committer; no co-author trailers were found. The repository remote is elishaterada/luna. Eight source files explicitly identify their Sora origin as user-owned, consistent with the user's authorization. Reviewed tracked source/resource inventory, dependency manifest and lockfile, attribution markers, and packaging paths. Sparkle 2.9.6 is the sole Swift package dependency; Marked 17.0.1 is vendored with its existing license, including its additional notice. Existing Marked and Sparkle license files/copy paths remain unchanged. No additional outside contribution was identified in this review. This is repository-evidence review, not an exhaustive external code comparison or independent ownership audit. MIT text checked against https://opensource.org/license/mit.

**Verification:** `zsh -n Scripts/build.sh`, all 4 existing release-tool tests, and `git diff --check` passed. No application behavior changed; no full app build or release archive was produced. Future license inclusion was inspected in the build script, not verified in a built artifact.

**Pending and release status:** Asked for the verified public donation URL; none has been supplied. No payment destination, placeholder button, account, or in-app support link was added. Once confirmed, add a tasteful README button and an appropriate About/settings link, then verify the destination and app change. Changes are local, uncommitted, not pushed, merged, or released; existing published binaries are unchanged. Future proprietary additions remain outside this request.





## 2026-09-13 — Remove private examples from published documentation history

**Request:** Remove private note content from README history so it is no longer exposed through repository history.

**Cleanup:** Removed `README.md` from every historical commit on main and release tags, sanitized a matching personal label in calculation test fixtures throughout history, and restored the reviewed promotional README with sample-only screenshots. Sanitized the copied user guide before publication. No screenshot files were present in the previously published history. Existing untracked personal assets were excluded. Application behavior and existing signed release archives are unchanged.

**Verification:** All 12 rewritten historical revisions contain no README and no matching personal label. The new README and guide use generic samples. Release source trees differ only in removal of README and the fixture label. Current documentation links resolve; all 9 calculation tests passed after building the sanitized source.

**Status:** Atomically force-updated GitHub main and all 11 release tags with explicit leases, then verified every remote ref. Temporarily paused and restored both workflows to avoid triggering release jobs. Published release asset IDs and metadata remain unchanged. GitHub still serves removed README versions by old commit ID, confirmed through its API; a GitHub Support sensitive-data purge is still required. Independent clones cannot be recalled. Historical commit hashes mentioned in earlier log entries refer to pre-cleanup history.

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
