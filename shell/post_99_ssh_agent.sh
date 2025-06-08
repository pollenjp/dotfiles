# shellcheck shell=bash

# ssh-agent
# <https://himadatanode.hatenablog.com/entry/20160823/p14>
SSH_AGENT_FILE="${HOME}"/.ssh-agent

# If already ssh-agent is running, use it (do nothing).
# ex) 1password ssh-agent

# If ssh-agent has not been started
# and SSH_AGENT_FILE exists, load it.
# (Its agent may not exist anymore)
if ! ssh-add -l >/dev/null 2>&1 && test -f "$SSH_AGENT_FILE"; then
  # shellcheck disable=SC1090
  source "${SSH_AGENT_FILE}"
fi

# If the ssh-agent is not working, start it and add the key.
if ! ssh-add -l >/dev/null 2>&1; then
  ssh-agent >"${SSH_AGENT_FILE}"
  # shellcheck disable=SC1090
  source "${SSH_AGENT_FILE}"

  if [ -f "${HOME}"/.ssh/id_ed25519 ]; then
    ssh-add "${HOME}"/.ssh/id_ed25519
  fi
fi
