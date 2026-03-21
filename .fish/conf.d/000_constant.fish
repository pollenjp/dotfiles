# History and editor settings

set -gx SUDO_EDITOR vim

if command -q manpath
  set -l tmp (manpath -g 2>/dev/null)
  if test -n "$tmp"
    set -gx MANPATH $MANPATH $tmp
  end
end
