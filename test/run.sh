#!/usr/bin/env bash
# Offline tests for kiro-auto using fake Kiro CLI and fake /usage probe.
# No real Kiro account or network is used.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail=0

export HOME="$work/home"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/kiro-cli"
export KIRO_AUTO_CONFIG_DIR="$work/config"
export KIRO_AUTO_SHIM=0
export KIRO_AUTO_CACHE_TTL=0 # most tests change state between calls; cache tested below
export KIRO_AUTO_WINDOWS_CLI="$work/none.exe" # windows kind stays unavailable
unset XDG_DATA_HOME KIRO_AUTO_PREFER KIRO_AUTO_FORCE KIRO_AUTO_SLOT KIRO_AUTO_WSL_CLI \
  KIRO_AUTO_MODEL KIRO_AUTO_AGENT KIRO_AUTO_TRUST_ALL KIRO_AUTO_DIAGNOSTICS KIRO_AUTO_CONFIGURE_MODEL

# Fake CLI: account and credits come from files in the active data dir.
cat >"$HOME/.local/bin/kiro-cli-real" <<'EOF'
#!/usr/bin/env bash
data="${XDG_DATA_HOME:-$HOME/.local/share}/kiro-cli"
case "$1" in
  whoami)
    [[ -f "$data/fail" ]] && { echo "transport failed"; exit 42; }
    [[ -f "$data/hang" ]] && sleep 30
    if [[ -f "$data/email" ]]; then echo "Email: $(<"$data/email")"; else echo "Not logged in"; exit 1; fi ;;
  --legacy-ui)
    # Minimal TUI for the real kiro-usage helper.
    echo "ask a question or describe a task"
    read -r line
    if [[ "$line" == /usage && -f "$data/credits" ]]; then
      read -r used limit <"$data/credits"
      echo "Estimated Usage"
      echo "Credits ($used of $limit covered in plan)"
    fi
    sleep 5 ;;
  chat)
    printf '\033[32mANSWER\033[0m %s\n' "$*"
    [[ -t 0 ]] || echo "STDIN:$(cat)"
    echo "chat-diagnostic" >&2
    exit "$(cat "$data/chat_rc" 2>/dev/null || echo 0)" ;;
  settings) echo "settings $*" >>"$data/settings.log"; echo "fake settings $*" ;;
  *) echo "fake $*" ;;
esac
EOF
cat >"$work/fake-usage" <<'EOF'
#!/usr/bin/env bash
data="${XDG_DATA_HOME:-$HOME/.local/share}/kiro-cli"
[[ -f "$data/credits" ]] || exit 1
read -r used limit <"$data/credits"
echo "Estimated Usage"
echo "Credits ($used of $limit covered in plan)"
EOF
chmod 755 "$HOME/.local/bin/kiro-cli-real" "$work/fake-usage"
cp "$HOME/.local/bin/kiro-cli-real" "$work/fake-cli"
export KIRO_AUTO_USAGE_BIN="$work/fake-usage"
export KIRO_AUTO_USAGE_ATTEMPTS=1
auto="$root/bin/kiro-auto"

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    fail=$((fail + 1))
    printf 'FAIL - %s\n  expected to contain: %s\n  actual: %s\n' "$name" "$expected" "$actual"
  fi
}

run() { KIRO_AUTO_DRY_RUN=1 "$auto" "$@" </dev/null 2>&1; }

echo "a@example.com" >"$HOME/.local/share/kiro-cli/email"
echo "10 100" >"$HOME/.local/share/kiro-cli/credits"
check "default slot used when it has credits" "Using: wsl" "$(run chat --no-interactive -- hi)"
check "slots file created" "wsl         wsl" "$(cat "$KIRO_AUTO_CONFIG_DIR/slots")"

run account add promo >/dev/null
promo="$HOME/.local/share/kiro-auto/slots/promo/kiro-cli"
check "extra slot shares runtime dir" "promo" "$(ls "$HOME/.local/share/kiro-auto/slots")"
check "extra slot not logged in" "not-logged-in" "$(run accounts)"

echo "b@example.com" >"$promo/email"
echo "5 50" >"$promo/credits"
echo "100 100" >"$HOME/.local/share/kiro-cli/credits"
out="$(run chat --no-interactive -- hi)"
check "falls back when preferred slot is full" "Using: promo" "$out"
check "extra slot runs with its XDG_DATA_HOME" "XDG_DATA_HOME=$HOME/.local/share/kiro-auto/slots/promo" "$out"

echo "10 100" >"$HOME/.local/share/kiro-cli/credits"
run use promo >/dev/null
check "preference moves slot first" "Using: promo" "$(run chat --no-interactive -- hi)"
run use auto >/dev/null
check "preference cleared" "Using: wsl" "$(run chat --no-interactive -- hi)"

check "forced slot" "(forced)" "$(run @promo chat -- hi)"
check "forced unknown slot fails" "unknown slot" "$(run @nope chat -- hi)"

rm "$HOME/.local/share/kiro-cli/credits"
rm "$promo/credits"
out="$(run chat --no-interactive -- hi)"
check "unknown usage never guessed" "never guessed" "$out"
KIRO_AUTO_DRY_RUN=1 "$auto" chat -- hi </dev/null >/dev/null 2>&1
check "unknown usage exits 69" "69" "$?"

echo "100 100" >"$HOME/.local/share/kiro-cli/credits"
echo "50 50" >"$promo/credits"
sed -i 's/^windows /# windows /' "$KIRO_AUTO_CONFIG_DIR/slots"
KIRO_AUTO_DRY_RUN=1 "$auto" chat -- hi </dev/null >/dev/null 2>&1
check "all full exits 75" "75" "$?"

awk '$1=="promo"{$4="c@example.com"}1' "$KIRO_AUTO_CONFIG_DIR/slots" >"$work/s" && mv "$work/s" "$KIRO_AUTO_CONFIG_DIR/slots"
check "pin_email mismatch is rejected" "pin-mismatch" "$(run accounts)"

run account rm promo >/dev/null
check "slot removed" "0" "$(grep -c '^promo' "$KIRO_AUTO_CONFIG_DIR/slots")"

# Shim: `kiro-cli chat` routes to kiro-auto, other subcommands go to the real binary.
cp "$root/bin/kiro-cli-shim" "$HOME/.local/bin/kiro-cli"
cp "$auto" "$HOME/.local/bin/kiro-auto"
chmod 755 "$HOME/.local/bin/kiro-cli" "$HOME/.local/bin/kiro-auto"
echo "1 100" >"$HOME/.local/share/kiro-cli/credits"
check "shim routes chat" "Using: wsl" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" chat --model m -- hi </dev/null 2>&1)"
check "shim keeps caller flags" "chat --model m -- hi" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" chat --model m -- hi </dev/null 2>&1)"
check "shim routes option-first chat" "Using: wsl" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" --legacy-ui chat --model m </dev/null 2>&1)"
check "option-first chat keeps global flag before chat" "kiro-cli-real --legacy-ui chat --model m" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" --legacy-ui chat --model m </dev/null 2>&1)"
for form in "--resume" "--agent x" ""; do
  # shellcheck disable=SC2086
  check "shim routes implicit chat: kiro-cli $form" "Using: wsl" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" $form </dev/null 2>&1)"
done
check "implicit chat becomes an explicit chat" "kiro-cli-real chat --resume" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" --resume </dev/null 2>&1)"
out="$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" acp 2>"$work/acp.err" </dev/null)"
check "acp is routed and runs as acp" "kiro-cli-real acp" "$out"
check "acp selector messages stay off stdout" "Using: wsl" "$(cat "$work/acp.err")"
check "translate is routed" "kiro-cli-real translate list\ files" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" translate "list files" </dev/null 2>&1)"
check "shim passes other commands" "fake settings" "$("$HOME/.local/bin/kiro-cli" settings </dev/null 2>&1)"

# Shim self-heal after an update overwrote kiro-cli.
mkdir -p "$HOME/.local/share/kiro-auto"
cp "$root/bin/kiro-cli-shim" "$HOME/.local/share/kiro-auto/kiro-cli-shim"
printf 'new-binary' >"$HOME/.local/bin/kiro-cli"
KIRO_AUTO_SHIM=1 "$auto" use auto >/dev/null 2>&1
check "shim reinstalled after update" "new-binary" "$(cat "$HOME/.local/bin/kiro-cli-real")"
check "shim back in place" "kiro-auto-shim" "$(cat "$HOME/.local/bin/kiro-cli")"


# Restore the fake real CLI (the heal test replaced it) and drop the shim template.
cp "$work/fake-cli" "$HOME/.local/bin/kiro-cli-real"
rm -f "$HOME/.local/share/kiro-auto/kiro-cli-shim"

# --- XDG isolation: an inherited XDG_DATA_HOME must not change the default slot.
"$auto" account add custom >/dev/null 2>&1 </dev/null
custom="$HOME/.local/share/kiro-auto/slots/custom/kiro-cli"
echo "custom@example.com" >"$custom/email"
echo "1 10" >"$custom/credits"
out="$(XDG_DATA_HOME="$HOME/.local/share/kiro-auto/slots/custom" "$auto" accounts </dev/null 2>&1)"
check "default slot ignores inherited XDG_DATA_HOME" "a@example.com" "$(grep ' wsl (wsl)' <<<"$out")"
check "extra slot keeps its own account" "custom@example.com" "$(grep 'custom (wsl' <<<"$out")"
"$auto" account rm custom >/dev/null 2>&1

# --- duplicate slot names are rejected.
cp "$KIRO_AUTO_CONFIG_DIR/slots" "$work/slots.bak"
echo "wsl wsl - -" >>"$KIRO_AUTO_CONFIG_DIR/slots"
check "duplicate slot rejected" "duplicate slot name" "$("$auto" accounts </dev/null 2>&1)"
cp "$work/slots.bak" "$KIRO_AUTO_CONFIG_DIR/slots"

cp "$root/bin/kiro-cli-shim" "$HOME/.local/share/kiro-auto/kiro-cli-shim"
# --- concurrent self-heal never turns kiro-cli-real into the shim.
printf '#!/bin/sh\necho updated "$@"\n' >"$HOME/.local/bin/kiro-cli"
chmod 755 "$HOME/.local/bin/kiro-cli"
for _ in 1 2 3 4 5 6 7 8; do KIRO_AUTO_SHIM=1 "$auto" use auto >/dev/null 2>&1 & done
wait
check "concurrent heal: real binary is not the shim" "updated" "$(cat "$HOME/.local/bin/kiro-cli-real")"
check "concurrent heal: shim installed" "kiro-auto-shim" "$(cat "$HOME/.local/bin/kiro-cli")"

cp "$work/fake-cli" "$HOME/.local/bin/kiro-cli-real"
rm -f "$HOME/.local/share/kiro-auto/kiro-cli-shim"
# --- kiro-delegate passes the model via settings and keeps stdout clean.
cp "$root/bin/kiro-delegate" "$HOME/.local/bin/kiro-delegate"
out="$(KIRO_AUTO_BIN="$auto" KIRO_AUTO_DRY_RUN=1 "$root/bin/kiro-delegate" --model m1 --no-tools --prompt hi 2>/dev/null)"
check "delegate sets model globally" "Would set global model: m1" "$out"
check "delegate uses v2 headless" "--agent-engine v2 --no-interactive" "$out"
check "delegate requires --model" "--model is required" "$("$root/bin/kiro-delegate" --prompt hi 2>&1)"

# --- unknown explicit admin slot is rejected (never runs on another slot).
out="$("$auto" logout typo </dev/null 2>&1)"; rc=$?
check "unknown admin slot rejected" "unknown slot: typo" "$out"
check "unknown admin slot exits 2" "2" "$rc"

# --- concurrent slot adds do not create duplicates.
for _ in $(seq 1 12); do "$auto" account add race </dev/null >/dev/null 2>&1 & done
wait
check "concurrent add creates one slot" "1" "$(grep -c '^race ' "$KIRO_AUTO_CONFIG_DIR/slots")"
"$auto" account rm race >/dev/null 2>&1

# --- existing permissive config is tightened.
chmod 755 "$KIRO_AUTO_CONFIG_DIR"; chmod 644 "$KIRO_AUTO_CONFIG_DIR/slots"
"$auto" accounts </dev/null >/dev/null 2>&1
check "config permissions tightened" "700 600" "$(stat -c %a "$KIRO_AUTO_CONFIG_DIR") $(stat -c %a "$KIRO_AUTO_CONFIG_DIR/slots")"

# --- `update` runs through kiro-auto and heals the shim afterwards.
cp "$root/bin/kiro-cli-shim" "$HOME/.local/bin/kiro-cli"
cp "$root/bin/kiro-cli-shim" "$HOME/.local/share/kiro-auto/kiro-cli-shim"
cat >"$HOME/.local/bin/kiro-cli-real" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == update ]]; then
  printf '#!/bin/sh\necho v2 "$@"\n' >"$HOME/.local/bin/kiro-cli"
  chmod 755 "$HOME/.local/bin/kiro-cli"
  exit 0
fi
echo v1 "$@"
EOF
chmod 755 "$HOME/.local/bin/kiro-cli-real"
KIRO_AUTO_SHIM=1 "$HOME/.local/bin/kiro-cli" update </dev/null >/dev/null 2>&1; rc=$?
check "update exit status kept" "0" "$rc"
check "update: shim reinstalled" "kiro-auto-shim" "$(cat "$HOME/.local/bin/kiro-cli")"
check "update: new binary is real" "v2" "$(cat "$HOME/.local/bin/kiro-cli-real")"
check "update: old binary kept as .prev" "v1" "$(cat "$HOME/.local/bin/kiro-cli-real.prev")"
cp "$work/fake-cli" "$HOME/.local/bin/kiro-cli-real"
rm -f "$HOME/.local/share/kiro-auto/kiro-cli-shim"

# --- whoami failures are probe-error, not "not logged in".
touch "$HOME/.local/share/kiro-cli/fail"
check "whoami failure is probe-error" "probe-error" "$("$auto" accounts </dev/null 2>&1)"
check "forced slot with probe error does not ask to log in" "unavailable: probe-error" "$(KIRO_AUTO_DRY_RUN=1 "$auto" @wsl chat -- hi </dev/null 2>&1)"
rm -f "$HOME/.local/share/kiro-cli/fail"

# --- probe wave has an overall deadline.
touch "$HOME/.local/share/kiro-cli/hang"
start=$SECONDS
out="$(KIRO_AUTO_PROBE_DEADLINE=2 "$auto" accounts </dev/null 2>&1)"
elapsed=$((SECONDS - start))
check "probe deadline bounds the wait" "yes" "$( ((elapsed <= 10)) && echo yes || echo "no (${elapsed}s)")"
check "timed-out slot is unknown" "unknown" "$(grep ' wsl (wsl)' <<<"$out")"
rm -f "$HOME/.local/share/kiro-cli/hang"

# --- KIRO_AUTO_WSL_CLI pointing at the shim is rejected instead of recursing.
out="$(KIRO_AUTO_WSL_CLI="$root/bin/kiro-cli-shim" timeout 10 "$auto" @wsl whoami </dev/null 2>&1)"; rc=$?
check "override to shim rejected" "must be the real Kiro CLI" "$out"
check "override to shim exits 2" "2" "$rc"

# --- real kiro-usage helper against a tmux server started with another HOME.
if command -v tmux >/dev/null; then
  sock="$work/tmux.sock"
  other="$work/other-home"
  mkdir -p "$other/.local/share/kiro-cli"
  echo "1 100" >"$other/.local/share/kiro-cli/credits"
  echo "77 100" >"$HOME/.local/share/kiro-cli/credits"
  HOME="$other" tmux -S "$sock" new-session -d -s keep "sleep 60"
  mkdir -p "$work/tmuxwrap"
  printf '#!/bin/sh\nexec %s -S %s "$@"\n' "$(command -v tmux)" "$sock" >"$work/tmuxwrap/tmux"
  chmod 755 "$work/tmuxwrap/tmux"
  out="$(PATH="$work/tmuxwrap:$PATH" "$root/bin/kiro-usage" "$HOME/.local/bin/kiro-cli-real" 2>&1)"
  check "kiro-usage reads the /usage panel" "Credits (77 of 100" "$out"
  check "kiro-usage uses the caller's HOME, not the tmux server's" "no-1" "$([[ "$out" == *"(1 of 100"* ]] && echo yes-1 || echo no-1)"
  tmux -S "$sock" kill-server 2>/dev/null
  echo "10 100" >"$HOME/.local/share/kiro-cli/credits"
else
  echo "skip - tmux not installed (kiro-usage tests)"
fi

# --- kiro-delegate real run: clean stdout, diagnostics on stderr, exit code kept.
rm -f "$HOME/.local/share/kiro-cli/settings.log"
KIRO_AUTO_BIN="$auto" "$root/bin/kiro-delegate" --model m2 --prompt hi >"$work/d.out" 2>"$work/d.err"; rc=$?
check "delegate exit 0" "0" "$rc"
check "delegate stdout has the answer without ANSI" "ANSWER" "$(cat "$work/d.out")"
check "delegate stdout ANSI stripped" "clean" "$(grep -q $'\033' "$work/d.out" && echo dirty || echo clean)"
check "delegate selector line only on stderr" "clean" "$(grep -q 'Using:' "$work/d.out" && echo dirty || echo clean)"
check "delegate diagnostics on stderr" "Using: wsl" "$(cat "$work/d.err")"
check "delegate default is read-only tools" "--trust-tools=fs_read" "$(cat "$work/d.out")"
check "delegate set model via settings" "chat.defaultModel m2" "$(cat "$HOME/.local/share/kiro-cli/settings.log")"
echo 7 >"$HOME/.local/share/kiro-cli/chat_rc"
KIRO_AUTO_BIN="$auto" "$root/bin/kiro-delegate" --model m2 --no-tools --prompt hi >/dev/null 2>&1; rc=$?
check "delegate keeps Kiro's exit code" "7" "$rc"
check "delegate sends the prompt on stdin" "STDIN:hi" "$(cat "$work/d.out")"
check "delegate keeps the prompt out of argv" "clean" "$(grep -q -- '-- hi' "$work/d.out" && echo dirty || echo clean)"
rm -f "$HOME/.local/share/kiro-cli/chat_rc"

# --- failed update keeps the known-good binary; routers during an update use it.
cp "$root/bin/kiro-cli-shim" "$HOME/.local/bin/kiro-cli"
cp "$root/bin/kiro-cli-shim" "$HOME/.local/share/kiro-auto/kiro-cli-shim"
cat >"$HOME/.local/bin/kiro-cli-real" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == update ]]; then
  printf '#!/bin/sh\necho PARTIAL "$@"\n' >"$HOME/.local/bin/kiro-cli"
  chmod 755 "$HOME/.local/bin/kiro-cli"
  [[ -f "$HOME/pause" ]] && sleep 3
  exit "$(cat "$HOME/update_rc" 2>/dev/null || echo 0)"
fi
echo GOOD "$@"
EOF
chmod 755 "$HOME/.local/bin/kiro-cli-real"
echo 42 >"$HOME/update_rc"
KIRO_AUTO_SHIM=1 "$HOME/.local/bin/kiro-cli" update </dev/null >/dev/null 2>&1; rc=$?
check "failed update exit code kept" "42" "$rc"
check "failed update keeps known-good real" "echo GOOD" "$(cat "$HOME/.local/bin/kiro-cli-real")"
check "failed update restores the shim" "kiro-auto-shim" "$(cat "$HOME/.local/bin/kiro-cli")"
check "failed update output moved aside" "PARTIAL" "$(cat "$HOME/.local/bin/kiro-cli.failed-update")"
rm -f "$HOME/update_rc" "$HOME/.local/bin/kiro-cli.failed-update"
touch "$HOME/pause"
KIRO_AUTO_SHIM=1 "$HOME/.local/bin/kiro-cli" update </dev/null >/dev/null 2>&1 &
sleep 1
out="$(KIRO_AUTO_SHIM=1 "$auto" @wsl settings 2>&1)"
wait
# The router either ran before the update (GOOD) or waited for the lock and
# used the finished update; it must never run while files are mid-change.
check "router during update is serialized" "settings" "$out"
check "shim in place after update" "kiro-auto-shim" "$(cat "$HOME/.local/bin/kiro-cli")"
check "successful update installed after the lock" "PARTIAL" "$(cat "$HOME/.local/bin/kiro-cli-real")"
check "known-good kept as .prev" "echo GOOD" "$(cat "$HOME/.local/bin/kiro-cli-real.prev")"
rm -f "$HOME/pause"
cp "$work/fake-cli" "$HOME/.local/bin/kiro-cli-real"
rm -f "$HOME/.local/share/kiro-auto/kiro-cli-shim"

# --- headless login/logout: active chat slot, else an explicit slot is required.
"$auto" account add beta </dev/null >/dev/null 2>&1
out="$("$auto" logout </dev/null 2>&1)"; rc=$?
check "headless logout without slot is refused" "needs a slot" "$out"
check "headless logout without slot exits 2" "2" "$rc"
beta_dir="$HOME/.local/share/kiro-auto/slots/beta"
out="$(KIRO_AUTO_SLOT=beta "$auto" logout </dev/null 2>&1)"
cat >"$work/envcli" <<'EOF'
#!/usr/bin/env bash
echo "ACTION=$1 XDG=${XDG_DATA_HOME:-default}"
EOF
chmod 755 "$work/envcli"
out="$(KIRO_AUTO_WSL_CLI="$work/envcli" KIRO_AUTO_SLOT=beta "$auto" logout </dev/null 2>&1)"
check "logout inside a chat uses that chat's slot" "ACTION=logout XDG=$beta_dir" "$out"
out="$(KIRO_AUTO_SLOT=windows HOME="$HOME" bash "$root/bin/kiro-cli-shim" logout </dev/null 2>&1)"
check "nested windows-slot logout is not sent to the Linux CLI" "not-linux" "$([[ "$out" == *"fake logout"* ]] && echo linux || echo not-linux)"
"$auto" account rm beta >/dev/null 2>&1

# --- menu/listing numbers follow the displayed (preference) order.
"$auto" account add second </dev/null >/dev/null 2>&1
echo "b@example.com" >"$HOME/.local/share/kiro-auto/slots/second/kiro-cli/email"
"$auto" use second >/dev/null 2>&1
check "listing shows preferred slot as 1" "1) second" "$("$auto" accounts </dev/null 2>&1)"
check "number 1 resolves to the listed first slot" "[second (wsl, extra)] (forced)" "$(KIRO_AUTO_DRY_RUN=1 "$auto" @1 chat -- hi </dev/null 2>&1)"
"$auto" use auto >/dev/null 2>&1
"$auto" account rm second >/dev/null 2>&1

# --- identity is verified right before every chat.
cat >"$work/vanishcli" <<'EOF'
#!/usr/bin/env bash
data="$HOME/.local/share/kiro-cli"
n=$(cat "$data/n" 2>/dev/null || echo 0); echo $((n + 1)) >"$data/n"
[[ "$1" == whoami ]] && ((n == 0)) && echo "Email: a@example.com"
exit 0
EOF
chmod 755 "$work/vanishcli"
rm -f "$HOME/.local/share/kiro-cli/n"
check "unverifiable identity before chat is refused" "could not verify" "$(KIRO_AUTO_WSL_CLI="$work/vanishcli" "$auto" @wsl chat -- hi </dev/null 2>&1)"
rm -f "$HOME/.local/share/kiro-cli/n"

# --- option values are never mistaken for subcommands.
for name in settings profile help; do
  check "kiro-cli --agent $name is routed" "Using: wsl" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" --agent "$name" </dev/null 2>&1)"
done
check "--agent X chat keeps the value before chat" "kiro-cli-real --agent settings chat" "$(KIRO_AUTO_DRY_RUN=1 "$HOME/.local/bin/kiro-cli" --agent settings chat </dev/null 2>&1)"

# --- shim and kiro-auto agree on passthrough commands.
shim_list="$(sed -n 's/^PASSTHROUGH=" \(.*\) "$/\1/p' "$root/bin/kiro-cli-shim" | tr ' ' '\n' | sort | tr '\n' ' ')"
auto_list="$(grep -A1 '^  debug | settings' "$auto" | head -1 | tr -d ')' | tr '|' '\n' | tr -d ' ' | grep . | sort | tr '\n' ' ')"
check "passthrough lists match" "same" "$([[ "$shim_list" == "$auto_list" ]] && echo same || echo "diff: [$shim_list] vs [$auto_list]")"
check "passthrough list not empty" "settings" "$shim_list"

# --- probe cache: a fresh result skips /usage; login/logout and --refresh clear it.
cat >"$work/count-usage" <<'EOF'
#!/usr/bin/env bash
echo x >>"$HOME/usage.calls"
exec "$REAL_USAGE" "$@"
EOF
chmod 755 "$work/count-usage"
rm -f "$HOME/usage.calls" "$HOME/.local/share/kiro-auto/cache/"*
echo "10 100" >"$HOME/.local/share/kiro-cli/credits"
cached_run() { KIRO_AUTO_CACHE_TTL=300 REAL_USAGE="$work/fake-usage" KIRO_AUTO_USAGE_BIN="$work/count-usage" "$auto" "$@" </dev/null 2>&1; }
cached_run accounts >/dev/null
calls1="$(wc -l <"$HOME/usage.calls")"
out="$(cached_run accounts)"
check "second listing uses the cache" "$calls1" "$(wc -l <"$HOME/usage.calls")"
check "cached rows are labelled" "checked" "$out"
out="$(KIRO_AUTO_DRY_RUN=1 cached_run chat --no-interactive -- hi)"
check "cached fast path starts the chat" "Using: wsl" "$out"
check "fast path runs no /usage" "$calls1" "$(wc -l <"$HOME/usage.calls")"
cached_run accounts --refresh >/dev/null
check "--refresh re-checks" "yes" "$( (($(wc -l <"$HOME/usage.calls") > calls1)) && echo yes)"
echo "b@example.com" >"$HOME/.local/share/kiro-cli/email"
check "cached account change still refused before chat" "account changed" "$(cached_run chat --no-interactive -- hi)"
echo "a@example.com" >"$HOME/.local/share/kiro-cli/email"
KIRO_AUTO_WSL_CLI="$work/fake-cli" cached_run logout wsl >/dev/null
check "logout clears that slot's cache" "gone" "$([[ -e "$HOME/.local/share/kiro-auto/cache/wsl" ]] || echo gone)"
rm -f "$HOME/usage.calls" "$HOME/.local/share/kiro-auto/cache/"*

# Malformed cache records are ignored (full probe instead).
mkdir -p "$HOME/.local/share/kiro-auto/cache"
now="$(date +%s)"
for rec in "$now\tavailable" "$now\tavailable\ta@example.com\t1\t100\textra" \
  "$now\tavailable\ta@example.com\tx\t100" "$now\tavailable\ta@example.com\t100\t100" \
  "$((now + 999))\tavailable\ta@example.com\t1\t100" "$now\tavailable\t-\t1\t100"; do
  printf "$rec\n" >"$HOME/.local/share/kiro-auto/cache/wsl"
  rm -f "$HOME/usage.calls"
  cached_run accounts >/dev/null
  check "malformed cache ignored: $(printf "$rec" | cut -f2- | tr '\t' ' ')" "x" "$(head -1 "$HOME/usage.calls" 2>/dev/null)"
done
rm -f "$HOME/usage.calls" "$HOME/.local/share/kiro-auto/cache/"*

# Login switched during /usage: the chat is refused, never run on the new account.
cat >"$work/switch-usage" <<'EOF'
#!/usr/bin/env bash
echo "b@example.com" >"$HOME/.local/share/kiro-cli/email"
echo "Estimated Usage"
echo "Credits (10 of 100 covered in plan)"
EOF
chmod 755 "$work/switch-usage"
echo "a@example.com" >"$HOME/.local/share/kiro-cli/email"
out="$(KIRO_AUTO_USAGE_BIN="$work/switch-usage" KIRO_AUTO_CACHE_TTL=300 "$auto" chat --no-interactive -- hi </dev/null 2>&1)"
check "login switch during /usage is refused" "never guessed" "$out"
check "switched result not left in cache" "gone" "$([[ -e "$HOME/.local/share/kiro-auto/cache/wsl" ]] || echo gone)"
echo "a@example.com" >"$HOME/.local/share/kiro-cli/email"
# Switch during /usage and back again: the mixed result is never cached/used.
out="$(KIRO_AUTO_USAGE_BIN="$work/switch-usage" KIRO_AUTO_CACHE_TTL=300 "$auto" accounts </dev/null 2>&1)"
check "switch during /usage makes usage unknown" "unknown" "$(grep ' wsl (wsl)' <<<"$out")"
check "switch during /usage is not cached" "gone" "$([[ -e "$HOME/.local/share/kiro-auto/cache/wsl" ]] || echo gone)"
echo "a@example.com" >"$HOME/.local/share/kiro-cli/email"
# Pin mismatch before a chat drops the cache entry.
awk '$1=="wsl"{$4="a@example.com"}1' "$KIRO_AUTO_CONFIG_DIR/slots" >"$work/s" && mv "$work/s" "$KIRO_AUTO_CONFIG_DIR/slots"
printf '%s\tavailable\ta@example.com\t1\t100\n' "$(date +%s)" >"$HOME/.local/share/kiro-auto/cache/wsl"
echo "b@example.com" >"$HOME/.local/share/kiro-cli/email"
KIRO_AUTO_CACHE_TTL=300 "$auto" chat --no-interactive -- hi </dev/null >/dev/null 2>&1
check "pin mismatch before chat clears cache" "gone" "$([[ -e "$HOME/.local/share/kiro-auto/cache/wsl" ]] || echo gone)"
awk '$1=="wsl"{$4="-"}1' "$KIRO_AUTO_CONFIG_DIR/slots" >"$work/s" && mv "$work/s" "$KIRO_AUTO_CONFIG_DIR/slots"
echo "a@example.com" >"$HOME/.local/share/kiro-cli/email"

# --- account change between the check and the chat is refused.
cat >"$work/flipcli" <<'EOF'
#!/usr/bin/env bash
data="$HOME/.local/share/kiro-cli"
case "$1" in
  whoami)
    n=$(cat "$data/n" 2>/dev/null || echo 0); echo $((n + 1)) >"$data/n"
    if ((n == 0)); then echo "Email: a@example.com"; else echo "Email: b@example.com"; fi ;;
  chat) echo "CHAT" ;;
esac
EOF
chmod 755 "$work/flipcli"
rm -f "$HOME/.local/share/kiro-cli/n"
out="$(KIRO_AUTO_WSL_CLI="$work/flipcli" "$auto" @wsl chat -- hi </dev/null 2>&1)"; rc=$?
check "account change before chat is refused" "account changed" "$out"
check "account change exits 78" "78" "$rc"
rm -f "$HOME/.local/share/kiro-cli/n"

# --- update succeeds but the shim cannot be restored -> nonzero.
cp "$root/bin/kiro-cli-shim" "$HOME/.local/bin/kiro-cli"
printf 'CORRUPT' >"$HOME/.local/share/kiro-auto/kiro-cli-shim"
cat >"$HOME/.local/bin/kiro-cli-real" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == update ]] && { printf '#!/bin/sh\necho NEW "$@"\n' >"$HOME/.local/bin/kiro-cli"; chmod 755 "$HOME/.local/bin/kiro-cli"; exit 0; }
echo OLD "$@"
EOF
chmod 755 "$HOME/.local/bin/kiro-cli-real"
KIRO_AUTO_SHIM=1 "$HOME/.local/bin/kiro-cli" update </dev/null >/dev/null 2>&1; rc=$?
check "update with broken shim template fails loudly" "70" "$rc"
cp "$work/fake-cli" "$HOME/.local/bin/kiro-cli-real"
cp "$root/bin/kiro-cli-shim" "$HOME/.local/bin/kiro-cli"
rm -f "$HOME/.local/share/kiro-auto/kiro-cli-shim"

# --- install.sh / uninstall.sh lifecycle in a fresh HOME.
ih="$work/install-home"
mkdir -p "$ih/.local/bin"
printf '#!/bin/sh\necho real "$@"\n' >"$ih/.local/bin/kiro-cli"
chmod 755 "$ih/.local/bin/kiro-cli"
HOME="$ih" bash "$root/install.sh" >/dev/null 2>&1
HOME="$ih" KIRO_AUTO_CONFIG_DIR="$ih/cfg" "$ih/.local/bin/kiro-auto" use auto >/dev/null 2>&1
check "default install leaves kiro-cli untouched" "echo real" "$(cat "$ih/.local/bin/kiro-cli")"
# Stale kiro-cli-real next to a real kiro-cli: the selector must use kiro-cli.
printf '#!/bin/sh\necho stale "$@"\n' >"$ih/.local/bin/kiro-cli-real"
chmod 755 "$ih/.local/bin/kiro-cli-real"
out="$(HOME="$ih" KIRO_AUTO_CONFIG_DIR="$ih/cfg" "$ih/.local/bin/kiro-auto" @wsl whoami 2>&1)"
check "no shim: selector uses active kiro-cli" "real whoami" "$out"
check "--no-shim: stale kiro-cli-real not used" "absent" "$([[ "$out" == *stale* ]] || echo absent)"
rm -f "$ih/.local/bin/kiro-cli-real"
HOME="$ih" bash "$root/install.sh" --shim >/dev/null 2>&1
check "install moves real binary" "echo real" "$(cat "$ih/.local/bin/kiro-cli-real")"
check "install puts shim" "kiro-auto-shim" "$(cat "$ih/.local/bin/kiro-cli")"
HOME="$ih" bash "$root/install.sh" --shim >/dev/null 2>&1
check "reinstall keeps real binary" "echo real" "$(cat "$ih/.local/bin/kiro-cli-real")"
HOME="$ih" bash "$root/uninstall.sh" >/dev/null 2>&1
check "uninstall restores real binary" "echo real" "$(cat "$ih/.local/bin/kiro-cli")"
check "uninstall removes kiro-auto" "gone" "$([[ -e "$ih/.local/bin/kiro-auto" ]] || echo gone)"
HOME="$ih" bash "$root/install.sh" --shim >/dev/null 2>&1
rm -f "$ih/.local/bin/kiro-cli"
HOME="$ih" bash "$root/uninstall.sh" >/dev/null 2>&1
check "uninstall restores when shim path is missing" "echo real" "$(cat "$ih/.local/bin/kiro-cli")"

# Concurrent install/uninstall never loses the real binary.
HOME="$ih" bash "$root/install.sh" --shim >/dev/null 2>&1
for _ in 1 2 3 4; do
  HOME="$ih" bash "$root/install.sh" --shim >/dev/null 2>&1 &
  HOME="$ih" bash "$root/uninstall.sh" >/dev/null 2>&1 &
done
wait
real_copies="$(grep -l 'echo real' "$ih/.local/bin/kiro-cli" "$ih/.local/bin/kiro-cli-real" "$ih/.local/bin/kiro-cli-real.prev" 2>/dev/null | wc -l)"
check "concurrent install/uninstall keeps the real binary" "1" "$real_copies"
HOME="$ih" bash "$root/uninstall.sh" >/dev/null 2>&1
check "final uninstall restores kiro-cli" "echo real" "$(cat "$ih/.local/bin/kiro-cli")"

# Install/uninstall never overwrite or delete same-named commands they do not own.
oh="$work/owner-home"
mkdir -p "$oh/.local/bin"
printf '#!/bin/sh\necho real\n' >"$oh/.local/bin/kiro-cli"; chmod 755 "$oh/.local/bin/kiro-cli"
printf '#!/bin/sh\necho OTHER-TOOL\n' >"$oh/.local/bin/kiro-auto"; chmod 755 "$oh/.local/bin/kiro-auto"
HOME="$oh" bash "$root/install.sh" --shim >/dev/null 2>&1; rc=$?
check "install refuses a foreign kiro-auto" "1" "$rc"
check "foreign kiro-auto kept" "OTHER-TOOL" "$(cat "$oh/.local/bin/kiro-auto")"
check "kiro-cli untouched after refused install" "echo real" "$(cat "$oh/.local/bin/kiro-cli")"
rm "$oh/.local/bin/kiro-auto"
HOME="$oh" bash "$root/install.sh" --shim >/dev/null 2>&1
printf '#!/bin/sh\necho REPLACED\n' >"$oh/.local/bin/kiro-delegate"
HOME="$oh" bash "$root/uninstall.sh" >/dev/null 2>&1
check "uninstall keeps a replaced helper" "REPLACED" "$(cat "$oh/.local/bin/kiro-delegate")"
check "uninstall removes its own helpers" "gone" "$([[ -e "$oh/.local/bin/kiro-auto" ]] || echo gone)"

# A foreign helper created while install waits for the lock survives.
lh="$work/lock-home"
mkdir -p "$lh/.local/bin" "$lh/.local/share/kiro-auto/locks"
printf '#!/bin/sh\necho real\n' >"$lh/.local/bin/kiro-cli"; chmod 755 "$lh/.local/bin/kiro-cli"
exec 8>>"$lh/.local/share/kiro-auto/locks/heal.lock"
flock 8
HOME="$lh" bash "$root/install.sh" --no-shim >/dev/null 2>&1 &
ipid=$!
sleep 1
printf '#!/bin/sh\necho FOREIGN\n' >"$lh/.local/bin/kiro-auto"
flock -u 8; exec 8>&-
wait "$ipid"; rc=$?
check "install re-checks ownership after the lock" "1" "$rc"
check "foreign helper created during lock wait survives" "FOREIGN" "$(cat "$lh/.local/bin/kiro-auto")"

# Install must refuse (not overwrite) an unexpected non-executable kiro-cli.
HOME="$ih" bash "$root/install.sh" --shim >/dev/null 2>&1
mv "$ih/.local/bin/kiro-cli" "$work/shim.bak"
printf 'DO-NOT-LOSE' >"$ih/.local/bin/kiro-cli"; chmod 600 "$ih/.local/bin/kiro-cli"
HOME="$ih" bash "$root/install.sh" --shim >/dev/null 2>&1; rc=$?
check "install refuses non-executable kiro-cli" "1" "$rc"
check "install keeps unexpected kiro-cli" "DO-NOT-LOSE" "$(cat "$ih/.local/bin/kiro-cli")"

echo "$pass passed, $fail failed"
((fail == 0))
