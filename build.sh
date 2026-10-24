#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=ScreenOff.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
for ARCH in arm64 x86_64; do
  swiftc -target arm64-apple-macosx13.0 -parse-as-library -O -target $ARCH-apple-macos13.0 ScreenOffApp.swift -o .build-$ARCH
done
lipo -create .build-arm64 .build-x86_64 -output $APP/Contents/MacOS/ScreenOff
rm -f .build-arm64 .build-x86_64
cp $APP/Contents/MacOS/ScreenOff $APP/Contents/MacOS/so-watchdog
cp AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScreenOff</string>
<key>CFBundleIdentifier</key><string>local.screenoff</string>
<key>CFBundleName</key><string>ScreenOff</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PL
codesign --force --deep --sign - $APP
echo "Built $APP"
