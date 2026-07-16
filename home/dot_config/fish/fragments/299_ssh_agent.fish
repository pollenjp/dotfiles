# SSH agent management

set -l SSH_AGENT_FILE "$HOME/.ssh-agent"

# If ssh-agent is already working (e.g., 1password), do nothing.
# If not, try loading saved agent info.
if not ssh-add -l >/dev/null 2>&1; and test -f $SSH_AGENT_FILE
  # Parse the SSH_AGENT_FILE (which contains bash-style exports)
  # Extract SSH_AUTH_SOCK and SSH_AGENT_PID
  set -l auth_sock (grep SSH_AUTH_SOCK $SSH_AGENT_FILE | sed 's/.*=\([^;]*\);.*/\1/')
  set -l agent_pid (grep SSH_AGENT_PID $SSH_AGENT_FILE | sed 's/.*=\([^;]*\);.*/\1/')
  if test -n "$auth_sock"
    set -gx SSH_AUTH_SOCK $auth_sock
  end
  if test -n "$agent_pid"
    set -gx SSH_AGENT_PID $agent_pid
  end
end

# If the ssh-agent is still not working, start a new one
if not ssh-add -l >/dev/null 2>&1
  set -l current_user (id -un)
  if set -q SSH_AGENT_PID; and test -n "$SSH_AGENT_PID"
    # Check if PID belongs to an ssh-agent owned by current user
    set -l ps_out (ps -p $SSH_AGENT_PID -o user=,comm= 2>/dev/null)
    set -l ps_user (echo $ps_out | awk '{print $1}')
    set -l ps_cmd (echo $ps_out | awk '{print $2}')
    if test "$ps_user" = "$current_user"; and test "$ps_cmd" = ssh-agent
      # Agent is running but not responding - skip
    end
  else
    ssh-agent >$SSH_AGENT_FILE
    # Parse the new agent file
    set -l auth_sock (grep SSH_AUTH_SOCK $SSH_AGENT_FILE | sed 's/.*=\([^;]*\);.*/\1/')
    set -l agent_pid (grep SSH_AGENT_PID $SSH_AGENT_FILE | sed 's/.*=\([^;]*\);.*/\1/')
    if test -n "$auth_sock"
      set -gx SSH_AUTH_SOCK $auth_sock
    end
    if test -n "$agent_pid"
      set -gx SSH_AGENT_PID $agent_pid
    end
  end

  if test -f "$HOME/.ssh/id_ed25519"
    ssh-add "$HOME/.ssh/id_ed25519" 2>/dev/null
  end
end
