#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo ./purge_agent_user.sh <username> [--dry-run] [--force] [--remove-key "<ssh-public-key>"]

Options:
  --dry-run                  Show actions without changing anything
  --force                    Try harder (aggressive kill; ignore some failures)
  --remove-key "<pubkey>"    Remove this exact SSH public key line from all users' ~/.ssh/authorized_keys
                             (use only if you re-used the same key in multiple accounts)
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi

USERNAME=""
DRY_RUN=0
FORCE=0
REMOVE_KEY=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --remove-key)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --remove-key needs a value"; exit 1; }
      REMOVE_KEY="$1"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$USERNAME" ]]; then USERNAME="$1"; shift
      else echo "Unknown arg: $1"; usage; exit 1
      fi
      ;;
  esac
done

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    echo
  else
    "$@"
  fi
}

# Must be root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: Run as root (sudo)." >&2
  exit 1
fi

# Validate target
if ! id "$USERNAME" &>/dev/null; then
  echo "ERROR: User '$USERNAME' does not exist." >&2
  exit 1
fi
if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "ERROR: Invalid username format." >&2
  exit 1
fi
if [[ "$USERNAME" == "root" ]]; then
  echo "ERROR: Refusing to delete root." >&2
  exit 1
fi

CURRENT_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [[ -n "${CURRENT_USER:-}" && "$USERNAME" == "$CURRENT_USER" ]]; then
  echo "ERROR: Refusing to delete the currently logged-in user ('$CURRENT_USER')." >&2
  exit 1
fi

USER_UID="$(id -u "$USERNAME")"
USER_GID="$(id -g "$USERNAME")"
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
PRIMARY_GROUP="$(getent group "$USER_GID" | cut -d: -f1 || true)"

echo "Purging agent login user: $USERNAME (uid=$USER_UID home=$USER_HOME)"
if [[ $DRY_RUN -eq 0 ]]; then
  read -r -p "Type the username to confirm: " CONFIRM
  [[ "$CONFIRM" == "$USERNAME" ]] || { echo "Aborted."; exit 1; }
fi

# 1) Kill processes
echo "Stopping processes owned by $USERNAME..."
if [[ $FORCE -eq 1 ]]; then
  run pkill -KILL -u "$USERNAME" || true
else
  run pkill -TERM -u "$USERNAME" || true
  sleep 1 || true
  run pkill -KILL -u "$USERNAME" || true
fi

# 2) Remove sudoers drop-ins
echo "Removing sudoers drop-ins..."
run rm -f "/etc/sudoers.d/$USERNAME" 2>/dev/null || true
# Remove files in sudoers.d that mention the username (best-effort; safe because sudoers.d should contain only small drop-ins)
run grep -RIl --exclude='README' --exclude='*~' -e "\\b$USERNAME\\b" /etc/sudoers.d 2>/dev/null | xargs -r rm -f || true

# 3) Remove cron/at (rare for agent, but safe)
echo "Removing scheduled jobs (cron/at)..."
run crontab -r -u "$USERNAME" 2>/dev/null || true
run rm -f "/var/spool/cron/crontabs/$USERNAME" 2>/dev/null || true
if command -v atrm &>/dev/null && command -v atq &>/dev/null; then
  run bash -c "for j in \$(atq 2>/dev/null | awk -v u='$USERNAME' '\$2==u{print \$1}'); do atrm \"\$j\" || true; done"
fi

# 4) systemd lingering
echo "Disabling systemd lingering..."
run loginctl disable-linger "$USERNAME" 2>/dev/null || true
run rm -f "/var/lib/systemd/linger/$USERNAME" 2>/dev/null || true

# 5) Optionally remove a shared public key from all users
if [[ -n "$REMOVE_KEY" ]]; then
  echo "Removing provided SSH public key from all users' authorized_keys..."
  # Remove exact matching lines only, without eval or shell interpolation.
  while IFS= read -r -d '' AUTH_FILE; do
    if grep -Fqx -- "$REMOVE_KEY" "$AUTH_FILE"; then
      TMP_FILE="$(mktemp)"
      grep -Fvx -- "$REMOVE_KEY" "$AUTH_FILE" >"$TMP_FILE"
      run mv -f "$TMP_FILE" "$AUTH_FILE"
    fi
  done < <(find /home /root -maxdepth 3 -type f -path '*/.ssh/authorized_keys' 2>/dev/null -print0)
fi

# 6) Delete the user and its home
echo "Deleting user account and home directory..."
if [[ $FORCE -eq 1 ]]; then
  run userdel -r -f "$USERNAME" || true
else
  run userdel -r "$USERNAME"
fi

# 7) Extra cleanup for SSH artifacts in its home (if userdel -r didn't remove for some reason)
echo "Cleaning leftover paths..."
run rm -rf "/var/mail/$USERNAME" 2>/dev/null || true
run rm -rf "/var/spool/mail/$USERNAME" 2>/dev/null || true
run rm -rf "/run/user/$USER_UID" 2>/dev/null || true
if [[ -n "${USER_HOME:-}" && "$USER_HOME" != "/" && "$USER_HOME" != "/root" ]]; then
  run rm -rf --one-file-system "$USER_HOME" 2>/dev/null || true
fi

# 8) Remove primary group if it matches username and is empty (common Ubuntu behavior)
if [[ -n "${PRIMARY_GROUP:-}" && "$PRIMARY_GROUP" == "$USERNAME" ]]; then
  if getent group "$PRIMARY_GROUP" >/dev/null; then
    MEMBERS="$(getent group "$PRIMARY_GROUP" | awk -F: '{print $4}')"
    if [[ -z "$MEMBERS" ]]; then
      echo "Removing empty group: $PRIMARY_GROUP"
      run groupdel "$PRIMARY_GROUP" 2>/dev/null || true
    fi
  fi
fi

echo "Done. '$USERNAME' removed (agent account purge complete)."
if [[ $DRY_RUN -eq 1 ]]; then
  echo "This was a dry-run. Re-run without --dry-run to apply."
fi
