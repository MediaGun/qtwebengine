#!/bin/bash
# Prepares a Mac as the self-hosted GitHub Actions runner that builds Qt WebEngine
# ("Build for MacOS" in .github/workflows/build.yaml, runner label macos-we-builder).
#
# Checks everything the job needs, installs or configures what is missing, and prints a summary.
# Safe to run again. Run it as the user the runner runs as (not root); it asks for sudo when needed.
#
#   ./setup-macos-runner.sh --check-only              # only report
#   ./setup-macos-runner.sh                           # install and configure
#   ./setup-macos-runner.sh --runner-token AAAA...    # also register the runner
#
# Not installed here, the job's actions download them: Node.js, CMake, Ninja, Python, Qt.
# Xcode can't be installed unattended (it needs an Apple ID): the script says what to do.
#
# Works with macOS's bash 3.2.

set -uo pipefail

CHECK_ONLY=0
RUNNER_URL="https://github.com/MediaGun/qtwebengine"
RUNNER_TOKEN=""
RUNNER_NAME="$(scutil --get ComputerName 2>/dev/null | tr ' ' '-' || hostname -s)"
RUNNER_LABELS="macos-we-builder"
RUNNER_DIR="$HOME/actions-runner"
MIN_FREE_GB=150
MIN_RAM_GB=32
MIN_XCODE_MAJOR=26          # xcodebuild -downloadComponent MetalToolchain, which the job runs
BREW_PACKAGES="gperf bison flex ccache git"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --runner-token) RUNNER_TOKEN="$2"; shift ;;
    --runner-url) RUNNER_URL="$2"; shift ;;
    --runner-name) RUNNER_NAME="$2"; shift ;;
    --runner-labels) RUNNER_LABELS="$2"; shift ;;
    --runner-dir) RUNNER_DIR="$2"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1"; usage 1 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

LOG="${TMPDIR:-/tmp}/setup-macos-runner-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

RESULTS=""
PATH_CHANGED=0
C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'

step() { printf '\n%s== %s%s\n' "$C_CYAN" "$1" "$C_RESET"; }

# result NAME STATUS [DETAIL]; STATUS: OK, FIXED, MISSING (check-only), WARN (needs a person), FAILED
result() {
  local color="$C_GREEN"
  case "$2" in MISSING|WARN) color="$C_YELLOW" ;; FAILED) color="$C_RED" ;; esac
  printf '   %s[%s]%s %s %s\n' "$color" "$2" "$C_RESET" "$1" "${3:-}"
  RESULTS="${RESULTS}$2|$1|${3:-}"$'\n'
}

# fix NAME WHAT-IS-MISSING FUNCTION: runs FUNCTION unless --check-only; the last line of its output
# is the detail. FUNCTION returns non-zero on failure. It runs in this shell (so it can set
# variables); a FUNCTION that changes directory does it in a subshell.
FIX_OUT="$(mktemp)"
trap 'rm -f "$FIX_OUT"' EXIT
fix() {
  local name="$1" missing="$2" fn="$3" rc
  if [ "$CHECK_ONLY" = 1 ]; then result "$name" MISSING "$missing"; return 1; fi
  echo "   $name: $missing -> fixing..."
  "$fn" > "$FIX_OUT" 2>&1; rc=$?
  sed 's/^/      /' "$FIX_OUT"
  if [ "$rc" = 0 ]; then result "$name" FIXED "$(tail -n 1 "$FIX_OUT")"
  else result "$name" FAILED "$(tail -n 1 "$FIX_OUT")"; fi
  return "$rc"
}

have() { command -v "$1" >/dev/null 2>&1; }
ver_major() { printf '%s' "$1" | cut -d. -f1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]; }

BREW=""
find_brew() {
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then BREW="$b"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------

check_machine() {
  step "Machine"
  local os arch ram_gb cpus free_gb
  os="$(sw_vers -productVersion)"
  arch="$(uname -m)"
  if ver_ge "$os" 15.6; then result "macOS" OK "$os"
  else result "macOS" WARN "$os; Xcode $MIN_XCODE_MAJOR needs macOS 15.6 or later"; fi

  # The job builds for the machine's architecture. GitHub's macos-26 runners were arm64.
  if [ "$arch" = arm64 ]; then result "Architecture" OK "arm64 (Apple Silicon)"
  else result "Architecture" WARN "$arch: the build will be x86_64 only, not arm64 like the GitHub-hosted build"; fi

  ram_gb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  if [ "$ram_gb" -ge "$MIN_RAM_GB" ]; then result "RAM" OK "$ram_gb GB"
  else result "RAM" WARN "$ram_gb GB; at least $MIN_RAM_GB GB recommended"; fi
  cpus="$(sysctl -n hw.ncpu)"
  result "CPU" OK "$cpus logical cores"

  local d="$RUNNER_DIR"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
  free_gb=$(( $(df -k "$d" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if [ "$free_gb" -ge "$MIN_FREE_GB" ]; then result "Free space ($RUNNER_DIR)" OK "$free_gb GB"
  else result "Free space ($RUNNER_DIR)" WARN "$free_gb GB; about $MIN_FREE_GB GB needed"; fi
}

fix_no_sleep() { sudo pmset -c sleep 0 disksleep 0 && echo "pmset -c sleep 0 disksleep 0"; }
check_sleep() {
  step "Sleep"
  # A sleeping Mac drops the runner's connection and the build. Only on AC power: a laptop on
  # battery still sleeps.
  local s
  s="$(pmset -g custom | awk '/AC Power/ {ac=1} ac && $1=="sleep" {print $2; exit}')"
  if [ -z "$s" ]; then s="$(pmset -g | awk '$1=="sleep" {print $2; exit}')"; fi
  if [ "$s" = 0 ]; then result "No sleep on AC power" OK
  else fix "No sleep on AC power" "sleep after ${s:-?} min" fix_no_sleep; fi
}

xcode_version() { # version of the Xcode that xcode-select points to, or empty
  xcodebuild -version 2>/dev/null | awk '/^Xcode/ {print $2; exit}'
}

newest_xcode_app() { # path of the newest /Applications/Xcode*.app with major >= MIN_XCODE_MAJOR
  local app v best="" bestv="0"
  for app in /Applications/Xcode*.app; do
    [ -d "$app" ] || continue
    v="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)" || continue
    if [ "$(ver_major "$v")" -ge "$MIN_XCODE_MAJOR" ] && ver_ge "$v" "$bestv"; then best="$app"; bestv="$v"; fi
  done
  printf '%s' "$best"
}

XCODE_APP=""
fix_select_xcode() { sudo xcode-select -s "$XCODE_APP/Contents/Developer" && xcode-select -p; }
fix_xcode_license() { sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch && echo "accepted"; }
fix_metal() { xcodebuild -downloadComponent MetalToolchain && echo "installed"; }

check_xcode() {
  step "Xcode"
  local dev v
  dev="$(xcode-select -p 2>/dev/null)"
  v="$(xcode_version)"
  XCODE_APP="$(newest_xcode_app)"

  if [ -n "$v" ] && [ "$(ver_major "$v")" -ge "$MIN_XCODE_MAJOR" ] && [[ "$dev" == *.app/Contents/Developer ]]; then
    result "Xcode" OK "$v ($dev)"
  elif [ -n "$XCODE_APP" ]; then
    fix "Xcode selected" "xcode-select points to ${dev:-nothing} (Xcode ${v:-none})" fix_select_xcode
  else
    result "Xcode" FAILED "found ${v:-none} at ${dev:-nothing}; need Xcode $MIN_XCODE_MAJOR+: install it from the App Store (or 'brew install xcodes && xcodes install --latest', which asks for an Apple ID), then run this script again"
    return
  fi
  v="$(xcode_version)"
  [ -n "$v" ] && [ "$(ver_major "$v")" -ge "$MIN_XCODE_MAJOR" ] || return

  # An unaccepted license makes every xcodebuild and clang call fail in the job.
  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 && xcrun clang --version >/dev/null 2>&1; then
    result "Xcode license and first launch" OK
  else
    fix "Xcode license and first launch" "not done" fix_xcode_license
  fi

  # Qt WebEngine 6.140 compiles Metal shaders; Xcode 26 ships the Metal toolchain separately. The
  # job downloads it too, but that fails without network access to Apple and costs time.
  if xcrun -f metal >/dev/null 2>&1 && xcrun metal --version >/dev/null 2>&1; then
    result "Metal toolchain" OK "$(xcrun -f metal)"
  else
    fix "Metal toolchain" "not installed" fix_metal
  fi
}

fix_brew() {
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
  find_brew && "$BREW" --version | head -n 1
}
PKG=""
fix_brew_pkg() { "$BREW" install "$PKG" && "$BREW" list --versions "$PKG"; }

check_brew() {
  step "Homebrew and tools"
  if find_brew; then result "Homebrew" OK "$("$BREW" --version | head -n 1) at $BREW"
  else fix "Homebrew" "not installed" fix_brew; find_brew || return; fi

  for PKG in $BREW_PACKAGES; do
    if "$BREW" list --versions "$PKG" >/dev/null 2>&1; then result "brew $PKG" OK "$("$BREW" list --versions "$PKG")"
    else fix "brew $PKG" "not installed" fix_brew_pkg; fi
  done
}

svc() { (cd "$RUNNER_DIR" && ./svc.sh "$@"); }
runner_running() { svc status 2>/dev/null | grep -q '^Started'; }

fix_register_runner() {
  local arch tag url
  case "$(uname -m)" in arm64) arch=arm64 ;; *) arch=x64 ;; esac
  tag="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$tag" ] || { echo "can't find the latest runner release"; return 1; }
  url="https://github.com/actions/runner/releases/download/v$tag/actions-runner-osx-$arch-$tag.tar.gz"
  mkdir -p "$RUNNER_DIR" || return 1
  if [ -f "$RUNNER_DIR/.runner" ]; then svc stop >/dev/null 2>&1; svc uninstall >/dev/null 2>&1; fi
  (cd "$RUNNER_DIR" && curl -fsSL "$url" | tar xz) || return 1
  (cd "$RUNNER_DIR" && ./config.sh --unattended --replace --url "$RUNNER_URL" --token "$RUNNER_TOKEN" \
    --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work) || return 1
  svc install && svc start || return 1
  echo "$RUNNER_NAME ($RUNNER_LABELS) in $RUNNER_DIR, v$tag"
}

fix_runner_path() {
  # The runner service takes PATH from the .path file written at configuration time.
  local p
  p="$(cat "$RUNNER_DIR/.path")"
  printf '%s:%s\n' "$(dirname "$BREW")" "$p" > "$RUNNER_DIR/.path" || return 1
  PATH_CHANGED=1
  cat "$RUNNER_DIR/.path"
}
fix_runner_start() { svc start >/dev/null && runner_running && echo "started"; }

check_runner() {
  step "GitHub Actions runner"
  if [ -n "$RUNNER_TOKEN" ]; then
    fix "Runner registration" "registering $RUNNER_NAME with labels $RUNNER_LABELS" fix_register_runner
  fi
  if [ ! -f "$RUNNER_DIR/.runner" ]; then
    result "Runner" "$([ "$CHECK_ONLY" = 1 ] && echo MISSING || echo WARN)" \
      "not configured in $RUNNER_DIR; run again with --runner-token <token> (repo Settings > Actions > Runners > New self-hosted runner), labels: $RUNNER_LABELS"
    return
  fi
  result "Runner" OK "$RUNNER_DIR ($(sed -n 's/.*"agentName": *"\([^"]*\)".*/\1/p' "$RUNNER_DIR/.runner" | head -n 1))"

  # The runner is a LaunchAgent: it only runs while its user is logged in.
  local user
  user="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
  if [ "$user" = "$(id -un)" ]; then result "Automatic login" OK "$user"
  else result "Automatic login" WARN "${user:-off}; the runner (a LaunchAgent) stops when $(id -un) is logged out. Turn on automatic login for $(id -un) in System Settings > Users & Groups"; fi

  if [ -n "$BREW" ] && [ -f "$RUNNER_DIR/.path" ]; then
    if tr ':' '\n' < "$RUNNER_DIR/.path" | grep -qx "$(dirname "$BREW")"; then result "Homebrew on the runner's PATH" OK
    else fix "Homebrew on the runner's PATH" "$(dirname "$BREW") not in $RUNNER_DIR/.path" fix_runner_path; fi
  fi

  if runner_running; then
    result "Runner service" OK "running"
    if [ "$PATH_CHANGED" = 1 ]; then
      if pgrep -f Runner.Worker >/dev/null; then
        result "Runner restart" WARN "PATH changed but a job is running; run 'cd $RUNNER_DIR && ./svc.sh stop && ./svc.sh start' after it"
      elif svc stop >/dev/null && svc start >/dev/null; then
        result "Runner restart" FIXED "restarted to pick up the new PATH"
      else
        result "Runner restart" FAILED "svc.sh stop/start failed"
      fi
    fi
  else
    fix "Runner service" "not running" fix_runner_start
  fi
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

if [ "$(id -u)" = 0 ]; then echo "Run this as the runner's user, not root (it uses sudo where needed)."; exit 1; fi
echo "Qt WebEngine macOS runner setup$([ "$CHECK_ONLY" = 1 ] && echo ' (check only)')"
if [ "$CHECK_ONLY" = 0 ]; then sudo -v || { echo "sudo is needed"; exit 1; }; fi

check_machine
check_sleep
check_xcode
check_brew
check_runner

step "Summary"
printf '%s' "$RESULTS" | awk -F'|' '{printf "   %-8s %-34s %s\n", $1, $2, $3}'
echo "Log: $LOG"
printf '%s' "$RESULTS" | grep -qE '^(FAILED|MISSING)\|' && exit 2
exit 0
