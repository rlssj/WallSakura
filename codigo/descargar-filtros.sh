#!/bin/zsh
# Descarga uBlock Origin Lite (solo se usan sus listas de filtros) en ~/Library/Application Support/WallSakura/extensiones/uBOLite.
# Después, compilar.sh las convierte al bloqueador de contenido de WebKit.
set -e
DATOS="$HOME/Library/Application Support/WallSakura/extensiones"
URL=$(curl -sL https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest | grep -o 'https://[^"]*safari\.zip' | head -1)
TMP=$(mktemp -d)
curl -sL -o "$TMP/ubol.zip" "$URL"
rm -rf "$DATOS/uBOLite"
mkdir -p "$DATOS"
unzip -q "$TMP/ubol.zip" -d "$DATOS/uBOLite"
rm -rf "$TMP"
echo "uBlock Origin Lite descargado: $URL"
