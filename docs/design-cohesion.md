# Luna and Sora design cohesion

Luna remains a focused native text editor. Its chrome now follows Sora’s semantic Panda palette: graphite surfaces, teal actions, peach values, blue functions, and pink keywords, with distinct light counterparts. The source of the design direction is Sora/Application/SoraTheme.swift and SoraSettingsView.swift, inspected alongside both running apps. Luna adapts the user-owned Sora skin library, playback view, and settings controls, with local regression tests. No new package dependency is required.

The workspace uses 13 pt note titles and 11 pt metadata, 32 pt toolbar targets, quiet selected-row fills, and hover feedback. Full note names and paths are available as tooltips. A shared spacing scale aligns document headings, editor text, dividers, and status content. Sidebar rows center their text vertically with 16 pt side padding, with one icon column shared by note rows and sidebar actions. Compact spacing reduces shelf rows from 68 to 56 pt. Editor padding is independent (16–80 pt, default 40). The minimum window width is 820 pt so the sidebar, document heading, and actions remain usable together.

Settings groups Appearance, Skins, Editor, Command Line, and Shortcuts in a native navigation sidebar. Sora’s relevant appearance controls carry over: System/Light/Dark, installed monospaced fonts, live font size, compact spacing, and restore defaults. Luna-specific controls expose line spacing, editor padding, line wrapping, syntax colors, spelling, literal tabs, indentation width, and presentation text size. Terminal installation keeps the existing safe installer and displays errors in place. Existing update controls remain in the Luna menu.

Appearance preferences are local and persistent. Dark, SF Mono, 18 pt, and comfortable spacing preserve Luna’s starting behavior. Presentation mode is temporary and restores the previous sidebar choice. The toolbar Save action matches the menu and keyboard shortcut.

Skins now supports photo/video import, copied originals, cached previews, per-skin background color, readability, softened photo edges, pointer perspective, audio opt-in, and rotation. Playback respects activity and accessibility settings. Agent clip downloading remains outside Luna because Luna has no agent workflow.

Feedback bundles carry `LunaDevelopmentBuild` and display 0.1.2-preview. Their updater stays off so a public 0.1.1 installation cannot replace the preview. Standard release builds are unaffected.

Validation: release build and signature verification; 25 tests covering recovery, command-line integration, editor input, skin persistence, image transparency, invalid imports/catalogs, rotation, and muted video import; native UI checks for light/dark appearance, compact spacing, settings navigation, presentation sidebar restoration, video rendering, horizontal scrolling, and syntax-color switching. Test media and notes were kept in an isolated recovery directory. this pass was visually checked on macOS 26.

## Control placement refinement

The floating five-icon toolbar mixed navigation, typography, presentation, and saving with equal visual weight. It is replaced by window-level sidebar navigation, labeled Present/Exit and Save actions at the document header, and minus/size/plus controls in the status bar. Presentation and sidebar toggles expose their current state and update their accessibility labels. Size controls disable at their limits.

Open File and Settings are matching 36 pt sidebar rows rather than a stretched native button beside an isolated gear. Their 18 pt icon columns and 12 pt icon-to-label gaps align with the note titles. A shared NSButton subclass draws the icon and label as one measured group, preserving native actions and accessibility while avoiding AppKit's expanding image-leading gap. Buttons expose hover, pressed, disabled, selected, and keyboard-focus states.

Presentation zoom changes the displayed text immediately and is temporary; leaving presentation returns to the normal editor size. Minus disables at the configured presentation minimum.

## Default glass and typing feedback

The default workspace now adapts Sora's WindowFrostView, including its near-clear window fill, regular Liquid Glass tint on macOS 26, native behind-window frost fallback, and Reduce Transparency handling. Opaque editor fills no longer conceal the glass. Custom skins still replace the default frost.

Sora's user-owned TypingImpact and TypingSound implementations are adapted without dependencies. Effects are window-owned, non-interactive decoration behind the editor and stored under Luna's editor.effects preferences. All effects default off. Only editor typing triggers feedback; shortcuts, held-key repeats, navigation, sheets, and other text fields are excluded. Recoil animates the content presentation layer without moving the window frame. Settings includes strength and sound previews.

The empty skin area is one native SwiftUI button with a full rectangular hit target and the same URL drop destination. Imports continue through the existing validated library pipeline.
