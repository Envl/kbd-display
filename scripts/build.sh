#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-release}
case "$config" in
  release) name="kbd-display"; id="com.kbd-display.app" ;;
  debug) name="kbd-display Debug"; id="com.kbd-display.app.debug" ;;
  *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;;
esac
version=${KBD_VERSION:-0.1.0}
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "KBD_VERSION must have the form 1.2.3" >&2
  exit 2
fi
args=(--configuration "$config")
if [[ "${KBD_UNIVERSAL:-0}" == 1 ]]; then
  args+=(--arch arm64 --arch x86_64)
fi
swift build "${args[@]}"
output=$(swift build "${args[@]}" --show-bin-path)
bundle="${KBD_DIST_DIR:-$PWD/dist}/$name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Frameworks"
install -m 755 "$output/kbd-display" "$bundle/Contents/MacOS/kbd-display"
ditto "$output/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
cp assets/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
rm -rf "$bundle/Contents/Resources/kbd-display_NinjaGame.bundle"
cp LICENSE "$bundle/Contents/Resources/LICENSE"
cp Licenses/Glimm.txt "$bundle/Contents/Resources/Glimm-LICENSE.txt"
cp Licenses/Sparkle.txt "$bundle/Contents/Resources/Sparkle-LICENSE.txt"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>kbd-display</string>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSInputMonitoringUsageDescription</key><string>Flash the matching key on the keyboard display when you type.</string>
<key>NSAudioCaptureUsageDescription</key><string>Analyze playing system audio with FFT to animate music ambient keyboard visuals.</string>
<key>NSMicrophoneUsageDescription</key><string>Analyze microphone audio with FFT to animate music ambient keyboard visuals.</string>
</dict></plist>
PLIST
if [[ -n "${KBD_UPDATE_FEED:-}${KBD_UPDATE_PUBLIC_KEY:-}" ]]; then
  [[ "$config" == release && "${KBD_UPDATE_FEED:-}" == https://* && -n "${KBD_UPDATE_PUBLIC_KEY:-}" ]] || {
    echo "Updates require a Release build, HTTPS feed, and public Ed25519 key." >&2
    exit 2
  }
  plist="$bundle/Contents/Info.plist"
  plutil -insert SUFeedURL -string "$KBD_UPDATE_FEED" "$plist"
  plutil -insert SUPublicEDKey -string "$KBD_UPDATE_PUBLIC_KEY" "$plist"
  for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
    plutil -insert "$key" -bool YES "$plist"
  done
fi

sign_identity="${KBD_DISPLAY_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null | grep -v "CSSMERR_" || true)
  sign_identity=$(printf '%s\n' "$identities" | grep -E '"Developer ID Application:' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
  if [[ -z "$sign_identity" ]]; then
    sign_identity=$(printf '%s\n' "$identities" | grep -E '"Apple Development:' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
  fi
fi
if [[ "${KBD_DISTRIBUTION:-0}" == 1 ]]; then
  : "${KBD_DISPLAY_SIGN_IDENTITY:?A Developer ID Application signing identity is required}"
  sign=(codesign --force --timestamp --options runtime --sign "$KBD_DISPLAY_SIGN_IDENTITY")
  framework="$bundle/Contents/Frameworks/Sparkle.framework"
  components="$framework/Versions/Current"
  for component in "$components"/XPCServices/*.xpc "$components/Autoupdate" "$components/Updater.app" "$framework"; do
    "${sign[@]}" --preserve-metadata=identifier,entitlements "$component"
  done
  "${sign[@]}" "$bundle"
else
  codesign --force --sign "${sign_identity:--}" "$bundle"
fi
codesign --verify --deep --strict "$bundle"
touch "$bundle"
echo "$bundle"
