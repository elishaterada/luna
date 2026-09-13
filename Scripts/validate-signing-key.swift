import Foundation
import CryptoKit
// Read only from stdin: private material must never appear in arguments or logs.
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let encoded = String(data: input, encoding: .utf8),
      let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32 else { fatalError("Expected Sparkle's 32-byte Ed25519 seed format") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil) as! [String: Any]
guard plist["SUPublicEDKey"] as? String == key.publicKey.rawRepresentation.base64EncodedString() else {
    fatalError("Signing key does not match the app's embedded public key")
}
print("Signing key matches the embedded public key")
