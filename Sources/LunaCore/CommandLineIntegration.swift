import Foundation

/// Owns only a marked launcher and a marked PATH block; unrelated shell setup
/// and commands are never replaced. Injectable paths keep tests out of the user's home.
public struct CommandLineIntegration {
    public let binDirectory: URL
    public let profile: URL
    public let appURL: URL
    public var launcher: URL { binDirectory.appendingPathComponent("luna") }
    public static let marker = "# Luna command-line launcher v1"
    public static let blockStart = "# >>> Luna command-line PATH >>>"
    public static let blockEnd = "# <<< Luna command-line PATH <<<"

    public init(home: URL, appURL: URL, zshDirectory: URL? = nil) {
        binDirectory = home.appendingPathComponent(".local/bin")
        profile = (zshDirectory ?? home).appendingPathComponent(".zshrc")
        self.appURL = appURL
    }
    public var isInstalled: Bool { (try? String(contentsOf: launcher, encoding: .utf8).contains(Self.marker)) == true }
    public var managesPATH: Bool { (try? String(contentsOf: profile, encoding: .utf8).contains(Self.blockStart)) == true }
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public var script: String {
        """
        #!/bin/zsh
        \(Self.marker)
        set -euo pipefail
        app_location=\(Self.quote(appURL.path))
        if [[ -d "$app_location" ]]; then
          app_selector=(-a "$app_location")
        else
          app_selector=(-b dev.luna.app)
        fi
        if (( $# == 0 )); then
          /usr/bin/open "${app_selector[@]}"
        else
          file_arguments=()
          for file_argument in "$@"; do
            file_arguments+=("${file_argument:a}")
          done
          /usr/bin/open "${app_selector[@]}" -- "${file_arguments[@]}"
        fi

        """
    }
    public var pathBlock: String {
        """
        \(Self.blockStart)
        case ":$PATH:" in
          *:\(Self.quote(binDirectory.path)):*) ;;
          *) export PATH=\(Self.quote(binDirectory.path)):"$PATH" ;;
        esac
        \(Self.blockEnd)
        """
    }
    private func removingBlock(from text: String) throws -> String {
        guard let start = text.range(of: Self.blockStart) else {
            if text.contains(Self.blockEnd) { throw failure("Luna’s PATH block is incomplete. Repair the marked block in \(profile.path) before continuing.") }
            return text
        }
        guard let end = text.range(of: Self.blockEnd, range: start.upperBound..<text.endIndex),
              !text[end.upperBound...].contains(Self.blockStart) else {
            throw failure("Luna’s PATH block is incomplete or duplicated. Check \(profile.path) before continuing.")
        }
        var result = text
        var upper = end.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        result.removeSubrange(start.lowerBound..<upper)
        return result
    }
    public func enable(addToZshPATH: Bool) throws {
        let manager = FileManager.default
        // Don't follow a command symlink and overwrite its target.
        if (try? manager.destinationOfSymbolicLink(atPath: launcher.path)) != nil {
            throw failure("A symbolic link already exists at \(launcher.path). Move it before enabling Luna’s command.")
        }
        let previous = manager.fileExists(atPath: launcher.path) ? try Data(contentsOf: launcher) : nil
        if previous != nil && !isInstalled { throw failure("A different command already exists at \(launcher.path). Luna will not replace it.") }
        let profileURL = profile.resolvingSymlinksInPath()
        let original = manager.fileExists(atPath: profileURL.path) ? try String(contentsOf: profileURL, encoding: .utf8) : ""
        var updated = try removingBlock(from: original)
        if addToZshPATH {
            if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
            updated += pathBlock + "\n"
        }
        try manager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try write(Data(script.utf8), to: launcher, defaultPermissions: 0o755)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        do {
            if updated != original { try write(Data(updated.utf8), to: profileURL, defaultPermissions: 0o600) }
        } catch {
            if let previous { try? write(previous, to: launcher, defaultPermissions: 0o755) }
            else { try? manager.removeItem(at: launcher) }
            throw error
        }
    }
    public func disable() throws {
        let profileURL = profile.resolvingSymlinksInPath()
        let original = FileManager.default.fileExists(atPath: profileURL.path) ? try String(contentsOf: profileURL, encoding: .utf8) : ""
        let updated = try removingBlock(from: original)
        if updated != original { try write(Data(updated.utf8), to: profileURL, defaultPermissions: 0o600) }
        do {
            if isInstalled { try FileManager.default.removeItem(at: launcher) }
        } catch {
            if updated != original { try? write(Data(original.utf8), to: profileURL, defaultPermissions: 0o600) }
            throw error
        }
    }
    private func write(_ data: Data, to url: URL, defaultPermissions: Int) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? defaultPermissions
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "Luna.CommandLine", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
