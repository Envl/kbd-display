# Publishing a macOS update

The workflow packages the existing `com.kbd-display.app` bundle for Intel and Apple silicon. It uses a Developer ID Application certificate for Gatekeeper, Apple’s notary service for distribution, and a separate Sparkle Ed25519 key for the appcast and archive.

## Configure GitHub Actions

In the public GitHub repository, add the following Actions secrets. The release job needs permission to write Releases. Protect release tags and limit who can run trusted code with these signing credentials.

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12` | Base64-encoded PKCS#12 export containing the Developer ID Application certificate and private key |
| `DEVELOPER_ID_PASSWORD` | Password for that PKCS#12 export |
| `NOTARY_KEY_ID` | App Store Connect team API key ID authorized for notarization |
| `NOTARY_ISSUER` | Issuer ID for that API key |
| `NOTARY_KEY_P8` | Full multiline content of the corresponding Apple private key file |
| `SPARKLE_PRIVATE_KEY` | Base64-encoded 32-byte Ed25519 seed exported by Sparkle |

Use Sparkle’s `generate_keys --account kbd-display` from the pinned [Sparkle 2.10.1 distribution](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1). Export it to a private location outside the checkout with `generate_keys --account kbd-display -x /path/to/private/export`. Set the GitHub secret from that file. Back up the key securely. Future releases must use the same signing key. The workflow derives the public key for the app locally on the runner.

## Cut a release

1. Run `swift test`, `swift test -c release`, and `scripts/build.sh release`. Run `pnpm --dir web check` for the standalone browser game.
2. Tag the tested commit with a strictly increasing `vMAJOR.MINOR.PATCH` version. Publishing that tag to the GitHub repository triggers **Publish macOS update**.
3. The workflow tests, signs and notarizes the universal app, staples the ticket, archives the stapled app, and generates its signed appcast. It uploads both files to a draft before publishing the release as latest. A failed attempt can reuse the same draft. Published releases are immutable to this workflow.
4. For an update check, launch the previous GitHub build from Applications. The orange dot and both restart actions appear once Sparkle finishes preparing the new version. Verify the running version after restart. For the initial release, verify direct installation from its ZIP.

The stable feed is `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml`. Each enclosure links to the archive on its specific version tag. Keep old releases available and keep the repository URL stable for installed clients. Debug and ordinary local builds do not contact the release feed.

## Updating Sparkle

Update the binary framework version and SHA-256 in `Package.swift`, the matching tools archive version and SHA-256 in `scripts/ci-release.sh`, and the bundled [license notices](Licenses/Sparkle.txt) together. Review Sparkle’s [publishing guide](https://sparkle-project.org/documentation/publishing/) before changing signing keys or feed format.
