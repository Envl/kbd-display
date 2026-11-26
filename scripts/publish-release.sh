#!/bin/bash
set -euo pipefail
: "${GITHUB_REF_NAME:?}" "${GITHUB_REPOSITORY:?}" "${RUNNER_TEMP:?}"
tag="$GITHUB_REF_NAME"
artifacts="$RUNNER_TEMP/update-release"
zip="$artifacts/kbd-display-${tag#v}.zip"
test -s "$zip" && test -s "$artifacts/appcast.xml" || exit 1

# Refuse to move the stable feed backwards or overwrite a published release.
releases=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" --slurp)
python3 -c '
import json, re, sys
tag = sys.argv[1]
def version(s):
    if re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", s):
        return tuple(map(int, s[1:].split(".")))
new = version(tag)
if not new:
    sys.exit("Invalid release tag")
for page in json.load(sys.stdin):
    for release in page:
        old = version(release["tag_name"])
        if old and old >= new and not release["draft"] and not release["prerelease"]:
            sys.exit("A matching or newer stable release already exists")
' "$tag" <<< "$releases"

if ! gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    gh release create "$tag" --repo "$GITHUB_REPOSITORY" --verify-tag --draft --generate-notes --title "$tag"
fi
[[ "$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)" == true ]]
gh release upload "$tag" "$zip" "$artifacts/appcast.xml" --repo "$GITHUB_REPOSITORY" --clobber
gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --latest
