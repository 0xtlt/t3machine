#!/usr/bin/env bash
# t3machine: set up (or update) a Debian/Ubuntu server for T3 Code.
#
# Run as root. Safe to run again: the first run installs everything, later
# runs update it.
#
#   ssh root@<host> 'bash -s' < setup.sh
#   curl -fsSL https://raw.githubusercontent.com/0xtlt/t3machine/main/setup.sh | sudo bash
#
# Environment:
#   T3_USER          user that runs T3 Code (default: t3)
#   APT_UPGRADE      1 to run `apt-get upgrade` first (default: 0)
#   T3MACHINE_REF    git ref used to fetch mise.toml (default: main)
#   MISE_CONFIG_SRC  local path or URL of the mise config template
#                    (default: mise.toml next to this script, else GitHub)
#   T3CODE_CHANNEL   T3 Code release train for the first install (default: stable)

set -euo pipefail

T3_USER="${T3_USER:-t3}"
APT_UPGRADE="${APT_UPGRADE:-0}"
T3MACHINE_REF="${T3MACHINE_REF:-main}"
T3MACHINE_RAW="https://raw.githubusercontent.com/0xtlt/t3machine/${T3MACHINE_REF}"
MARK_BEGIN="# >>> t3machine >>>"
MARK_END="# <<< t3machine <<<"

# ---------------------------------------------------------------- logging
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_RED=$'\033[31m'
else
  C_RESET='' C_BOLD='' C_BLUE='' C_GREEN='' C_YELLOW='' C_RED=''
fi
step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s✘ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# ---------------------------------------------------------------- checks
[[ "$(id -u)" -eq 0 ]] || die "Run this script as root (or with sudo)."
command -v apt-get >/dev/null 2>&1 || die "Only Debian/Ubuntu (apt) is supported."
[[ "$T3_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid T3_USER: $T3_USER"
[[ "$T3_USER" != root ]] || die "T3 Code must not run as root; pick another T3_USER."

HAS_SYSTEMD=0
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
  HAS_SYSTEMD=1
fi

# ---------------------------------------------------------------- apt base
step "System packages (apt)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
if [[ "$APT_UPGRADE" == 1 ]]; then
  info "APT_UPGRADE=1: upgrading installed packages"
  apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
fi
base_pkgs=(ca-certificates curl git tar gzip xz-utils zstd unzip procps)
if [[ "$HAS_SYSTEMD" == 1 ]]; then
  base_pkgs+=(dbus-user-session)
fi
apt-get install -y -qq --no-install-recommends "${base_pkgs[@]}" >/dev/null
ok "base packages: ${base_pkgs[*]}"

# ---------------------------------------------------------------- user
step "User '$T3_USER'"
if id "$T3_USER" >/dev/null 2>&1; then
  ok "already exists"
else
  useradd --create-home --shell /bin/bash "$T3_USER"
  passwd -l "$T3_USER" >/dev/null
  ok "created (password login disabled)"
fi
T3_UID="$(id -u "$T3_USER")"
T3_HOME="$(getent passwd "$T3_USER" | cut -d: -f6)"
[[ -d "$T3_HOME" ]] || die "Home directory $T3_HOME is missing."
RUNTIME_DIR="/run/user/$T3_UID"

if [[ "$HAS_SYSTEMD" == 1 ]]; then
  loginctl enable-linger "$T3_USER"
  systemctl start "user@${T3_UID}.service"
  for _ in $(seq 1 50); do
    [[ -S "$RUNTIME_DIR/bus" ]] && break
    sleep 0.2
  done
  [[ -S "$RUNTIME_DIR/bus" ]] || warn "user bus $RUNTIME_DIR/bus not found yet"
  ok "linger enabled, user@${T3_UID}.service running"
else
  warn "systemd is not running (container?): skipping linger and the T3 service"
fi

# Run a command as the T3 user in a login shell (sources ~/.profile).
as_user() {
  local -a envs=("HOME=$T3_HOME" "USER=$T3_USER" "LOGNAME=$T3_USER" "SHELL=/bin/bash"
    "PATH=/usr/local/bin:/usr/bin:/bin" "LANG=${LANG:-C.UTF-8}")
  if [[ "$HAS_SYSTEMD" == 1 ]]; then
    envs+=("XDG_RUNTIME_DIR=$RUNTIME_DIR" "DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus")
  fi
  [[ -n "${T3CODE_CHANNEL:-}" ]] && envs+=("T3CODE_CHANNEL=$T3CODE_CHANNEL")
  (cd "$T3_HOME" && runuser -u "$T3_USER" -- env -i "${envs[@]}" bash -lc "$1")
}

# Replace (or append) the t3machine block in a file owned by the T3 user.
write_block() {
  local file="$1" body="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }' "$file" > "$tmp"
  fi
  printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$body" "$MARK_END" >> "$tmp"
  install -o "$T3_USER" -g "$(id -gn "$T3_USER")" -m 0644 "$tmp" "$file"
  rm -f "$tmp"
}

# ---------------------------------------------------------------- shell PATH
step "Login shell PATH"
# shellcheck disable=SC2016 # expanded later by the user's shell
write_block "$T3_HOME/.profile" 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
if [ -x "$HOME/.local/bin/mise" ]; then
  eval "$("$HOME/.local/bin/mise" activate bash --shims)"
fi'
# shellcheck disable=SC2016
write_block "$T3_HOME/.bashrc" 'if [ -x "$HOME/.local/bin/mise" ]; then
  eval "$("$HOME/.local/bin/mise" activate bash)"
fi'
ok "$T3_HOME/.profile (shims) and $T3_HOME/.bashrc (mise activate) up to date"

# ---------------------------------------------------------------- mise
step "mise"
if as_user 'test -x ~/.local/bin/mise'; then
  as_user 'mise self-update -y' || warn "mise self-update failed, keeping the current version"
  ok "updated"
else
  as_user 'curl -fsSL https://mise.run | sh'
  ok "installed"
fi

step "mise config"
conf_dir="$T3_HOME/.config/mise/conf.d"
install -d -o "$T3_USER" -g "$(id -gn "$T3_USER")" "$T3_HOME/.config" "$T3_HOME/.config/mise" "$conf_dir"
script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
src="${MISE_CONFIG_SRC:-}"
if [[ -z "$src" ]]; then
  if [[ -n "$script_dir" && -f "$script_dir/mise.toml" ]]; then
    src="$script_dir/mise.toml"
  else
    src="$T3MACHINE_RAW/mise.toml"
  fi
fi
tmp_conf="$(mktemp)"
if [[ "$src" =~ ^https?:// ]]; then
  curl -fsSL "$src" -o "$tmp_conf" || die "Could not download $src"
else
  cp "$src" "$tmp_conf"
fi
install -o "$T3_USER" -g "$(id -gn "$T3_USER")" -m 0644 "$tmp_conf" "$conf_dir/t3machine.toml"
rm -f "$tmp_conf"
ok "$conf_dir/t3machine.toml (from $src)"

step "mise bootstrap packages"
# apt needs root, and the T3 user has no sudo: run the user's mise as root,
# pointed at the user's config directory.
BOOTSTRAP_STATE="$T3_HOME/.local/state/t3machine/bootstrapped"
as_root_mise() {
  (cd / && env MISE_CONFIG_DIR="$T3_HOME/.config/mise" "$T3_HOME/.local/bin/mise" "$@")
}
as_root_mise bootstrap packages apply --update --yes
if [[ -f "$BOOTSTRAP_STATE" ]]; then
  as_root_mise bootstrap packages upgrade --yes
  ok "packages applied and upgraded"
else
  ok "packages applied"
fi

step "mise tools"
as_user 'mise install --yes'
if [[ -f "$BOOTSTRAP_STATE" ]]; then
  as_user 'mise upgrade --yes'
fi
as_user 'mise reshim'
ok "tools installed"

# ---------------------------------------------------------------- T3 Code
step "T3 Code"
if as_user 'test -x ~/.local/bin/t3'; then
  if [[ "$HAS_SYSTEMD" == 1 ]]; then
    as_user 't3 update --yes'
  else
    as_user 't3 update --yes' || warn "t3 update could not finish without systemd"
  fi
  ok "updated"
else
  as_user 'curl -fsSL https://t3.codes/install.sh | sh'
  ok "installed"
fi

if [[ "$HAS_SYSTEMD" == 1 ]]; then
  # Installs, or repairs an existing service. Run from a login shell so the
  # service gets the PATH with mise shims.
  as_user 't3 service install'
  if as_user 't3 service status' 2>&1 | grep -q 'restart-pending'; then
    as_user 't3 service restart'
  fi
  as_user 't3 service status' || warn "t3 service status reported a problem"
fi

as_user 'mkdir -p ~/.local/state/t3machine && touch ~/.local/state/t3machine/bootstrapped'

# ---------------------------------------------------------------- summary
step "Summary"
# shellcheck disable=SC2016 # expanded by the user's shell
as_user '
  printf "    %-6s %s\n" user "$(id -un) (uid $(id -u))"
  printf "    %-6s %s\n" mise "$(mise --version 2>/dev/null | head -n1)"
  printf "    %-6s %s\n" t3 "$(t3 --version 2>/dev/null | head -n1)"
  printf "    %-6s %s\n" node "$(node --version 2>/dev/null)"
  printf "    %-6s %s\n" gh "$(gh --version 2>/dev/null | head -n1)"
  printf "    %-6s %s\n" shims "$(command -v node)"
'
if [[ "$HAS_SYSTEMD" == 0 ]]; then
  warn "T3 service not installed (no systemd). On a real server, run this script again."
fi

cat <<NEXT

${C_BOLD}Next steps${C_RESET} (interactive, run them yourself):
  1. Become the user:          su - $T3_USER
  2. Install a provider, e.g.: curl -fsSL https://claude.ai/install.sh | bash
     then log in:              claude auth login
  3. Pair your devices:        t3 pair --tailscale
     (the link works like a password: do not share or screenshot it)

${C_GREEN}Done.${C_RESET} Run the same command again any time to update everything.
NEXT
