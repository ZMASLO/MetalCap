#!/bin/sh
# Builds a release binary and wraps it in build/MetalCap.app (ad-hoc signed).
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP=build/MetalCap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MetalCap "$APP/Contents/MacOS/MetalCap"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>MetalCap</string>
	<key>CFBundleIdentifier</key>
	<string>com.metalcap.MetalCap</string>
	<key>CFBundleName</key>
	<string>MetalCap</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
