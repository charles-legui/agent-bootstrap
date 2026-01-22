#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo ./add_agent_user.sh --pubkey "<ssh-public-key>" [--username <name>]
  sudo ./add_agent_user.sh --pubkey-file /path/to/key.pub [--username <name>]

Options:
  --username <name>       Username to create
  --pubkey "<key>"        SSH public key line to install
  --pubkey-file <path>    File containing the SSH public key
  --skip-update           Skip apt update
  --do-upgrade            Run apt upgrade (default: no)
  --skip-upgrade          Skip apt upgrade (default)
  -h, --help              Show help
EOF
}

USERNAME=""
PUBKEY=""
PUBKEY_FILE=""
USERNAME_PROVIDED=0
PUBKEY_PROVIDED=0
PUBKEY_FILE_PROVIDED=0
SKIP_UPDATE=0
SKIP_UPGRADE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) USERNAME="${2:-}"; USERNAME_PROVIDED=1; shift 2 ;;
    --pubkey) PUBKEY="${2:-}"; PUBKEY_PROVIDED=1; shift 2 ;;
    --pubkey-file) PUBKEY_FILE="${2:-}"; PUBKEY_FILE_PROVIDED=1; shift 2 ;;
    --skip-update) SKIP_UPDATE=1; shift ;;
    --skip-upgrade) SKIP_UPGRADE=1; shift ;;
    --do-upgrade) SKIP_UPGRADE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: Run as root (sudo)." >&2
  exit 1
fi

if [[ $USERNAME_PROVIDED -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo "ERROR: --username is required when not running interactively." >&2
    exit 1
  fi
  read -r -p "Username [${USERNAME}]: " INPUT_USERNAME
  if [[ -n "$INPUT_USERNAME" ]]; then
    USERNAME="$INPUT_USERNAME"
  fi
fi

normalize_pubkey() {
  local key="${1:-}"
  printf '%s\n' "$key" | tr -d '\r' | sed -n '/^[[:space:]]*$/d;1p'
}

if [[ -z "$PUBKEY" && -n "$PUBKEY_FILE" ]]; then
  if [[ ! -f "$PUBKEY_FILE" ]]; then
    echo "ERROR: pubkey file not found: $PUBKEY_FILE" >&2
    exit 1
  fi
  PUBKEY="$(normalize_pubkey "$(cat "$PUBKEY_FILE")")"
else
  PUBKEY="$(normalize_pubkey "$PUBKEY")"
fi

if [[ $PUBKEY_PROVIDED -eq 0 && $PUBKEY_FILE_PROVIDED -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo "ERROR: --pubkey or --pubkey-file is required when not running interactively." >&2
    exit 1
  fi
  read -r -p "SSH public key: " INPUT_PUBKEY
  PUBKEY="$(normalize_pubkey "$INPUT_PUBKEY")"
fi

if [[ -z "$PUBKEY" ]]; then
  echo "ERROR: Provide --pubkey or --pubkey-file." >&2
  exit 1
fi

if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "ERROR: Invalid username format." >&2
  exit 1
fi

if [[ $SKIP_UPDATE -eq 0 ]]; then
  apt update
fi

if [[ $SKIP_UPGRADE -eq 0 ]]; then
  apt -y upgrade
fi

if ! dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q "install ok installed"; then
  apt -y install openssh-server
  if command -v systemctl &>/dev/null; then
    systemctl enable --now ssh &>/dev/null || systemctl enable --now sshd &>/dev/null || true
  fi
fi

if ! id "$USERNAME" &>/dev/null; then
  useradd -m -s /bin/bash "$USERNAME"
fi
passwd -l "$USERNAME" &>/dev/null || true
chage -E -1 -M -1 "$USERNAME" &>/dev/null || true

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
if [[ -z "$USER_HOME" || "$USER_HOME" == "/" ]]; then
  echo "ERROR: Invalid home directory for user: $USERNAME" >&2
  exit 1
fi
SSH_DIR="$USER_HOME/.ssh"
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$SSH_DIR"
if [[ ! -f "$AUTHORIZED_KEYS" ]]; then
  install -m 600 -o "$USERNAME" -g "$USERNAME" /dev/null "$AUTHORIZED_KEYS"
fi
if ! grep -Fxq "$PUBKEY" "$AUTHORIZED_KEYS"; then
  printf '%s\n' "$PUBKEY" >>"$AUTHORIZED_KEYS"
fi
chown "$USERNAME:$USERNAME" "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

SUDOERS_FILE="/etc/sudoers.d/$USERNAME"
printf '%s\n' "$USERNAME ALL=(ALL) NOPASSWD:ALL" >"$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"

echo "User '$USERNAME' created/updated and SSH key installed."
