#!/bin/sh
#
# Install mateinate without Homebrew: link it into ~/.local/bin, then load the
# LaunchAgents (which asks for the sudoers rule once).
#
set -eu

SRC=$(cd "$(dirname "$0")" && pwd -P)
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$BIN_DIR"
ln -sf "$SRC/mateinate" "$BIN_DIR/mateinate"
echo "linked $BIN_DIR/mateinate"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: add $BIN_DIR to your PATH so 'mateinate' works everywhere" ;;
esac

exec "$BIN_DIR/mateinate" install
