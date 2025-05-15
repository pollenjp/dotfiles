# shellcheck shell=bash

# ssh-agent
# <https://himadatanode.hatenablog.com/entry/20160823/p14>
SSH_AGENT_FILE="${HOME}"/.ssh-agent
# shellcheck disable=SC1090
test -f "$SSH_AGENT_FILE" && source "${SSH_AGENT_FILE}"
if ! ssh-add -l >/dev/null 2>&1; then
  ssh-agent >"${SSH_AGENT_FILE}"
  # shellcheck disable=SC1090
  source "${SSH_AGENT_FILE}"

  if [ -f "${HOME}"/.ssh/id_ed25519 ]; then
    ssh-add "${HOME}"/.ssh/id_ed25519
  fi
fi
