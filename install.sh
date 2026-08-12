#!/usr/bin/env bash
# Copyright 2026 Jack Lau
# SPDX-License-Identifier: Apache-2.0
#
# husk installer - works both ways:
#   local:  bash install.sh            (from a cloned repo)
#   remote: curl -fsSL https://raw.githubusercontent.com/jackulau/husk/main/install.sh | bash
# Options via env:
#   HUSK_BIN_DIR   install destination (default: ~/.local/bin, then /usr/local/bin if writable)
#   HUSK_URL       raw URL of the husk script (remote mode)
set -euo pipefail

HUSK_URL="${HUSK_URL:-https://raw.githubusercontent.com/jackulau/husk/main/bin/husk}"

say() { printf 'husk-install: %s\n' "$*" >&2; }

# --- pick destination ---
dest_dir="${HUSK_BIN_DIR:-}"
if [ -z "$dest_dir" ]; then
  if [ -d "$HOME/.local/bin" ] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
    dest_dir="$HOME/.local/bin"
  elif [ -w /usr/local/bin ]; then
    dest_dir=/usr/local/bin
  else
    dest_dir="$HOME/bin"; mkdir -p "$dest_dir"
  fi
fi
mkdir -p "$dest_dir"

# --- locate source: local repo first, else download ---
src=""
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd -P) || script_dir=""
if [ -n "$script_dir" ] && [ -f "$script_dir/bin/husk" ]; then
  src="$script_dir/bin/husk"
  say "installing from local checkout: $src"
fi

tmp=""
if [ -z "$src" ]; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/husk.XXXXXX")
  say "downloading $HUSK_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$HUSK_URL" -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$HUSK_URL"
  else
    say "need curl or wget"; exit 1
  fi
  head -1 "$tmp" | grep -q 'bash' || { say "downloaded file does not look like husk"; exit 1; }
  src="$tmp"
fi

# --- install + verify ---
install -m 0755 "$src" "$dest_dir/husk" 2>/dev/null || { cp "$src" "$dest_dir/husk" && chmod 0755 "$dest_dir/husk"; }
[ -n "$tmp" ] && rm -f "$tmp"

"$dest_dir/husk" version >/dev/null || { say "installed binary failed self-check"; exit 1; }
say "installed: $dest_dir/husk ($("$dest_dir/husk" version))"

# --- PATH check ---
case ":$PATH:" in
  *":$dest_dir:"*) : ;;
  *)
    say "NOTE: $dest_dir is not on your PATH."
    say "  add:  export PATH=\"$dest_dir:\$PATH\"   (~/.zshrc or ~/.bashrc)"
    ;;
esac

say "next: cd your-repo && husk setup --write"
