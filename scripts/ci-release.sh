#!/bin/bash
# Run on a disposable GitHub-hosted macOS runner.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?}" "${GITHUB_REPOSITORY:?}" "${RELEASE_TAG:?}"
: "${MACOS_CERTIFICATE_P12_BASE64:?}" "${MACOS_CERTIFICATE_PASSWORD:?}" "${MACOS_KEYCHAIN_PASSWORD:?}" "${SPARKLE_ED_PRIVATE_KEY:?}"
[[ "$RELEASE_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "Expected a vMAJOR.MINOR.PATCH tag" >&2; exit 1; }
export KBD_VERSION=${RELEASE_TAG#v}
export KBD_UNIVERSAL=1 KBD_DISTRIBUTION=1
export KBD_UPDATE_FEED="https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml"
umask 077
credentials=$(mktemp -d "$RUNNER_TEMP/kbd-signing.XXXXXX")
keychain="$credentials/signing.keychain-db"
trap 'security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$credentials"' EXIT
password=$MACOS_KEYCHAIN_PASSWORD
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 -D > "$credentials/distribution.p12"
security import "$credentials/distribution.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
KBD_DISPLAY_SIGN_IDENTITY=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2; exit}')
export KBD_DISPLAY_SIGN_IDENTITY
: "${KBD_DISPLAY_SIGN_IDENTITY:?No Developer ID Application identity in certificate}"

# generate_keys exports modern Sparkle keys as a base64-encoded 32-byte seed.
KBD_UPDATE_PUBLIC_KEY=$(swift -e 'import CryptoKit; import Foundation
guard let seed = Data(base64Encoded: ProcessInfo.processInfo.environment["SPARKLE_ED_PRIVATE_KEY"] ?? ""), seed.count == 32 else { exit(1) }
print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())')
export KBD_UPDATE_PUBLIC_KEY
umask 022
scripts/build.sh release
bundle="dist/kbd-display.app"
architectures=$(lipo -archs "$bundle/Contents/MacOS/kbd-display")
for arch in arm64 x86_64; do
    [[ " $architectures " == *" $arch "* ]] || { echo "Missing $arch executable slice" >&2; exit 1; }
done
if [[ "${SIGNING_ONLY:-false}" == true ]]; then
    [[ "${GITHUB_EVENT_NAME:?}" == workflow_dispatch ]]
    echo "Verified the signed universal app."
    exit 0
fi
: "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}"
xcrun notarytool store-credentials kbd-display-notary --keychain "$keychain" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$credentials/notarize.zip"
notarize() {
    xcrun notarytool submit "$1" --keychain-profile kbd-display-notary --keychain "$keychain" \
        --wait --output-format plist > "$credentials/notary.plist"
    if [[ "$(plutil -extract status raw "$credentials/notary.plist")" != Accepted ]]; then
        plutil -p "$credentials/notary.plist" >&2
        return 1
    fi
}
notarize "$credentials/notarize.zip"
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"
codesign --verify --deep --strict "$bundle"
spctl --assess --type execute "$bundle"

artifacts="$RUNNER_TEMP/update-release"
mkdir "$artifacts"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$artifacts/kbd-display-$KBD_VERSION.zip"
tools_dir="$credentials/sparkle"
mkdir "$tools_dir"
curl --fail --silent --show-error --location --retry 3 \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz -o "$tools_dir/tools.tar.xz"
(cd "$tools_dir" && echo '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  tools.tar.xz' | shasum -a 256 -c - && tar -xf tools.tar.xz)
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools_dir/bin/generate_appcast" --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/" "$artifacts"
test -s "$artifacts/appcast.xml"

# Keep the installer outside Sparkle's input directory until the ZIP feed exists.
staging="$credentials/dmg"
mkdir "$staging"
ditto "$bundle" "$staging/kbd-display.app"
ln -s /Applications "$staging/Applications"
dmg="$artifacts/kbd-display.dmg"
hdiutil create -volname "kbd-display" -srcfolder "$staging" -format UDZO "$dmg"
codesign --force --timestamp --sign "$KBD_DISPLAY_SIGN_IDENTITY" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
hdiutil verify "$dmg"
codesign --verify --strict "$dmg"
