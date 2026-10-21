#!/bin/sh
# Builds a release binary and wraps it in build/MetalCap.app (ad-hoc signed).
# VERSION and BUILD_NUMBER set the bundle's version (defaults: 1.0.0 and 1).
set -e
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release

APP=build/MetalCap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Empty localization folders make AppKit show its own menus and panels in these languages.
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/pl.lproj"
cp .build/release/MetalCap "$APP/Contents/MacOS/MetalCap"
Scripts/stamp-sdk.sh "$APP/Contents/MacOS/MetalCap"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>MetalCap</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.metalcap.MetalCap</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>pl</string>
	</array>
	<key>CFBundleName</key>
	<string>MetalCap</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP ($VERSION)"
