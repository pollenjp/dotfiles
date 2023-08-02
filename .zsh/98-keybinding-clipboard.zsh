# shellcheck shell=zsh

function paste_form_clipboard_file() {
  local filepath="${HOME}/clipboard.txt"
  if [[ ! -f "${filepath}" ]]; then
    touch "${filepath}"
  fi

  # ファイルからのテキストを取得
  local insert_text=$(cat "${filepath}")

  # 新しいテキストを現在のカーソル位置
  LBUFFER="${insert_text}"
}
zle -N clipboard_widget paste_form_clipboard_file
bindkey "^Y" clipboard_widget
