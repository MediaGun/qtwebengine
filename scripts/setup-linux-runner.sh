#!/bin/bash
# Prepares an Ubuntu/Debian machine as the self-hosted GitHub Actions runner that builds Qt WebEngine
# ("Build for Linux" in .github/workflows/build.yaml, runner label linux-we-builder).
#
# Checks everything the job needs, installs or configures what is missing, and prints a summary.
# Safe to run again. Run it as the user the runner runs as (not root); it asks for sudo when needed.
#
#   ./setup-linux-runner.sh --check-only              # only report
#   ./setup-linux-runner.sh                           # install and configure
#   ./setup-linux-runner.sh --runner-token AAAA...    # also register the runner
#
# Not installed here, the job's actions download them: Node.js, CMake, Python, Qt.

set -uo pipefail

CHECK_ONLY=0
RUNNER_URL="https://github.com/MediaGun/qtwebengine"
RUNNER_TOKEN=""
RUNNER_NAME="$(hostname -s)"
RUNNER_LABELS="linux-we-builder"
RUNNER_DIR="$HOME/actions-runner"
RUNNER_USER="$(id -un)"
MIN_FREE_GB=150
MIN_RAM_GB=32

# The job's "Install dependencies" step (keep in sync with build.yaml), plus ccache (the job's
# ccache action would otherwise install it itself) and what the runner and this script use.
APT_PACKAGES="
  bison build-essential flex git gperf
  libasound2-dev libatspi2.0-dev libavcodec-dev libavformat-dev libavutil-dev libcups2-dev libgbm-dev
  libdbus-1-dev libdrm-dev libegl1-mesa-dev libevent-dev libfontconfig1-dev libfreetype6-dev libicu-dev libjsoncpp-dev libminizip-dev
  libnss3-dev libopus-dev libpci-dev libprotobuf-dev libpulse-dev libre2-dev libsnappy-dev libsrtp2-dev libssl-dev libudev-dev libvpx-dev
  libwebp-dev libx11-dev libx11-xcb-dev libxcb-glx0-dev libxcb-icccm4-dev libxcb-image0-dev libxcb-keysyms1-dev libxcb-randr0-dev
  libxcb-render-util0-dev libxcb-shape0-dev libxcb-shm0-dev libxcb-sync0-dev libxcb-util-dev libxcb-xfixes0-dev libxcb-xinerama0-dev
  libxcb-xkb-dev libxcb1-dev libxcomposite-dev libxcursor-dev libxdamage-dev libxext-dev libxfixes-dev libxi-dev libxkbcommon-dev
  libxkbcommon-x11-dev libxkbfile-dev libxrandr-dev libxrender-dev libxshmfence-dev libxss-dev libxtst-dev
  ninja-build protobuf-compiler
  ccache pkg-config python3 python3-pip python3-html5lib
  curl ca-certificates tar zip unzip
"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
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

LOG="${TMPDIR:-/tmp}/setup-linux-runner-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

RESULTS=""
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
  sed 's/^/      /' "$FIX_OUT" | tail -n 40
  if [ "$rc" = 0 ]; then result "$name" FIXED "$(tail -n 1 "$FIX_OUT")"
  else result "$name" FAILED "$(tail -n 1 "$FIX_OUT")"; fi
  return "$rc"
}

# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------

check_machine() {
  step "Machine"
  local id ver arch ram_gb free_gb
  id="$(. /etc/os-release && echo "$ID")"
  ver="$(. /etc/os-release && echo "$VERSION_ID")"
  arch="$(uname -m)"
  if [ "$id" = ubuntu ] && [ "$ver" = 24.04 ]; then result "OS" OK "Ubuntu $ver"
  elif command -v apt-get >/dev/null; then result "OS" WARN "$id $ver; the job was written for Ubuntu 24.04 (package names may differ)"
  else result "OS" FAILED "$id $ver; the job installs packages with apt-get"; fi
  if [ "$arch" = x86_64 ]; then result "Architecture" OK "$arch"
  else result "Architecture" WARN "$arch; the GitHub-hosted build was x86_64"; fi

  ram_gb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
  if [ "$ram_gb" -ge "$MIN_RAM_GB" ]; then result "RAM" OK "$ram_gb GB"
  else result "RAM" WARN "$ram_gb GB; at least $MIN_RAM_GB GB recommended (or add swap)"; fi
  result "CPU" OK "$(nproc) logical cores"

  local d="$RUNNER_DIR"; while [ ! -d "$d" ]; do d="$(dirname "$d")"; done
  free_gb=$(( $(df -Pk "$d" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
  if [ "$free_gb" -ge "$MIN_FREE_GB" ]; then result "Free space ($RUNNER_DIR)" OK "$free_gb GB"
  else result "Free space ($RUNNER_DIR)" WARN "$free_gb GB; about $MIN_FREE_GB GB needed"; fi
}

SUDOERS_FILE="/etc/sudoers.d/github-runner-$RUNNER_USER"
fix_sudoers() {
  # Only apt-get, which the job's "Install dependencies" step and the ccache action run with sudo.
  local tmp
  tmp="$(mktemp)"
  printf '%s ALL=(root) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt\n' "$RUNNER_USER" > "$tmp"
  sudo visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; echo "visudo rejected the rule"; return 1; }
  sudo install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE" && rm -f "$tmp" && echo "$SUDOERS_FILE"
}

check_sudo() {
  step "sudo for the job"
  # The job runs "sudo apt-get ..." and can't type a password.
  if sudo -n -l /usr/bin/apt-get >/dev/null 2>&1; then result "Passwordless sudo apt-get" OK
  else fix "Passwordless sudo apt-get" "the job's 'sudo apt-get' would ask for a password" fix_sudoers; fi
}

MISSING_PKGS=""
fix_apt() { sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING_PKGS && echo "installed:$MISSING_PKGS"; }

check_packages() {
  step "Packages"
  local p
  MISSING_PKGS=""
  for p in $APT_PACKAGES; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || MISSING_PKGS="$MISSING_PKGS $p"
  done
  if [ -z "$MISSING_PKGS" ]; then result "apt packages" OK "$(echo $APT_PACKAGES | wc -w) packages"
  else fix "apt packages" "missing:$MISSING_PKGS" fix_apt; fi
}

fix_inotify() {
  printf 'fs.inotify.max_user_watches=524288\nfs.file-max=2097152\n' | sudo tee /etc/sysctl.d/90-github-runner.conf >/dev/null \
    && sudo sysctl --system >/dev/null && echo "/etc/sysctl.d/90-github-runner.conf"
}

check_limits() {
  step "Kernel limits"
  # Chromium's build opens many files at once.
  local w
  w="$(cat /proc/sys/fs/inotify/max_user_watches)"
  if [ "$w" -ge 524288 ]; then result "inotify watches / file-max" OK "$w"
  else fix "inotify watches / file-max" "max_user_watches=$w" fix_inotify; fi
}

svc() { (cd "$RUNNER_DIR" && sudo ./svc.sh "$@"); }
runner_unit() { systemctl list-units --all --plain --no-legend 'actions.runner.*' 2>/dev/null | awk '{print $1}' | head -n 1; }

fix_register_runner() {
  local tag url
  tag="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$tag" ] || { echo "can't find the latest runner release"; return 1; }
  url="https://github.com/actions/runner/releases/download/v$tag/actions-runner-linux-x64-$tag.tar.gz"
  mkdir -p "$RUNNER_DIR" || return 1
  if [ -f "$RUNNER_DIR/.runner" ]; then svc stop >/dev/null 2>&1; svc uninstall >/dev/null 2>&1; fi
  (cd "$RUNNER_DIR" && curl -fsSL "$url" | tar xz) || return 1
  (cd "$RUNNER_DIR" && sudo ./bin/installdependencies.sh) || return 1
  (cd "$RUNNER_DIR" && ./config.sh --unattended --replace --url "$RUNNER_URL" --token "$RUNNER_TOKEN" \
    --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work) || return 1
  svc install "$RUNNER_USER" && svc start || return 1
  echo "$RUNNER_NAME ($RUNNER_LABELS) in $RUNNER_DIR, v$tag"
}
fix_runner_start() { local u; u="$(runner_unit)"; sudo systemctl enable --now "$u" && systemctl is-active "$u"; }

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
  # The label lives on GitHub, not in local files; check it in Settings > Actions > Runners.

  local unit
  unit="$(runner_unit)"
  if [ -z "$unit" ]; then
    result "Runner service" "$([ "$CHECK_ONLY" = 1 ] && echo MISSING || echo WARN)" "no systemd unit; run 'cd $RUNNER_DIR && sudo ./svc.sh install $RUNNER_USER && sudo ./svc.sh start'"
  elif [ "$(systemctl is-active "$unit")" = active ] && [ "$(systemctl is-enabled "$unit" 2>/dev/null)" = enabled ]; then
    result "Runner service" OK "$unit, runs as $(systemctl show -p User --value "$unit")"
  else
    fix "Runner service" "$unit is $(systemctl is-active "$unit")/$(systemctl is-enabled "$unit" 2>/dev/null)" fix_runner_start
  fi
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

if [ "$(id -u)" = 0 ]; then echo "Run this as the runner's user, not root (it uses sudo where needed)."; exit 1; fi
echo "Qt WebEngine Linux runner setup$([ "$CHECK_ONLY" = 1 ] && echo ' (check only)')"
if [ "$CHECK_ONLY" = 0 ]; then sudo -v || { echo "sudo is needed"; exit 1; }; fi

check_machine
check_sudo
check_packages
check_limits
check_runner

step "Summary"
printf '%s' "$RESULTS" | awk -F'|' '{printf "   %-8s %-34s %s\n", $1, $2, $3}'
echo "Log: $LOG"
printf '%s' "$RESULTS" | grep -qE '^(FAILED|MISSING)\|' && exit 2
exit 0
