# Luna user guide

[← Back to Luna](../README.md)

Run repository commands in this guide from the repository root.

A native macOS text editor for a quick config edit, a note you don't want to name, or a conversation worth putting on screen.

Luna uses AppKit and TextKit 2. Media notes and Markdown previews use WebKit. No Electron, language servers, or project indexing. Sparkle is the only package dependency and handles signed app updates. The editor starts at 18 pt with generous margins, Sora’s adaptive graphite-and-teal palette, and explicitly grouped native controls. Window navigation sits beside the window buttons, Present and source/live-view controls sit in the document header, and text-size controls sit beside the size readout in the status bar.

## Download and updates

Download the latest build from [GitHub Releases](https://github.com/elishaterada/luna/releases/latest). Move Luna.app into Applications, then open it. Like Sora, these preview builds are ad-hoc signed and not Apple-notarized; follow the release page's first-open instructions.

Luna automatically checks for signed updates. Use **Luna → Check for Updates…** to check manually or **Automatically Check for Updates** to change the preference. Updates show the release highlights before installation and checkpoint your notes before relaunching. Earlier development builds without Sparkle need one manual installation of this version.

See [the release runbook](releasing.md) for the complete GitHub publishing process.

## Run

Requires macOS 14 or newer. Building requires Xcode 26's command-line tools and Swift 6.

```sh
./Scripts/build.sh
open dist/Luna.app
```

Open the project in Xcode with `open Package.swift`, or use `swift build` / `swift test`.

## Open from the terminal

```sh
./Scripts/luna notes.txt data.csv
./Scripts/luna .env config.yaml README.md
```

For a permanent installation:

```sh
./Scripts/install.sh
```

This installs the app in `~/Applications`. On first launch, Luna recommends enabling the **luna command**. Choose **Enable luna command**, then open a new terminal tab and run `luna notes.txt data.csv`. Pass one file path or several to open text-based files, including notes, CSV data, JSON, Markdown, and source code.

**Luna → Settings… (⌘,) → Command Line** lets you enable, update, or disable the command anytime. It installs `~/.local/bin/luna`. The recommended checkbox adds an idempotent, marked PATH block to `.zshrc` (or the `ZDOTDIR` directory when present in Luna’s environment). Disable removes only Luna’s launcher and marked block. Existing unrelated commands are never overwritten. If you use another shell or manage PATH yourself, uncheck this option and add `~/.local/bin` through your own shell setup. App installation alone does not change shell configuration.

The command accepts relative paths, absolute paths, multiple files, and quoted names containing spaces. Running `luna` alone opens the app. Finder's **Open With → Luna** also works; Luna does not take over default file associations.

## Inline calculations

End an arithmetic expression with `=` to see a muted result at the cursor. Press **Tab** to insert it or **Escape** to dismiss it. For example, `Workshop Value: $150 x 2080 = ` suggests `$312,000`. Suggestions are not saved until accepted, and accepting one can be undone normally.

Calculations support `+`, `-`, `*` / `x` / `×`, `/` / `÷`, parentheses, decimals, and comma-grouped numbers. Dollar amounts keep their `$` prefix; results use thousands separators and up to six decimal places.

| Type | Example | Suggestion |
| --- | --- | --- |
| Percentage | `$41,000 / $312,000 as % =` | `13.14%` |
| Percent of an amount | `20% of $85 =` | `$17` |
| Percent adjustment | `$85 + 20% =` | `$102` |
| Conversion | `180 cm in feet =` | `5 ft 10.87 in` |
| Mixed lengths | `5 ft 8 in + 10 cm in cm =` | `182.72 cm` |
| Mixed weights | `2 lb + 8 oz in lb =` | `2.5 lb` |
| Mixed volumes | `1 L + 250 ml =` | `1.25 L` |
| Time total | `1h 25m + 45m =` | `2h 10m` |
| Date math | `Sep 13, 2026 + 30 days =` | `Oct 13, 2026` |

Conversions accept `in`, `to`, or `as`. Supported units cover metric and imperial lengths and weights, liters/milliliters, and seconds through weeks. Compact `m` means minutes in expressions containing explicit time units, and meters otherwise; use `min` or `meters` to be explicit. Incompatible quantities produce no suggestion. Date math accepts `today`, ISO dates, or English month names, with whole days, weeks, months, or years; omitted years use the current year.

Name values on earlier lines, such as `Hourly rate: $150` and `Hours: 2080`, then type `Hourly rate x Hours =` to suggest `$312,000`. Names are case-insensitive and can contain spaces. Earlier calculated definitions can also be referenced: `Value: Hourly rate x Hours = $312,000`. Suggestions recalculate from the expression, so editing a source value affects subsequent suggestions even if an earlier accepted result is stale. Accepted results remain ordinary text. Reference lookup covers the preceding 32 KB of the note.

Currency conversion is **off by default**. Enable **Settings → Editor → Enable online currency conversion** after reviewing the external-service disclosure. It works with `100,000 baht in USD =`, `THB 100000 to EUR =`, or `$100 in THB =`. Use ISO currency codes or common names such as baht, dollars, euros, yen, and sterling (`$` means USD). Press Tab to accept an approximate result such as `≈ 3,025.00 USD`; the amount depends on the current reference rate. Hover over the editor to see the rate's date and source.

Rates come from [Frankfurter's free, no-key API](https://frankfurter.dev/). Luna sends only the currency pair, calculates the amount locally, and caches rates for 24 hours across app launches. A valid cache works offline; otherwise the editor shows that the exchange rate is unavailable. Fetches run after a short typing pause, duplicate requests share one lookup, and failures pause retries for five minutes. Reference rates older than seven days are rejected. Rates are estimates, not live bank or card quotes. Turning currency conversion off cancels pending lookups and disables currency suggestions, including cached results. No currency API requests are made while it is off. Ordinary calculations stay entirely local.

## Appearance and editor settings

The default workspace uses Sora’s full-window Liquid Glass on macOS 26, with native frost on earlier systems and a solid accessibility fallback.

Settings uses a native sidebar with Appearance, Skins, Editor, Command Line, and Shortcuts pages. Choose System, Light, or Dark appearance; select a monospaced font and size; or enable compact spacing for a tighter notes shelf. Adjust line spacing and editor padding independently. Appearance changes apply immediately, and text size adjustments from the menu are remembered. Restore Appearance Defaults returns to dark, SF Mono, 18 pt, 30% line spacing, 40 pt editor padding, and comfortable spacing.

Editor settings lets you choose two, four, or eight spaces for indentation, insert literal tab characters, continue indentation on Return, check spelling, wrap long lines, and toggle syntax colors. Presentation mode has its own minimum text size. Presentation mode temporarily enlarges text and hides the notes shelf; leaving it restores your previous sidebar choice. Use File → Save or ⌘S to save an existing file or choose a path for a scratch note.

Appearance also includes Sora’s optional playful effects: ambient glow, eight varied typing impacts with adjustable strength, ten synthesized keyboard sounds with volume and previews, and a Return-key light pulse. Effects start off, respond only to editor typing, and respect Reduce Motion for animation.

Skins supports local photos and videos, just like Sora. Click anywhere in the empty drop area to choose files, or drop multiple photos and videos onto it. Luna copies imports into `~/Library/Application Support/Luna/Skins`, prepares previews, and keeps a persistent library. Choose a readability tint, per-skin background color, optional pointer perspective, or scheduled rotation. Videos start muted; playback pauses when the app is inactive or hidden. Reduce Motion pauses video and perspective; Reduce Transparency uses a solid background. Photos cover the full background. Removing a skin removes only Luna’s copy.

For a local feedback build that cannot be replaced by the public updater:

```sh
LUNA_DEVELOPMENT_BUILD=1 MARKETING_VERSION=0.1.2-preview CURRENT_PROJECT_VERSION=20260913053000 ./Scripts/build.sh
```

The preview disables update checks only in that generated bundle. Normal release builds retain updates.

See [the design notes](design-cohesion.md) for the patterns shared with Sora.

## Everyday use

| Action | Shortcut |
| --- | --- |
| New persistent scratch note | ⌘N |
| Open files | ⌘O |
| Save original / save a new note as a file | ⌘S |
| Save As File | ⌘⇧S |
| Find and replace | ⌘F |
| Delete selected note | ⌘Delete |
| Preview / source / live view | ⌘⇧M |
| Presentation mode | ⌘⇧P |
| Hide/show notes | ⌘⌥S |
| Larger / smaller text | ⌘+ / ⌘− |
| Close window; keep notes | ⌘W |

Presentation mode hides the notes shelf and file path and raises text to your presentation minimum (26 pt by default). Use macOS full screen (⌃⌘F) for more space. Choose a syntax language at the bottom of the window, including on scratch notes. Opening a file selects its language automatically.

Syntax colors cover Markdown, JavaScript, TypeScript, JSON, YAML, environment files, shell, Python, Swift, CSS, HTML, and configuration files. Highlighting is deliberately lexical, not compiler-backed; it doesn't validate code. Multiline tokens extending beyond the viewport context and embedded languages may have approximate colors.

## Your notes and files

- Notes recover across window closure and quitting. Recovery is debounced by 400 ms, written atomically on a serial background queue, and flushed before switching notes, closing, or quitting. A sudden crash can lose the last debounce interval.
- Recovery lives at `~/Library/Application Support/Luna/Recovery`. Each note is an independent JSON file. The directory is owner-only (0700), and records are owner read/write (0600). Recovery is local plaintext; it includes unsaved edits to opened files.
- Opening or editing a file never silently overwrites it. **Save** writes the original; **Save As File** chooses a destination. If the original's modification time changed, Luna offers a copy or explicit replacement.
- Clean file copies refresh from disk when selected. Unsaved edits remain authoritative until you save. If an original is unavailable, its recovery copy remains usable.
- UTF-8 and BOM-marked UTF-16 are supported. Existing line endings are retained, although new Enter presses use native LF. Binary / unsupported encodings are rejected. Existing Unix permissions are retained on save.
- **File → Delete Note** explicitly removes the recovery copy after confirmation; it doesn't delete the original file. Corrupt records are retained and reported without hiding healthy notes.

## Performance and validation

Read [the engine research](editor-engine-research.md), [measured performance](performance.md), and [raw release results](benchmark-results.json).

```sh
swift test
./Scripts/build.sh
python3 Scripts/benchmark.py
```

The benchmark launches isolated instances with temporary recovery directories. It measures initialization, the first event-loop turn, installing a 10 MB fixture, a real editor insertion (including the delegate's work), visible syntax coloring, issuing a scroll-to-end, and flushing recovery. It does not measure complete on-screen frame delivery or cold disk-cache launch.

Notes can open in multiple synchronized windows. It has soft wrapping, native undo/redo and find/replace, configurable space insertion for Tab, and optional matching indentation on Enter. It has no project tree, plugins, or LSP. Files over 100 MB are refused; giant individual lines and hundreds of restored notes need further stress testing. The GitHub release pipeline signs archives and appcasts with Sparkle Ed25519. Developer ID signing and notarization remain a separate distribution step; app bundles currently use ad-hoc code signatures, matching Sora.

### Markdown preview

For Markdown files or notes, choose **Preview** (⌘⇧M) to read formatted headings, emphasis, lists, task lists, links, tables, quotes, and fenced code blocks. Click a task checkbox to mark it complete or incomplete; Luna updates the Markdown source and keeps the change in local recovery. For files, use ⌘S to save to disk. Choose **Edit** to return to the source with your selection and undo history intact. Preview uses the current text size and appearance. Rendering stays on your Mac; raw HTML appears as text and images display their descriptions without loading external content. Documents above 2 MB remain available in the source editor.

The notes shelf uses compact, single-line filenames without file-type labels or repeated icons. A dot marks unsaved file changes; hover a row to see its full path. The compact-density setting reduces row height further.

Select a file in the notes shelf and use ↑/↓ to switch files. Focus stays in the shelf until you click the content or press →. Once the editor is focused, arrow keys move the cursor normally. New notes start in the editor, ready to type.


### Media and live embeds

Drop image, audio, or video files into a note to copy them into Luna and open an inline editing view. Text remains editable between media blocks. Paste an HTTPS URL or iframe embed code to add live web content; **Source / Live View** (⌘⇧M) switches between views. Removing a block removes its reference from the note; its local media remains available until the note is deleted.

Luna keeps imported files in `Recovery/Attachments/<note-id>/`, beside its existing note records. Originals can be moved or deleted after import. Duplicating a note copies its attachments independently. Saving a media note exports Markdown plus a sibling `<filename>.assets` folder; keep those together when moving or sharing the export. Opening that export in Luna imports its media again.

HTTPS embeds use isolated frames. Luna resolves iframe-based and photo oEmbed responses, including discovery links and common YouTube, Vimeo, Spotify, and SoundCloud endpoints. Sites that prohibit embedding, require authentication, or require script-only widgets may need the **Open original** link. Standard Markdown preview still escapes raw HTML; live content belongs to the separate media-note view.

## Direct note editing

Type bullet, numbered, or checkbox prefixes to format lists in plain-text and Markdown notes. Return continues a list and Return on an empty item ends it. List markers are saved as ordinary text. Paste a URL to choose plain text, linked text, a preview chip with a fetched page title, or a live iframe embed. Sites can disallow embedding; unavailable preview titles fall back to the domain.

The note header shows its last updated date and time to the minute. Each white directory segment opens that folder in Finder and underlines independently on hover. Clicking blank space below a live note places the cursor at the end of the last line.

For implementation decisions and verified changes, see [the LLM change log](llm-changelog.md).
