## Scripts: Agent User Bootstrap

These scripts create or purge a generic "agent" user for initial bootstrap on a host.

### Quick start (get and run)

From your admin machine, copy the scripts to a new host and run the add script:

  scp /path/to/repo/scripts/*.sh root@NEW_HOST:/root/
  ssh root@NEW_HOST
  chmod +x /root/*.sh
  /root/add_agent_user.sh --username agent --pubkey "ssh-ed25519 AAAA... user@host"

### Simple new machine prep

- Ensure basic connectivity (DNS, outbound apt access).
- Copy and run `add_agent_user.sh` as shown above.
- Test login with the new key, then disable direct root SSH if required by policy.

### add_agent_user.sh

Create an agent login user, install an SSH public key, and set minimal privileges.

Usage:

  sudo ./add_agent_user.sh --pubkey "<ssh-public-key>" [--username <name>]
  sudo ./add_agent_user.sh --pubkey-file /path/to/key.pub [--username <name>]

Options:

  --username <name>       Username to create (required if non-interactive)
  --pubkey "<key>"        SSH public key line to install
  --pubkey-file <path>    File containing the SSH public key
  --skip-update           Skip apt update
  --do-upgrade            Run apt upgrade (default: no)
  --skip-upgrade          Skip apt upgrade (default)
  -h, --help              Show help

Notes:

- If no username or pubkey is provided, the script will prompt in interactive mode.
- OpenSSH server is installed only if missing.
- The account password is locked; SSH key auth is required.

### purge_agent_user.sh

Purge an agent login user and cleanup related artifacts.

Usage:

  sudo ./purge_agent_user.sh <username> [--dry-run] [--force] [--remove-key "<ssh-public-key>"]

Options:

  --dry-run                  Show actions without changing anything
  --force                    Try harder (aggressive kill; ignore some failures)
  --remove-key "<pubkey>"    Remove this exact SSH public key line from all users' ~/.ssh/authorized_keys
  -h, --help                 Show help

### SECURITY NOTICE

- No credentials are stored in this repository.
- SSH keys must be provided at runtime.
- These scripts are intended for initial bootstrap only.
- Report security issues via private contact.
