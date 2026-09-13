# Releasing Luna

Luna follows Sora's GitHub Releases + Sparkle distribution model: Apple Silicon ZIPs, ad-hoc app signatures, Ed25519-signed archives and appcasts, and the same readable changelog on GitHub and in the native update window. These builds are not Apple-notarized.

## One-time configuration

- Public repository: https://github.com/elishaterada/luna
- Stable feed: https://github.com/elishaterada/luna/releases/latest/download/appcast.xml
- Sparkle version: 2.9.6, pinned in `Package.swift` and `Package.resolved`.
- Luna has its own Ed25519 key. Its public key is committed in `Resources/Info.plist`.
- The private key is in the local login Keychain under account `dev.luna.app`, and in the repository's Actions secret `SPARKLE_ED_PRIVATE_KEY`. It must never be committed or printed. GitHub does not allow reading secrets back.
- Keep a secure backup of the key through Sparkle's `generate_keys --account dev.luna.app -x <secure-file>` command. Keychain access may require macOS approval. Do not replace this key: existing clients trust its public counterpart.

The workflow verifies that its secret derives the public key embedded in the packaged app. It signs and then verifies both final artifacts before publishing. `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are enabled; future edits to a signed appcast require regeneration and re-signing.

## Every release

1. Choose a new stable `X.Y.Z` version. Update `CFBundleShortVersionString` in `Resources/Info.plist` and add an exact `## X.Y.Z — YYYY-MM-DD` entry at the top of `CHANGELOG.md`.
2. Write short user-facing benefits and fixes. The release deliberately fails if this entry is missing or empty.
3. Run `swift test`, `python3 -m unittest discover -s Tests/ReleaseTests -v`, and `Scripts/build.sh`. Exercise the changed app flow.
4. Review and commit the version, changelog, code, and documentation. Push `main`.
5. Tag that commit and push it:

   ```sh
   git tag -a vX.Y.Z -m 'Luna X.Y.Z'
   git push origin vX.Y.Z
   ```

6. Wait for **Release Luna** to finish. Do not call the release complete while the job is queued or still running.
7. Verify the public latest-release URL, its highlights, ZIP and `appcast.xml`. The workflow reads release metadata with GitHub authentication, downloads the feed and ZIP without authentication, and compares them byte-for-byte with the artifacts verified before upload.
8. Test **Luna → Check for Updates…** in an older Sparkle-enabled copy: review the highlights, install, relaunch, and confirm notes recover and the new version is running.

The workflow builds on `macos-26`, requires Apple Silicon and a version tag on `main`, assigns a UTC timestamp as monotonically increasing `CFBundleVersion`, and publishes through a draft after all files are signed. It refuses to overwrite existing releases. If an upload fails leaving a draft, inspect and remove the incomplete draft before retrying; never replace artifacts of a published release. `workflow_dispatch` accepts an existing version tag for recovery, not arbitrary shell input.

## In-app updates

Automatic checks are enabled by default, with a background check shortly after launch and Sparkle's scheduled checks while running. They can be disabled using **Luna → Automatically Check for Updates**. **Check for Updates…** remains available manually. Installation is user-controlled by default; Sparkle lets clients opt into automatically downloading/installing future updates.

Updater initialization is deferred until after the first window. Debug runs and isolated benchmark/recovery sessions do not initialize Sparkle. Recovery is checkpointed before proceeding with an update, immediately before installation, and before relaunch. Normal app termination also refuses to quit if the final recovery flush fails.

Development copies made before Sparkle was added need one manual installation of a Sparkle-enabled release. After that, the stable URL and public key allow in-app updates. Install the app somewhere permanent before enabling the `luna` command; the launcher falls back to its bundle identifier if the recorded location moves.

## Signing versus notarization

Ed25519 authenticates update archives and feed contents. It does not replace Apple's Developer ID signing and notarization or remove Gatekeeper's first-open checks. Matching Sora, this pipeline currently uses ad-hoc signing. Moving to notarized public distribution is a separate change requiring Apple signing credentials. The release page and bundled `INSTALL.txt` explain the current first-open flow.

Sparkle's license is embedded in the app and ZIP. Its framework, symlinks, updater app, and helper services are copied and signed inside-out before the outer app is signed.

## Primary references

- [Sparkle setup and signed-feed requirements](https://sparkle-project.org/documentation/)
- [Automatic checks and installation settings](https://sparkle-project.org/documentation/customization/)
- [Appcast publishing](https://sparkle-project.org/documentation/publishing/)
- [Updater delegate and lifecycle hooks](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
