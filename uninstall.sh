#!/usr/bin/env bash
# Remove kiro-account-router and restore the real Kiro CLI binary.
# Slot config (~/.config/kiro-auto) and extra login data
# (~/.local/share/kiro-auto/slots) are kept; delete them manually if wanted.
set -euo pipefail

bin_dir="$HOME/.local/bin"
target="$bin_dir/kiro-cli"
real="$bin_dir/kiro-cli-real"
is_shim() { [[ -f "$1" ]] && head -c 512 "$1" | grep -q 'kiro-auto-shim'; }

# Serialize with kiro-auto's shim self-heal and other install/uninstall runs.
lock_dir="$HOME/.local/share/kiro-auto/locks"
mkdir -p "$lock_dir" && chmod 700 "$HOME/.local/share/kiro-auto" "$lock_dir"
exec 9>>"$lock_dir/heal.lock"
flock -w 60 9 || { echo "error: another kiro-auto install/update is running" >&2; exit 1; }

if [[ -x "$real" ]] && ! is_shim "$real"; then
  if [[ ! -e "$target" ]] || is_shim "$target"; then
    mv -f "$real" "$target"
    echo "restored real Kiro CLI -> $target"
  else
    # kiro-cli was replaced by something else (e.g. an update); keep both.
    echo "note: $target is not the shim; left it in place. Older binary kept at $real." >&2
  fi
elif is_shim "$target"; then
  echo "warning: $target is the shim but no real binary was found at $real." >&2
  echo "         Removing the shim; reinstall Kiro CLI to get kiro-cli back." >&2
  rm -f "$target"
fi

# Remove only files this project installed.
for f in "$bin_dir/kiro-auto" "$bin_dir/kiro-usage" "$bin_dir/kiro-delegate" \
  "$HOME/.local/share/kiro-auto/kiro-cli-shim"; do
  [[ -e "$f" ]] || continue
  if grep -q 'Part of kiro-account-router' "$f" 2>/dev/null; then
    rm -f "$f"
    echo "removed $f"
  else
    echo "note: kept $f (not from kiro-account-router)" >&2
  fi
done
echo "kept: ~/.config/kiro-auto, ~/.local/share/kiro-auto/slots, $real.prev (if present)"
