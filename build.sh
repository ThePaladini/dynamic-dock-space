#!/bin/zsh
# Builds build/DynamicDockSpace.app (universal: arm64 + x86_64).
#   ./build.sh            build
#   ./build.sh --install  build, then copy to ~/Applications (quits a running copy)
#   ./build.sh --zip      build, then create build/DynamicDockSpace.zip for distribution
# Needs only the Command Line Tools (xcode-select --install); Xcode is not required.
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
SRCS=(Sources/DynamicDockSpace/*.swift)
APP=build/DynamicDockSpace.app
BIN="$APP/Contents/MacOS/DynamicDockSpace"
FW=(-framework AppKit -framework ApplicationServices -framework ServiceManagement -framework CoreGraphics)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() { # $1 = arch
  local target=$1-apple-macos13.0 out=build/DynamicDockSpace-$1
  if swiftc -O -target $target -sdk "$SDK" "${SRCS[@]}" "${FW[@]}" -o $out 2>/dev/null; then return; fi
  # Fallback for Command Line Tools installs whose swift driver is broken: call the frontend directly.
  local CLT=$(xcode-select -p)
  DYLD_LIBRARY_PATH=$CLT/Library/PrivateFrameworks/LLDB.framework/Versions/A/Libraries/usr/lib/swift/host \
    $CLT/usr/bin/swift-frontend -frontend -c "${SRCS[@]}" -sdk "$SDK" -target $target \
    -module-name DynamicDockSpace -swift-version 5 -O -o $out.o
  clang -target $target -isysroot "$SDK" $out.o -L"$SDK/usr/lib/swift" -Wl,-rpath,/usr/lib/swift "${FW[@]}" -o $out
}
compile arm64
compile x86_64
lipo -create build/DynamicDockSpace-arm64 build/DynamicDockSpace-x86_64 -output "$BIN"

# Icon: docs/icon.png (rendered by Tools/make-icon.swift) -> AppIcon.icns
ICONSET=build/AppIcon.iconset; rm -rf $ICONSET; mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s docs/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) docs/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - --identifier io.github.thepaladini.DynamicDockSpace "$APP"
echo "OK: $APP ($(lipo -archs "$BIN"))"

if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x DynamicDockSpace 2>/dev/null || true
  rm -rf ~/Applications/DynamicDockSpace.app
  cp -R "$APP" ~/Applications/
  echo "installed: ~/Applications/DynamicDockSpace.app"
elif [[ "$1" == "--zip" ]]; then
  rm -f build/DynamicDockSpace.zip
  ditto -c -k --keepParent "$APP" build/DynamicDockSpace.zip
  echo "zip: build/DynamicDockSpace.zip"
fi
