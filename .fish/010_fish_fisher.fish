function fish_greeting
  echo "Welcome back"
  echo "Run following command to update fish plugins!"

  set -l msg 'fisher update'

  # msg のlength 分の `-` を表示
  set_color normal
  string repeat -n (string length -- "$msg") -

  set_color yellow
  echo $msg

  # msg のlength 分の `-` を表示
  set_color normal
  string repeat -n (string length -- "$msg") -
end
funcsave fish_greeting

if not type -q fisher
  curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
end
