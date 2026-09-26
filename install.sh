#!/usr/bin/env bash
# Install kiro-account-router into ~/.local/bin.
#
#   ./install.sh          install / upgrade kiro-auto, kiro-usage, kiro-delegate
#   ./install.sh --shim   also route raw `kiro-cli` calls (opt-in, see below)
#
# Running without --shim after a --shim install removes the shim again.
#
# The --shim step moves the real Kiro CLI binary to ~/.local/bin/kiro-cli-real
# and puts a small routing script at ~/.local/bin/kiro-cli, so any caller
# (other agents, scripts) that runs `kiro-cli chat` is routed through the
# usage-aware selector. Undo with ./uninstall.sh.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin"
bin_dir="$HOME/.local/bin"
state_dir="$HOME/.local/share/kiro-auto"
target="$bin_dir/kiro-cli"
real="$bin_dir/kiro-cli-real"
install_shim=0
case "${1:-}" in
  "" | --no-shim) ;;
  --shim) install_shim=1 ;;
  *)
    echo "usage: $0 [--shim]" >&2
    exit 2
    ;;
esac

is_shim() { [[ -f "$1" ]] && head -c 512 "$1" | grep -q 'kiro-auto-shim'; }

missing=()
for tool in bash tmux perl awk sed seq flock timeout; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
  echo "error: missing required commands: ${missing[*]}" >&2
  exit 1
fi
if ((BASH_VERSINFO[0] < 4)); then
  echo "error: bash 4+ is required" >&2
  exit 1
fi

# Serialize with kiro-auto's shim self-heal and other install/uninstall runs.
lock_dir="$HOME/.local/share/kiro-auto/locks"
mkdir -p "$lock_dir" && chmod 700 "$HOME/.local/share/kiro-auto" "$lock_dir"
exec 9>>"$lock_dir/heal.lock"
flock -w 60 9 || { echo "error: another kiro-auto install/update is running" >&2; exit 1; }

# Never overwrite a same-named command that this project did not install.
owned() { grep -q 'Part of kiro-account-router' "$1" 2>/dev/null; }
for f in kiro-auto kiro-usage kiro-delegate; do
  if [[ -e "$bin_dir/$f" ]] && ! owned "$bin_dir/$f"; then
    echo "error: $bin_dir/$f exists and is not from kiro-account-router; move it away and re-run." >&2
    exit 1
  fi
done
if ((install_shim)) && [[ -e "$target" || -L "$target" ]] && [[ ! -f "$target" || ! -x "$target" ]]; then
  echo "error: $target exists but is not an executable file; move it away and re-run." >&2
  exit 1
fi
if ((install_shim)) && [[ ! -x "$target" && ! -x "$real" ]]; then
  echo "error: no Kiro CLI at $target. Install Kiro CLI first, or install without --shim and set KIRO_AUTO_WSL_CLI." >&2
  exit 1
fi

mkdir -p "$bin_dir"
mkdir -p "$state_dir" && chmod 700 "$state_dir"

install -m 755 "$src/kiro-auto" "$bin_dir/kiro-auto"
install -m 755 "$src/kiro-usage" "$bin_dir/kiro-usage"
install -m 755 "$src/kiro-delegate" "$bin_dir/kiro-delegate"
echo "installed: kiro-auto, kiro-usage, kiro-delegate -> $bin_dir"

if ((install_shim == 0)); then
  # Without the template kiro-auto never rewrites kiro-cli.
  rm -f "$state_dir/kiro-cli-shim"
  if is_shim "$target" && [[ -x "$real" ]] && ! is_shim "$real"; then
    mv -f "$real" "$target"
    echo "restored real Kiro CLI -> $target (shim removed)"
  fi
  [[ -x "$target" ]] || echo "warning: no Kiro CLI at $target; set KIRO_AUTO_WSL_CLI" >&2
  exit 0
fi

if is_shim "$target"; then
  if [[ ! -x "$real" ]] || is_shim "$real"; then
    echo "error: $target is the shim but $real is missing or invalid. Reinstall Kiro CLI first." >&2
    exit 1
  fi
elif [[ -e "$target" || -L "$target" ]] && [[ ! -f "$target" || ! -x "$target" ]]; then
  echo "error: $target exists but is not an executable file; move it away and re-run." >&2
  exit 1
elif [[ -x "$target" ]]; then
  # A fresh (or updated) real binary is at kiro-cli; keep any older copy.
  if [[ -f "$real" ]] && ! is_shim "$real"; then
    mv -f "$real" "$real.prev"
    echo "kept previous real binary -> $real.prev"
  fi
  mv "$target" "$real"
  echo "moved real Kiro CLI -> $real"
elif [[ ! -x "$real" ]] || is_shim "$real"; then
  echo "error: no Kiro CLI at $target. Install Kiro CLI first, or install without --shim and set KIRO_AUTO_WSL_CLI." >&2
  exit 1
fi

staged="$(mktemp "$bin_dir/.kiro-cli-shim.XXXXXX")"
install -m 755 "$src/kiro-cli-shim" "$staged"
mv -f "$staged" "$target"
install -m 755 "$src/kiro-cli-shim" "$state_dir/kiro-cli-shim"
echo "installed routing shim -> $target"

cat <<'EOF'

Optional: add a `kiro` shell function (bash/zsh) for the interactive picker:

  kiro() { command "$HOME/.local/bin/kiro-auto" "$@"; }

Then run:  kiro accounts
EOF
