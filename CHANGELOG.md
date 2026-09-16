# Luna release notes

## 0.9.2 — 2026-09-16

- Ambient Glow now stays steady while typing; flashes occur only when Return Pulse is enabled and Return is pressed.

## 0.9.1 — 2026-09-16

- Fixed Delete Note in the three-dot menu and ⌘Backspace. The shortcut now acts on the selected note without deleting editor text.

## 0.9.0 — 2026-09-16

- Switch to the first nine notes with ⌘1–⌘9. Hold Command for one second to reveal inline shortcut reminders in the sidebar.

## 0.8.0 — 2026-09-15

- Hover over a note tab to reveal its actions menu. Pin, duplicate, share, open in a new window, and close or delete actions now show keyboard shortcuts; clean saved files close without a confirmation dialog.

- Improved Finder Open With registration for Markdown and unclassified files such as `.env`. Existing default apps remain unchanged.

- Drag files from Finder onto Luna to open them, including multiple files and files without a familiar extension. Drops work in the editor, previews, and notes sidebar.

## 0.7.1 — 2026-09-14

- Luna’s original code and documentation are now available under the MIT License. Third-party components retain their existing licenses.
- Support Luna voluntarily through Buy Me a Coffee directly in the Luna app menu, in Settings → About, or in the README. Luna remains fully usable for free; contributions help cover Apple Developer membership and AI-assisted maintenance costs.

## 0.7.0 — 2026-09-13

- Write bulleted, numbered, and checkbox lists directly in notes. Return continues the list; Return on an empty item ends it.
- Choose plain text, linked text, a preview chip, or a live site embed when pasting a URL. Preview chips fetch the page title.
- Open any directory in a note’s path directly in Finder. White path segments underline individually on hover.
- See the last updated date and time, down to the minute, above each note.
- Click below the end of a live note to continue typing on its last line.
- Enjoy photos that cover the entire background and a simpler sidebar without the tagline.

## 0.6.0 — 2026-09-13

- Convert currencies as you write, including `100,000 baht in USD =`, then press Tab to accept an approximate result. Rates are cached for 24 hours.
- Currency conversion is off by default. Enable it in Settings → Editor, where Luna explains that lookups contact Frankfurter and send only currency codes—not amounts or note text. Turning it off cancels pending lookups.
- See clearer terminal guidance with `luna notes.txt data.csv` and examples of the text-based files Luna can open.

## 0.5.0 — 2026-09-13

- Calculate as you write: finish an expression with `=` to see a subtle inline result, press Tab to accept it, or Escape to dismiss. Accepted results support undo.
- Work with percentages and price adjustments, convert units, and combine mixed lengths, weights, volumes, and durations such as `1h 25m + 45m`.
- Add or subtract days, weeks, months, and years from dates, including `today`.
- Reference named values from earlier lines, such as `Hourly rate: $150` and `Hours: 2080`. New suggestions use updated inputs; accepted results remain ordinary text.

## 0.4.1 — 2026-09-13

- Click Markdown preview checkboxes to mark tasks complete or incomplete. Changes update the source, support undo, and are kept in local recovery; use ⌘S to save opened files.
- Render task lines written with `[]`, `[ ]`, or `[x]`, including tasks without a leading list bullet.
- Keep attachment and embed close icons centered within their circular buttons.

## 0.4.0 — 2026-09-13

- Drag notes into your preferred sidebar order and pin favorites at the top. Your arrangement survives restarting Luna.
- Right-click notes to pin, duplicate, share, open in a new window, or delete. Use ⌘Delete to remove a note; saved files remain on disk.
- Edit the same note in multiple synchronized windows, with menu commands and shortcuts acting on the active window.
- Drop images, audio, and video into notes, then write between inline media blocks. Luna keeps its own attachment copies, including when you duplicate a note.
- Paste HTTPS URLs or iframe code for live embeds, with oEmbed support for common providers. Switch between Source and Live View with ⌘⇧M; sites that prohibit embedding can be opened through their original links.
- Save media notes as portable Markdown with a companion assets folder, and reopen those exports with their media intact.
- Enjoy a cleaner editor header: save through File → Save or ⌘S without an extra Save button.

## 0.3.1 — 2026-09-13

- Spot Luna more easily in the Dock with a larger full-body cat and a simpler moonlit icon, paired with Sora’s matching design.

## 0.3.0 — 2026-09-13

- Read formatted Markdown with headings, lists, tables, quotes, and code blocks. Switch between Preview and Edit with ⌘⇧M while preserving your text, cursor, and undo history.
- See more files in a simpler sidebar: single-line names, unsaved-change dots, and full paths on hover, without repeated icons or file-type labels.
- Browse files with ↑ and ↓ while focus stays in the sidebar. Press → or click the content to start editing; new notes are ready to type immediately.
- Enjoy more room for files with Open File and Settings available through the menus and their familiar shortcuts.

## 0.2.1 — 2026-09-13

- A new moonlit app icon pairs Luna’s cat silhouette with a softly shaded moon, midnight slate background, and mint note accent.

## 0.2.0 — 2026-09-13

### Make this space yours

- Enjoy Sora-inspired Liquid Glass, a refreshed app icon, and clearer editor controls with matching light and dark colors.
- Make your notes feel personal with photo and video skins. Click or drop files into the centered import area; Luna keeps its own copies and leaves your originals untouched.
- Fine-tune your skins with readability tint, transparent-image backgrounds, softened edges, optional perspective, and automatic rotation. Videos start muted.
- Add a little play with optional ambient glow, adjustable typing shake, ten keyboard sounds, and a Return-key light pulse. Animated effects respect Reduce Motion.
- Customize fonts, spacing, wrapping, indentation, syntax colors, spelling, and presentation size from the new settings sidebar.
- Keep your place when leaving presentation mode, save existing files directly from the toolbar, and start typing without a lingering empty-note hint.

## 0.1.1 — 2026-09-12

### Reliable updates

- Improved release checks ensure Luna’s download and in-app update feed are verified together, even when GitHub is busy.
- Your notes stay with you when Luna installs an update and reopens.

## 0.1.0 — 2026-09-12

### A little space to think

- Open a configuration file, change a line, and get back to your day with a lightweight native editor.
- Keep scratch notes without choosing filenames. Notes and unsaved file edits recover when you reopen Luna.
- Bring ideas into meetings with generous margins, readable syntax colors, and a larger presentation mode.
- Enable `luna ~/.zshrc` from the welcome setup or Settings to open files directly from your terminal.
- Receive signed updates inside Luna, with release highlights to review before installing.
