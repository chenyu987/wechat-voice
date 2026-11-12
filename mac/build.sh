#!/bin/bash
# 编译并安装「微信语音播报」到 /Applications（或 ~/Applications）
set -e
cd "$(dirname "$0")"
APP="build/微信语音播报.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "▶ 编译中…"
swiftc -O -o "$APP/Contents/MacOS/WeChatVoice" main.swift -framework Cocoa -framework ServiceManagement -lsqlite3
cp Info.plist "$APP/Contents/Info.plist"
if [ -f icon.png ]; then
  IS=build/AppIcon.iconset; mkdir -p $IS
  for z in 16 32 128 256 512; do
    sips -z $z $z icon.png --out $IS/icon_${z}x${z}.png >/dev/null
    sips -z $((z*2)) $((z*2)) icon.png --out $IS/icon_${z}x${z}@2x.png >/dev/null
  done
  iconutil -c icns $IS -o "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep -s - --identifier com.lyc.wechatvoice "$APP"
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -f "微信语音播报.app/Contents/MacOS/WeChatVoice" 2>/dev/null || true
rm -rf "$DEST/微信语音播报.app"
cp -R "$APP" "$DEST/"
echo "✅ 已安装到 $DEST/微信语音播报.app"
[ "$1" = "--no-open" ] || open "$DEST/微信语音播报.app"
