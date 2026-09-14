// Adapted from the user-owned Sora project; local media only, without Agent dependencies.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SkinSettingsView: View {
    @ObservedObject var library: SkinLibrary
    @State private var removing: EditorSkin?
    @State private var dropTargeted = false
    @State private var importingBatch = false
    private var canImport: Bool { !importingBatch && !library.importing && !library.loadFailed }
    private var config: SkinConfiguration { library.configuration }
    private func binding<T>(_ key: WritableKeyPath<SkinConfiguration, T>) -> Binding<T> {
        Binding(get: { config[keyPath: key] }, set: { value in library.update { $0[keyPath: key] = value } })
    }
    var body: some View {
        Form {
            Section("Background") {
                Toggle("Use custom skin", isOn: binding(\.enabled)).disabled(config.skins.isEmpty)
                Text("Your photos and videos, softened behind the editor. Luna keeps its own copy of every skin.")
                    .font(.caption).foregroundStyle(.secondary)
                if let skin = config.selected {
                    ZStack(alignment: .bottomLeading) {
                        SkinBackground(library: library, preview: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("# Your next idea").foregroundStyle(Color(nsColor: Theme.mint))
                            Text("Your words, with a view.")
                        }.font(.system(.callout, design: .monospaced)).padding(20)
                    }
                    .frame(height: 150).background(Color(nsColor: Theme.background))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Skin preview: \(skin.name)")
                }
                if config.skins.isEmpty {
                    emptyDropArea
                } else {
                    Button("Add Photo or Video…", action: importFiles)
                        .disabled(!canImport)
                }
                if importingBatch || library.importing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Copying and preparing…").font(.caption)
                    }
                }
                if let error = library.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Show Skin Library in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.root]) }
                }
            }
            if !config.skins.isEmpty {
                Section("Your skins") {
                    ForEach(config.skins) { skin in
                        HStack(spacing: 12) {
                            if let image = NSImage(contentsOf: library.posterURL(for: skin)) {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 42)
                                    .background(Color(nsColor: skin.backgroundColor(light: EditorPreferences.isLight)))
                                    .clipped().cornerRadius(5)
                            }
                            Button { library.select(skin.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(skin.name).lineLimit(1)
                                    Text(skin.kind == .video ? (skin.hasAudio ? "Video · includes audio" : "Video") : "Photo")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("Use \(skin.name)")
                            if skin.id == config.selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).accessibilityLabel("Selected") }
                            Button(role: .destructive) { removing = skin } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove \(skin.name)")
                        }
                    }
                }
                Section("Finish") {
                    if let skin = config.selected {
                        ColorPicker("Background color", selection: Binding(
                            get: { Color(nsColor: skin.backgroundColor(light: EditorPreferences.isLight)) },
                            set: { value in
                                guard let packed = EditorSkin.backgroundRGB(from: NSColor(value)) else { return }
                                library.update { state in
                                    if let index = state.skins.firstIndex(where: { $0.id == skin.id }) {
                                        state.skins[index].backgroundRGB = packed
                                    }
                                }
                            }
                        ), supportsOpacity: false)
                        Button("Use Theme Background") {
                            library.update { state in
                                if let index = state.skins.firstIndex(where: { $0.id == skin.id }) {
                                    state.skins[index].backgroundRGB = nil
                                }
                            }
                        }.disabled(skin.backgroundRGB == nil)
                        Text("Saved for this skin. Shows through transparent PNG and WebP images, beneath the glass and readability tint.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Readability")
                        Slider(value: binding(\.readability), in: 0.25...0.95, step: 0.05)
                            .accessibilityLabel("Readability")
                        Text("\(Int((config.readability * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44)
                    }
                    Text("Increase to soften distractions and give text a calmer backdrop. The tint follows your light or dark theme.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Subtle perspective with pointer movement", isOn: binding(\.perspective))
                    Text("Reduce Motion pauses video and perspective. Reduce Transparency uses a solid background.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let skin = config.selected, skin.kind == .video, skin.hasAudio {
                        Toggle("Play this video's sound", isOn: Binding(get: { !skin.muted }, set: { value in
                            library.update { state in
                                if let index = state.skins.firstIndex(where: { $0.id == skin.id }) { state.skins[index].muted = !value }
                            }
                        }))
                        Text("Sound plays only in the active editor window. New videos start muted.").font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Change skin", selection: binding(\.rotationSeconds)) {
                        Text("Manually").tag(0.0)
                        Text("Every minute").tag(60.0)
                        Text("Every 5 minutes").tag(300.0)
                        Text("Every 15 minutes").tag(900.0)
                        Text("Every 30 minutes").tag(1800.0)
                        Text("Every hour").tag(3600.0)
                        Text("Every day").tag(86400.0)
                    }.onChange(of: config.rotationSeconds) { library.update { $0.rotationAnchor = Date() } }
                    Text("Cycles through your library in order while Luna is running. All editor windows use the same skin.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped).scenePadding().navigationTitle("Skins")
        .alert("Remove skin?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let removing { library.remove(removing) }; removing = nil }
        } message: { Text("Luna's copy will be deleted. Your original file is unaffected.") }

    }
    private var emptyDropArea: some View {
        Button(action: importFiles) {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundStyle(dropTargeted && canImport ? Color(nsColor: Theme.mint) : .secondary)
                .accessibilityHidden(true)
            Text("Make this space yours")
                .font(.title2.weight(.semibold))
            Text("Drop photos or videos here to use behind your notes. Your originals stay untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 340)
            Text("Add Photo or Video…")
                .foregroundStyle(Color(nsColor: Theme.mint))
                .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 224, alignment: .center)
        .background(Color(nsColor: Theme.mint).opacity(dropTargeted && canImport ? 0.10 : 0))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(dropTargeted && canImport ? Color(nsColor: Theme.mint) : Color.secondary.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        }
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canImport)
        .accessibilityLabel("Add photos or videos")
        .accessibilityHint("Choose files, or drop photos and videos here.")
        .dropDestination(for: URL.self) { urls, _ in
            guard canImport, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            addFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func addFiles(_ urls: [URL]) {
        guard canImport else { return }
        importingBatch = true
        Task { @MainActor in
            defer { importingBatch = false }
            var failures: [String] = []
            for url in urls {
                do { try await library.add(url) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { library.errorMessage = failures.joined(separator: "\n") }
        }
    }

    private func importFiles() {
        guard canImport else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "Add to Skins"
        panel.begin { response in
            guard response == .OK else { return }
            addFiles(panel.urls)
        }
    }
}
