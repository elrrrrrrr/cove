#!/bin/bash
# Public unsigned device build. Never bundle local private seed folders.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?Usage: build-ipa.sh VERSION BUILD_NUMBER [OUTPUT_DIRECTORY]}"
number="${2:?Build number required}"
output="${3:-$root/build/release}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z' >&2; exit 1; }
[[ "$number" =~ ^[1-9][0-9]*$ ]] || { echo 'Build number must be a positive integer' >&2; exit 1; }
for directory in sites data config; do
    if [[ -d "$root/$directory" ]] && [[ -n "$(find "$root/$directory" -type f -print -quit)" ]]; then
        echo "Public release requires a clean checkout without $directory/ content." >&2
        exit 1
    fi
done
mkdir -p "$output"
output="$(cd "$output" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cove-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$root/Cove"
xcodegen generate
xcodebuild -project Cove.xcodeproj -scheme Cove -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$work/Cove.xcarchive" \
    -derivedDataPath "${COVE_DERIVED_DATA:-$root/build/ReleaseDerivedData}" \
    archive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$number"
xcrun lipo -verify_arch arm64 "$work/Cove.xcarchive/Products/Applications/Cove.app/Cove"
python3 "$root/scripts/package-ipa.py" "$work/Cove.xcarchive" "$output"
