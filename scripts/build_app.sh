#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
destination="${1:-$project_dir/dist}"
configuration="release"
app_name="TypingPet"
app_dir="$destination/$app_name.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

cd "$project_dir"
swift build -c "$configuration"

binary_path="$(swift build -c "$configuration" --show-bin-path)/$app_name"
rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"
cp "$binary_path" "$macos_dir/$app_name"
cp Sources/TypingPet/Resources/*.png "$resources_dir/"
cp Sources/TypingPet/Resources/*.icns "$resources_dir/"

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleDisplayName</key>
    <string>Typing Pet</string>
    <key>CFBundleExecutable</key>
    <string>TypingPet</string>
    <key>CFBundleIdentifier</key>
    <string>ing.miel.typingpet</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TypingPet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.9.1</string>
    <key>CFBundleVersion</key>
    <string>13</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Personal macOS build</string>
</dict>
</plist>
PLIST

signing_identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
fi

if [[ "$signing_identity" == "Developer ID Application:"* ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$app_dir"
    echo "Signed for distribution with $signing_identity"
else
    codesign --force --deep --options runtime --timestamp=none --sign "$signing_identity" "$app_dir"
    echo "Warning: this build is not signed with Developer ID and cannot be notarized."
fi
echo "$app_dir"
