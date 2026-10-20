#!/bin/zsh
# Compila WallSakura.app y la instala en /Applications. Los datos de la app viven en ~/Library/Application Support/WallSakura.
# El icono es WallSakura.icon (Icon Composer); hace falta Xcode para compilarlo.
set -e
cd "$(dirname "$0")"
APP=/Applications/WallSakura.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TMP=$(mktemp -d)
xcrun actool WallSakura.icon --compile "$APP/Contents/Resources" --platform macosx \
	--minimum-deployment-target 14.0 --app-icon WallSakura \
	--output-partial-info-plist "$TMP/icono.plist" >/dev/null
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.raul.wallsakura</string>
	<key>CFBundleName</key><string>WallSakura</string>
	<key>CFBundleDisplayName</key><string>WallSakura</string>
	<key>CFBundleExecutable</key><string>WallSakura</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>15.4</string>
	<key>CFBundleIconName</key><string>WallSakura</string>
	<key>CFBundleIconFile</key><string>WallSakura</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Listas de uBlock Origin → bloqueador de contenido de WebKit (ver descargar-filtros.sh)
DATOS="$HOME/Library/Application Support/WallSakura/extensiones"
if [ -d "$DATOS/uBOLite" ]; then
	python3 -I filtros.py "$DATOS/uBOLite/rulesets/main" "$DATOS/filtros"
fi
swiftc -O WallSakura.swift -o "$APP/Contents/MacOS/WallSakura"
codesign --force -s - "$APP"
