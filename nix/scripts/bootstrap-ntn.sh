#!/usr/bin/env bash
# shellcheck shell=bash
#
# ntn (Notion CLI) の config.json の keyring を host option (dotfiles.ntn.keyring) の値にそろえる。keyring: false なら、
# token を置く config directory を 700・auth.json を 600 にもそろえる。冪等。`setup.sh --update` でも毎回走る。
#
# ## 何のために
#
# ntn は `ntn login` の token を OS の keychain に置く。keychain の無い・続かないマシン (SSH で入る Linux の VM
# など) では `ntn login` が keychain のエラーで落ちるので、ntn の config.json に "keyring": false を書き、token を
# config directory の auth.json に置かせる。どのマシンで切るかは host option (dotfiles.ntn.keyring) に置き、
# ここで config.json へ写す。
#
# ## 何を読むか
#
# home-manager が置く ~/.local/state/dotfiles/ntn.json (nix/home/modules/ntn.nix)。中身は option の値そのもの:
#
#   {"keyring": false}      (null・true もある)
#
# 無ければ、この option を含む世代へまだ switch していないということなので、警告して exit 0 する
# (setup.sh は手順が 1 つ失敗すると残りを走らせないため)。
#
# ## 何をするか
#
#   - keyring が null なら何もしない (config.json にも、config directory と auth.json の mode にも触らない)
#   - keyring が false なら、config.json より先に config directory と auth.json の mode をそろえる (下の「config
#     directory と auth.json の mode」)
#   - config.json があれば keyring だけを書き換え (無ければ足し)、ほかのキー (既定の workspace など) は残す。
#     同じ値なら書かない。書くときは同じディレクトリの一時ファイルから mv で置き換え、元の mode を保つ
#   - 無ければ、ntn が空の場所に作るのと同じ形 {"version": "1", "defaultWorkspaceIds": {}, "keyring": <値>} で作る
#     (ディレクトリも。config.json の mode は ntn と同じく umask どおり。ディレクトリは keyring: false なら 700、
#     true なら umask どおり)。ntn は version の無い config.json を読めない
#     ({"keyring": false} だけだと Failed to parse config.json)。ntn が入っていなくても作る (あとで入れて
#     ntn login したときから token をファイルに置くため)
#   - 次のときは書き換えずに警告し、exit 0 で終わる (setup を止めない): jq が無い、状態ファイルが無い・形が違う、
#     NOTION_HOME がディレクトリでない、config.json が JSON の object として読めない・symlink、書けない、
#     keyring: false で config directory に触ると危ない (下の「config directory と auth.json の mode」)。
#     config.json の symlink を書き換えないのは、mv で置き換えると張った symlink が消えるため
#   - version (文字列) の無い config.json は、keyring を書いたうえで ntn が読めないと警告する (version は足さない。
#     書くのは keyring だけ)
#
# ntn は打つたびに config.json を読むので、動いている process (herdr・Claude Code・systemd の service) の下の ntn にも、
# 次に打ったときから効く。ntn では環境変数 NOTION_KEYRING が config.json より強いが、dotfiles はそれを入れない。
#
# ## config directory の場所
#
# ntn と同じ規則で決める (Linux の ntn 0.23.25 で確かめた。公式の文書は 4 つの場所の順だけを書く):
#
#   1. NOTION_HOME (空でなければ)。ディレクトリでなければ ntn は止まるので、作らずに警告して終わる
#   2. $XDG_CONFIG_HOME/notion (XDG_CONFIG_HOME が空でなく、ディレクトリのとき)
#   3. ~/.config/notion (~/.config がディレクトリのとき。~/.notion/config.json があっても見ない)
#   4. ~/.notion
#
# NOTION_HOME の末尾の / は外して使う (付いたままだと [[ -L ]] が symlink の先をたどり、symlink を見落とす)。
#
# ## config directory と auth.json の mode
#
# keyring: false では token が config directory の auth.json に平文で入る。ntn はディレクトリもファイルも umask
# どおりに作る (umask 002 なら 775・664) ので、keyring: false のときだけ、ほかのユーザーが読めないようにそろえる:
#
#   - config directory は、作るなら 700 で作り、あれば 700 にそろえる。ディレクトリが 700 なら、ntn が login し直して
#     auth.json を 664 で作り直しても、ほかのユーザーは読めない
#   - auth.json があれば 600 にそろえる (無ければ作らない)。ほかのファイル (config.json・cache.json など) の mode は
#     変えない。秘密は auth.json だけで、ディレクトリが 700 なら中身は読まれない (作る config.json も umask どおり)
#   - 違うときだけ chmod し、直したら「そろえました: <パス> の mode を 775 から 700 に」のように 1 行出す。
#     比べるのは権限の 3 桁 (rwx) だけ。GNU の chmod は数字の mode でディレクトリの setgid を残す (2775 は 2700 に
#     なる) ので、特殊な桁まで比べると毎回そろえ直すことになる
#   - config directory が symlink・持ち主が自分でない・700 にできないときは、token を置く場所の安全を確かめられない
#     ので、mode も config.json も変えずに警告して exit 0 する (config.json が symlink のときと同じ作法)。ディレクトリ
#     でないもの (普通のファイル) なら、config.json を作るところで作れずに警告して終わる
#   - auth.json が symlink・普通のファイルでない・600 にできないときは、auth.json だけ変えずに警告し、keyring は
#     そろえる (ディレクトリは 700 にそろえ終えている)。持ち主が自分でない auth.json は chmod が落ちるので、こちらに入る
#   - keyring が true・null なら mode に触らない。true の token は OS の keychain にあり、config directory に秘密が
#     無い。null は ntn の設定に触らない約束
#
# ## なぜ Nix でやらないのか
#
# config.json は ntn が自分で書き換える (`ntn login` が既定の workspace を書く) ため、store 上の read-only の
# ファイルにできない (ntn は symlink の先へ書こうとして Failed to write config.json で落ちる)。
# home.activation で書く手も採らない。store 管理でないファイルを switch が作ると「Nix 管理か否か」の線が
# 曖昧になる (bootstrap-claude-skill-overrides.sh と同じ理由)。

set -eu -o pipefail

state_file="${HOME}/.local/state/dotfiles/ntn.json"

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
# setup.sh が手順ごとに DOTFILES_SETUP_WARNINGS でファイルを渡す。単体で流したときは何もしない。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
}

if ! command -v jq &>/dev/null; then
  warn "jq が見つかりません。ntn の keyring (dotfiles.ntn.keyring) の状態ファイルを読めません。" \
    "先に home-manager switch を実行してください。この手順は飛ばします。"
  exit 0
fi

if [[ ! -r ${state_file} ]]; then
  warn "ntn の keyring の状態ファイルがありません: ${state_file}" \
    "dotfiles.ntn.keyring を持つ世代へ先に home-manager switch してください (~/dotfiles/setup --update なら続けて流れます)。" \
    "この手順は飛ばします。"
  exit 0
fi

if ! jq -e 'type == "object" and has("keyring") and (.keyring == null or (.keyring | type) == "boolean")' \
  "${state_file}" &>/dev/null; then
  warn "ntn の keyring の状態ファイルの形が違います: ${state_file}" \
    '({"keyring": null か true か false} のはず)' \
    "この手順は飛ばします。"
  exit 0
fi

value=$(jq -c '.keyring' "${state_file}")
if [[ ${value} == null ]]; then
  echo "dotfiles.ntn.keyring は null (指定なし) なので、ntn の config.json には触りません。"
  exit 0
fi

# config directory (冒頭の「config directory の場所」)
if [[ -n ${NOTION_HOME-} ]]; then
  if [[ ! -d ${NOTION_HOME} ]]; then
    warn "NOTION_HOME (${NOTION_HOME}) がディレクトリではありません。ntn もこのままでは動きません。" \
      "ディレクトリを作るか NOTION_HOME を外してから、~/dotfiles/setup --update を流し直してください。" \
      "ntn の config.json には触りません。"
    exit 0
  fi
  # 末尾の / を外す (付いたままだと、下で symlink かを見るとき [[ -L ]] が symlink の先をたどってしまう)。/ は残す
  config_dir=${NOTION_HOME}
  while [[ ${config_dir} == */ && ${config_dir} != / ]]; do
    config_dir=${config_dir%/}
  done
elif [[ -n ${XDG_CONFIG_HOME-} && -d ${XDG_CONFIG_HOME} ]]; then
  config_dir="${XDG_CONFIG_HOME}/notion"
elif [[ -d ${HOME}/.config ]]; then
  config_dir="${HOME}/.config/notion"
else
  config_dir="${HOME}/.notion"
fi
config="${config_dir}/config.json"

# 権限の桁 (rwx の 8 進 3 桁) を出す。setgid などの特殊な桁は除く (冒頭の「config directory と auth.json の mode」)。
# GNU の stat か、macOS の stat
perm_bits() {
  local m
  m=$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1") || return 1
  m="00${m}"
  printf '%s\n' "${m: -3}"
}

# keyring: false なら token を置くディレクトリなので、ほかのユーザーが読めないようにそろえる
# (冒頭の「config directory と auth.json の mode」)。無ければ下で 700 で作る。ディレクトリでないもの
# (普通のファイル) があれば、下で作れずに警告して終わる
if [[ ${value} == false ]]; then
  if [[ -L ${config_dir} ]]; then
    warn "ntn の config directory が symlink なので触りません: ${config_dir} -> $(readlink "${config_dir}")" \
      "keyring: false では token (auth.json) をここに置きます。先がほかのユーザーから読めないかを確かめられないので、mode も config.json も変えません。" \
      "symlink をやめて普通のディレクトリにしてから、~/dotfiles/setup --update を流し直してください。"
    exit 0
  fi
  if [[ -d ${config_dir} ]]; then
    if [[ ! -O ${config_dir} ]]; then
      warn "ntn の config directory の持ち主が自分ではないので触りません: ${config_dir}" \
        "keyring: false では token (auth.json) をここに置きます。ほかのユーザーのディレクトリなので、mode も config.json も変えません。" \
        "自分のディレクトリにしてから、~/dotfiles/setup --update を流し直してください。"
      exit 0
    fi
    perm=$(perm_bits "${config_dir}") || perm="(読めない)"
    if [[ ${perm} != 700 ]]; then
      if ! chmod 700 "${config_dir}"; then
        warn "ntn の config directory を 700 にできませんでした (上のエラー): ${config_dir}" \
          "keyring: false の token (auth.json) をほかのユーザーが読めるかもしれないので、config.json も変えません。"
        exit 0
      fi
      echo "そろえました: ${config_dir} の mode を ${perm} から 700 に"
    fi

    auth="${config_dir}/auth.json"
    if [[ -L ${auth} ]]; then
      warn "ntn の auth.json が symlink なので mode を変えません: ${auth} -> $(readlink "${auth}")" \
        "token のファイルなので、先のファイルをほかのユーザーが読めないことを確かめてください。"
    elif [[ -e ${auth} && ! -f ${auth} ]]; then
      warn "ntn の auth.json が普通のファイルではないので mode を変えません: ${auth}"
    elif [[ -f ${auth} ]]; then
      perm=$(perm_bits "${auth}") || perm="(読めない)"
      if [[ ${perm} != 600 ]]; then
        if chmod 600 "${auth}"; then
          echo "そろえました: ${auth} の mode を ${perm} から 600 に"
        else
          warn "ntn の auth.json を 600 にできませんでした (上のエラー): ${auth}" \
            "config directory は 700 なので、ほかのユーザーからは読めません。"
        fi
      fi
    fi
  fi
fi

tmp=""
# 落ちたときに config.json の隣へ中間ファイルを残さない。
trap '[[ -z ${tmp} ]] || rm -f "${tmp}"' EXIT

# 書けなかったとき (ディレクトリを作れない・一時ファイルを置けない・mv できない): 警告して終わる (setup を止めない)
give_up() {
  warn "ntn の config.json を書けませんでした (上のエラー): ${config}" \
    "keyring は ${value} になっていません。この手順は飛ばします。"
  exit 0
}

# 作った・書いたあとに、token の置き場所を 1 行で知らせる
tell_token_place() {
  if [[ ${value} == false ]]; then
    echo "keyring: false のあいだ、ntn login の token は OS の keychain でなく ${config_dir}/auth.json に置かれます。"
  else
    echo "keyring: true のあいだ、ntn login の token は OS の keychain に置かれます。"
  fi
}

if [[ -L ${config} ]]; then
  warn "ntn の config.json が symlink なので書き換えません: ${config} -> $(readlink "${config}")" \
    "keyring を ${value} にするなら、symlink の先のファイルを直してください。"
  exit 0
fi

if [[ ! -e ${config} ]]; then
  # keyring: false なら token を置くディレクトリなので 700 で作る (あれば上でそろえてある)。true は ntn と同じく umask どおり
  if [[ ${value} == false ]]; then
    # shellcheck disable=SC2174 # 700 にするのは一番深い config directory だけでよい (親は ~/.config などの今あるもの)
    mkdir -p -m 700 "${config_dir}" || give_up
  else
    mkdir -p "${config_dir}" || give_up
  fi
  tmp=$(mktemp "${config}.XXXXXX") || give_up
  # mktemp は 0600 で作る。ntn が作るときと同じく umask どおりにする
  mask=$(umask)
  chmod "$(printf '%o' "$((0666 & ~mask))")" "${tmp}" || give_up
  jq -n --argjson v "${value}" '{version: "1", defaultWorkspaceIds: {}, keyring: $v}' >"${tmp}" || give_up
  mv "${tmp}" "${config}" || give_up
  tmp=""
  echo "作りました: ${config} (ntn が作るのと同じ形に keyring: ${value})"
  tell_token_place
  exit 0
fi

if ! jq -e 'type == "object"' "${config}" &>/dev/null; then
  warn "ntn の config.json が JSON の object として読めないので書き換えません: ${config}" \
    "ntn もこのファイルを読めません。直すか退けてから ~/dotfiles/setup --update を流し直してください (無ければ ntn と同じ形で作ります)。"
  exit 0
fi

current=$(jq -c '.keyring' "${config}")
if [[ ${current} == "${value}" ]]; then
  echo "そろっています: ${config} の keyring は ${value}"
else
  # 元の mode を写す (GNU の stat か、macOS の stat)
  mode=$(stat -c '%a' "${config}" 2>/dev/null || stat -f '%Lp' "${config}") || give_up
  tmp=$(mktemp "${config}.XXXXXX") || give_up
  jq --argjson v "${value}" '.keyring = $v' "${config}" >"${tmp}" || give_up
  chmod "${mode}" "${tmp}" || give_up
  mv "${tmp}" "${config}" || give_up
  tmp=""
  [[ ${current} != null ]] || current="(無し)"
  echo "書きました: ${config} の keyring を ${current} から ${value} に"
  tell_token_place
fi

if ! jq -e '.version | type == "string"' "${config}" &>/dev/null; then
  warn "ntn の config.json に version (文字列) がありません: ${config}" \
    "ntn はこの形を読めません (Failed to parse config.json)。" \
    "\"version\": \"1\" を足すか、ファイルを退けてから ~/dotfiles/setup --update を流し直してください (ntn と同じ形で作り直します)。"
fi
