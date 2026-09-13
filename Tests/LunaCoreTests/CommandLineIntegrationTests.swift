import XCTest
@testable import LunaCore

final class CommandLineIntegrationTests: XCTestCase {
    var home: URL!
    var integration: CommandLineIntegration!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("Luna test ' " + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        home = home.resolvingSymlinksInPath()
        integration = CommandLineIntegration(home: home, appURL: home.appendingPathComponent("Luna's app.app"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func testEnableIsIdempotentAndDisablePreservesOtherConfiguration() throws {
        let original = "export EDITOR=vim\n# My existing settings\n"
        try original.write(to: integration.profile, atomically: true, encoding: .utf8)
        try integration.enable(addToZshPATH: true)
        try integration.enable(addToZshPATH: true)
        XCTAssertTrue(integration.isInstalled); XCTAssertTrue(integration.managesPATH)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: integration.launcher.path))
        let profile = try String(contentsOf: integration.profile, encoding: .utf8)
        XCTAssertEqual(profile.components(separatedBy: CommandLineIntegration.blockStart).count, 2)
        let result = try runZsh("source \(CommandLineIntegration.quote(integration.profile.path)); source \(CommandLineIntegration.quote(integration.profile.path)); command -v luna")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), integration.launcher.path)
        try integration.disable()
        XCTAssertFalse(integration.isInstalled); XCTAssertFalse(integration.managesPATH)
        XCTAssertEqual(try String(contentsOf: integration.profile, encoding: .utf8), original)
    }
    func testPATHIsOptionalAndCanBeRemovedWhileCommandRemains() throws {
        try integration.enable(addToZshPATH: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: integration.profile.path))
        try integration.enable(addToZshPATH: true)
        try integration.enable(addToZshPATH: false)
        XCTAssertTrue(integration.isInstalled); XCTAssertFalse(integration.managesPATH)
    }
    func testExistingCommandIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: integration.binDirectory, withIntermediateDirectories: true)
        try "my command".write(to: integration.launcher, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try integration.enable(addToZshPATH: true))
        XCTAssertEqual(try String(contentsOf: integration.launcher, encoding: .utf8), "my command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: integration.profile.path))
    }
    func testMalformedBlockDoesNotInstallCommand() throws {
        try CommandLineIntegration.blockStart.write(to: integration.profile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try integration.enable(addToZshPATH: true))
        XCTAssertFalse(integration.isInstalled)
    }
    func testSymlinkedProfileRemainsSymlink() throws {
        let target = home.appendingPathComponent("dotfiles-zshrc")
        try "# dotfiles\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: integration.profile, withDestinationURL: target)
        try integration.enable(addToZshPATH: true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: integration.profile.path), target.path)
        try integration.disable()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# dotfiles\n")
    }
    func testLauncherForwardsQuotedRelativePathsAndNoArguments() throws {
        try FileManager.default.createDirectory(at: integration.appURL, withIntermediateDirectories: true)
        // Substitute only the external launch boundary; execute the actual generated zsh script.
        let stub = home.appendingPathComponent("capture-open")
        try "#!/bin/zsh\nprintf '%s\\0' \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let script = home.appendingPathComponent("launcher")
        try integration.script.replacingOccurrences(of: "/usr/bin/open", with: CommandLineIntegration.quote(stub.path)).write(to: script, atomically: true, encoding: .utf8)
        let result = try runZsh("source \(CommandLineIntegration.quote(script.path)) 'a file.txt' '-config' 'literal$(echo nope).md'")
        let physicalDirectory = try runZsh("pwd -P").trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = result.split(separator: "\0").map(String.init)
        XCTAssertEqual(arguments, ["-a", integration.appURL.path, "--", physicalDirectory + "/a file.txt", physicalDirectory + "/-config", physicalDirectory + "/literal$(echo nope).md"])
        XCTAssertEqual(try runZsh("source \(CommandLineIntegration.quote(script.path))").split(separator: "\0").map(String.init), ["-a", integration.appURL.path])
    }
    private func runZsh(_ command: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]; process.currentDirectoryURL = home
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, result)
        return result
    }
}
