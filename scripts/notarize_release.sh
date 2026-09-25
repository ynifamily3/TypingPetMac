#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_path="${1:-$project_dir/dist/TypingPet.app}"
output_zip="${2:-$project_dir/dist/TypingPet-macOS-arm64.zip}"
keychain_profile="${NOTARY_KEYCHAIN_PROFILE:-typingpet-notary}"

identity="$(codesign -dv --verbose=4 "$app_path" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)"
if [[ -z "$identity" ]]; then
    echo "Error: app must be signed with a Developer ID Application certificate." >&2
    exit 1
fi

work_dir="$(mktemp -d)"
submission_zip="$work_dir/TypingPet-notary.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$submission_zip"
xcrun notarytool submit "$submission_zip" --keychain-profile "$keychain_profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$output_zip"
shasum -a 256 "$output_zip"
