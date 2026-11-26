#!/bin/bash
# Run on a disposable GitHub-hosted macOS runner.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_REF_NAME:?}"
: "${DEVELOPER_ID_P12:?}" "${DEVELOPER_ID_PASSWORD:?}" "${NOTARY_KEY_P8:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER:?}" "${SPARKLE_PRIVATE_KEY:?}"
[[ "$GITHUB_REF_NAME" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "Expected a vMAJOR.MINOR.PATCH tag" >&2; exit 1; }
export KBD_VERSION=${GITHUB_REF_NAME#v}
export KBD_UNIVERSAL=1 KBD_DISTRIBUTION=1
export KBD_UPDATE_FEED="https://github.com/$GITHUB_REPOSITORY/releases/latest/download/appcast.xml"
umask 077
credentials=$(mktemp -d "$RUNNER_TEMP/kbd-signing.XXXXXX")
keychain="$credentials/signing.keychain-db"
trap 'security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$credentials"' EXIT
password=$(openssl rand -hex 32)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security list-keychains -d user -s "$keychain" "$HOME/Library/Keychains/login.keychain-db"
printf '%s' "$DEVELOPER_ID_P12" | base64 -D > "$credentials/distribution.p12"
security import "$credentials/distribution.p12" -k "$keychain" -P "$DEVELOPER_ID_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
KBD_DISPLAY_SIGN_IDENTITY=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2; exit}')
export KBD_DISPLAY_SIGN_IDENTITY
: "${KBD_DISPLAY_SIGN_IDENTITY:?No Developer ID Application identity in certificate}"
printf '%s\n' "$NOTARY_KEY_P8" > "$credentials/notary.p8"

# generate_keys exports modern Sparkle keys as a base64-encoded 32-byte seed.
KBD_UPDATE_PUBLIC_KEY=$(swift -e 'import CryptoKit; import Foundation
guard let seed = Data(base64Encoded: ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY"] ?? ""), seed.count == 32 else { exit(1) }
print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())')
export KBD_UPDATE_PUBLIC_KEY
umask 022
scripts/build.sh release
bundle="dist/kbd-display.app"
lipo -verify_arch arm64 x86_64 "$bundle/Contents/MacOS/kbd-display"
ditto -c -k --sequesterRsrc --keepParent "$bundle" "$credentials/notarize.zip"
xcrun notarytool submit "$credentials/notarize.zip" --key "$credentials/notary.p8" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait --output-format plist > "$credentials/notary.plist"
[[ "$(plutil -extract status raw "$credentials/notary.plist")" == Accepted ]] || {
    plutil -p "$credentials/notary.plist" >&2
    exit 1
}
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
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools_dir/bin/generate_appcast" --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$GITHUB_REF_NAME/" "$artifacts"
test -s "$artifacts/appcast.xml"
