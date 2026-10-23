#!/bin/zsh
# Unplug.app'i build/ altına derler. Kullanım: ./build.sh [sürüm]
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
APP=build/Unplug.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R Resources/*.lproj Resources/AppIcon.icns "$APP/Contents/Resources/"

# Hem Apple Silicon hem Intel Mac'lerde çalışsın diye universal binary.
for arch in arm64 x86_64; do
    swiftc -O -target $arch-apple-macos13 -o "build/Unplug-$arch" Sources/main.swift
done
lipo -create build/Unplug-arm64 build/Unplug-x86_64 -output "$APP/Contents/MacOS/Unplug"
rm build/Unplug-arm64 build/Unplug-x86_64

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Unplug</string>
    <key>CFBundleDisplayName</key><string>Unplug</string>
    <key>CFBundleIdentifier</key><string>com.iltekin.Unplug</string>
    <key>CFBundleExecutable</key><string>Unplug</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
    <key>NSHumanReadableCopyright</key><string>© 2026 Sezer Iltekin. MIT License.</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# SIGN_IDENTITY verilmezse yerel kullanım için ad-hoc imzalanır. Developer ID ile imzalarken
# notarization için hardened runtime ve zaman damgası gerekir.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP ($VERSION)"
