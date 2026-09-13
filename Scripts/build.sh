#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
APP="$PWD/dist/Luna.app"
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Luna "$APP/Contents/MacOS/Luna"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${MARKETING_VERSION:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP/Contents/Info.plist"; fi
if [[ -n "${CURRENT_PROJECT_VERSION:-}" ]]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CURRENT_PROJECT_VERSION" "$APP/Contents/Info.plist"; fi
if [[ "${LUNA_DEVELOPMENT_BUILD:-0}" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Add :LunaDevelopmentBuild bool true" "$APP/Contents/Info.plist"
fi
if [[ -f Resources/Luna.icns ]]; then cp Resources/Luna.icns "$APP/Contents/Resources/Luna.icns"; fi
ditto "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Sign nested code inside-out, retaining Sparkle's required helper entitlements.
for component in "$FRAMEWORK"/Versions/B/XPCServices/*.xpc "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK/Versions/B/Autoupdate"; do
  codesign --force --sign - --preserve-metadata=entitlements "$component"
done
codesign --force --sign - "$FRAMEWORK"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
