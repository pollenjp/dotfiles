#!/usr/bin/env bash
# shellcheck shell=bash
#
# Notion の API キーを宣言したプロファイル (dotfiles.claude.notion.tokens) ごとに、~/.config/pjp/env に変数の行があるかと
# ファイルの権限を、値を出さずに確かめて知らせる。書き換えない。冪等。`setup.sh --update` でも毎回走る。
#
# tool: claude (dotfiles.claude.enable)
# order: 55
#
# ^ tool は setup.sh が読む道具の名前 (設定グループ。nix/README.md「設定グループ」)。~/.local/state/dotfiles/group.json の
#   tools でこの道具が off のホスト (Claude Code を入れないホスト) では、setup はこの手順を飛ばす。状態ファイルも Claude Code を
#   入れるホストにだけ置く (nix/home/modules/claude.nix)。
#   order は、bootstrap-local-env.sh (50) が ~/.config/pjp/env を置き、group と other の権限を外した後に見るため。
#
# ## 何のために
#
# Notion へ書く skill (claude-skills の pjp-dev-tracker など) は、そのマシンに PJP_NOTION_TOKEN_<名前> があれば API キーで、
# 無ければ ntn login で Notion を呼ぶ。API キーを使うホストは、ホストの設定で宣言する (dotfiles.claude.notion.tokens。種類は
# integration か個人用アクセストークン)。値は ~/.config/pjp/env に、ユーザーが自分の端末で入れる (pjp notion-profile set-token
# <名前>。Claude は値を読まない・書かない・出さない。dotfiles-private の docs/adr/112_notion_api_token_local_*)。setup のたびに、
# 宣言したのに入っていない・ファイルをほかのユーザーも読めるを知らせる。
#
# ## 何を読むか
#
#   ~/.local/state/dotfiles/notion-tokens.json   home-manager が置く宣言 (nix/lib/notion-tokens.nix)。宣言が無くても置く:
#       {"tokens": {"personal": {"kind": "integration", "item": null, "var": "PJP_NOTION_TOKEN_PERSONAL"}}}
#   ~/.config/pjp/env   $XDG_CONFIG_HOME があれば $XDG_CONFIG_HOME/pjp/env (bash と fish のローダと同じ)。symlink なら指す先
#
# ## 値を読まない
#
# 行の有無は awk に数えさせ、件数だけを受け取る。値をシェルの変数に入れない・出さない (長さも)。権限は stat で見る。
# ~/.config/pjp/env は書き換えない (group と other の権限を外すのは bootstrap-local-env.sh、入れるのは set-token)。
#
# ## 何を知らせるか (!! で。setup は止めない。どのときも exit 0)
#
#   - 宣言したプロファイルの変数の行が無い。行は、頭が <var>= で、= の後ろが空でない行 (行の末尾の CR は値に数えない)。
#     # で始まる行・頭に空白のある行はローダも読まないので数えない。~/.config/pjp/env が無いときも同じ。入れ方
#     (pjp notion-profile set-token <名前>) と、item があれば 1Password の参照を添える
#   - ~/.config/pjp/env の権限が 600 より広い (rwx の 9 桁のうち、600 の外の桁がある。600 より狭い 400 などは知らせない)
#   - 状態ファイルが無い (この宣言を持つ世代へまだ switch していない)・形が違う、jq が無い、~/.config/pjp/env が普通の
#     ファイルでない・読めない (確かめずに飛ばす)

set -eu -o pipefail

state_file="${HOME}/.local/state/dotfiles/notion-tokens.json"
env_file="${XDG_CONFIG_HOME:-${HOME}/.config}/pjp/env"

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
  warn "jq が見つかりません。Notion の API キーの宣言 (dotfiles.claude.notion.tokens) の状態ファイルを読めません。" \
    "先に home-manager switch を実行してください。この手順は飛ばします。"
  exit 0
fi

if [[ ! -r ${state_file} ]]; then
  warn "Notion の API キーの宣言の状態ファイルがありません: ${state_file}" \
    "dotfiles.claude.notion.tokens を持つ世代へ先に home-manager switch してください (~/dotfiles/setup --update なら続けて流れます)。" \
    "この手順は飛ばします。"
  exit 0
fi

# 形を確かめる。名前と var は文と awk に渡し、item は文に出すので、ここで形を決めておく (item に値が入っていても出さない)。
# 正規表現の頭と終わりは \A と \z (jq の $ は末尾の改行の前でも当たる)
shape='
  type == "object" and (.tokens | type) == "object"
  and all(.tokens | to_entries[];
    (.key | test("\\A[a-z0-9][a-z0-9_-]*\\z"))
    and (.value | type) == "object"
    and (.value.kind == "integration" or .value.kind == "personal")
    and ((.value.var | type) == "string" and (.value.var | test("\\APJP_NOTION_TOKEN_[A-Z0-9_]+\\z")))
    and (.value.item == null
      or ((.value.item | type) == "string"
        and (.value.item | test("\\Aop://[^/[:cntrl:]]+/[^/[:cntrl:]]+/[^/[:cntrl:]]+(/[^/[:cntrl:]]+)?\\z")))))'
bad_shape() {
  warn "Notion の API キーの宣言の状態ファイルの形が違います: ${state_file}" \
    '({"tokens": {"<名前>": {"kind": "integration" か "personal", "item": null か "op://<vault>/<項目>/<欄>", "var": "PJP_NOTION_TOKEN_<名前>"}}} のはず)' \
    "この手順は飛ばします。"
  exit 0
}
jq -e "${shape}" "${state_file}" &>/dev/null || bad_shape
# 1 行に 1 つ、名前・種類・変数名・item (無ければ空) をタブで区切る。どれも制御文字を含まない (上で確かめた)
entries=$(jq -r '.tokens | to_entries[] | [.key, .value.kind, .value.var, (.value.item // "")] | join("\t")' "${state_file}") \
  || bad_shape

if [[ -z ${entries} ]]; then
  echo "Notion の API キーの宣言はありません (dotfiles.claude.notion.tokens)。${env_file} は見ません。"
  exit 0
fi

if [[ ! -e ${env_file} ]]; then
  env_state=missing
elif [[ ! -f ${env_file} ]]; then
  warn "${env_file} が普通のファイルではないので、Notion の API キーの行があるかを確かめられません。" \
    "普通のファイルにしてから、pjp notion-profile set-token <名前> で入れてください。"
  exit 0
elif [[ ! -r ${env_file} ]]; then
  warn "${env_file} を読めないので、Notion の API キーの行があるかを確かめられません。" \
    "ls -l ${env_file} で持ち主と権限を見てください (持ち主が読み書きできる 600 にする)。"
  exit 0
else
  env_state=present
fi

# <var>= で始まり、= の後ろが (行の末尾の CR を除いて) 空でない行を数える。値は awk の中に留め、件数だけを出す。
# var は PJP_NOTION_TOKEN_[A-Z0-9_]+ の形 (上で確かめた) なので、awk の -v の逃がしの字を含まない
count_lines() {
  awk -v prefix="$1=" '
    index($0, prefix) == 1 {
      rest = substr($0, length(prefix) + 1)
      sub(/\r$/, "", rest)
      if (rest != "") n++
    }
    END { print n + 0 }
  ' "${env_file}"
}

# 権限の桁 (rwx の 8 進 3 桁) を出す。symlink は指す先を見る。setgid などの特殊な桁は除く。GNU の stat か、macOS の stat
perm_bits() {
  local m
  m=$(stat -L -c '%a' "$1" 2>/dev/null || stat -L -f '%Lp' "$1" 2>/dev/null) || return 1
  [[ ${m} =~ ^[0-7]+$ ]] || return 1
  m="00${m}"
  printf '%s\n' "${m: -3}"
}

kind_label() {
  case $1 in
    integration) echo "integration の API キー" ;;
    personal) echo "個人用アクセストークン" ;;
  esac
}

echo "Notion の API キーの宣言 (dotfiles.claude.notion.tokens) を ${env_file} で確かめます (値は読みません)。"
vars=()
while IFS=$'\t' read -r name kind var item; do
  vars+=("${var}")
  label=$(kind_label "${kind}")
  n=0
  if [[ ${env_state} == present ]]; then
    n=$(count_lines "${var}") || n=""
    if [[ ! ${n} =~ ^[0-9]+$ ]]; then
      warn "${env_file} を読めないので、Notion の API キーの行があるかを確かめられません。" \
        "ls -l ${env_file} で持ち主と権限を見てください。"
      exit 0
    fi
  fi
  if ((n > 0)); then
    echo "  入っています: ${name} (${label}) の ${var} の行"
    continue
  fi
  if [[ ${env_state} == missing ]]; then
    where="${env_file} が無い"
  else
    where="${env_file} にその行が無い"
  fi
  if [[ -n ${item} ]]; then
    source_text="値は 1Password の ${item}"
  else
    source_text="値は 1Password に置いた元の値"
  fi
  warn "Notion の API キーが入っていません: プロファイル ${name} (${label}) の ${var} (${where})。dotfiles.claude.notion.tokens で宣言したプロファイルです。" \
    "入れ方: ユーザーが自分の端末で pjp notion-profile set-token ${name} を打つ (${source_text}。Claude には打たせない)。"
done <<<"${entries}"

if [[ ${env_state} == present ]]; then
  if ! perm=$(perm_bits "${env_file}"); then
    warn "${env_file} の権限を読めませんでした。ls -l ${env_file} で 600 より広くないかを見てください。"
  elif ((8#${perm} & 8#177)); then
    joined=$(
      IFS='・'
      echo "${vars[*]}"
    )
    warn "${env_file} の権限が ${perm} で、600 より広くなっています (Notion の API キー ${joined} を置くファイル)。" \
      "chmod 600 ${env_file} で、持ち主のほかが読めない 600 にしてください。"
  else
    echo "  権限: ${perm}"
  fi
fi
