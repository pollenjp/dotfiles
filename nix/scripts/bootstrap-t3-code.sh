#!/usr/bin/env bash
# shellcheck shell=bash
#
# T3 Code (dotfiles.t3Code.enable) の settings.json (~/.t3/userdata/settings.json) の決めたキーを合わせ、T3 Code を動かすのに要るもの
# (runtime・nix-ld・linger・service・claude-t3 のログイン・T3 Connect) の状態を出す。冪等。`setup.sh --update` でも毎回走る。
#
# tool: t3Code (dotfiles.t3Code.enable)
# order: 70
#
# ^ setup.sh が読む道具の名前と実行順。t3Code が off のホスト (どのグループでも既定) では、setup はこの手順を飛ばす。claude のアカウント
#   t3 (~/.claude-t3) を用意する bootstrap-claude-accounts.sh (order: 60) より後。
#
# ## 何を読むか
#
# home-manager が置く ~/.local/state/dotfiles/t3-code.json (nix/home/modules/t3-code.nix):
#
#   {"version": "0.1.11", "runtime": "<~/.t3/runtime/versions/0.1.11>", "clearClaudeEntrypoint": true,
#    "managed": <nix/files/t3-code/managed-settings.json の中身>}
#
# 無ければ、この手順を持つ世代へまだ switch していないということなので、警告して exit 0 する (setup.sh は手順が 1 つ失敗すると残りを
# 走らせないため)。
#
# ## settings.json で合わせるキー (Windows の runner の手順 t3-code-settings と同じ決まり)
#
#   providerInstances.claudeAgent.driver           managed.claudeAgent.driver ("claudeAgent")
#   providerInstances.claudeAgent.config.homePath  managed.claudeAgent.homePath ("~/.claude-t3")。config のほかのキー (launchArgs など) は残す
#   providerInstances.claudeAgent.environment      clearClaudeEntrypoint が true なら、managed.entrypointEnvironment と同じ名前の要素を
#                                                  それに置き換える (最初の位置に 1 つ。無ければ末尾に足す)。false なら同じ名前の要素を外す
#                                                  (環境変数の配列が無ければ作らない)。ほかの要素は順を保って残す
#   defaultModelSelection                          managed.defaultModelSelection (丸ごと)
#   defaultThreadEnvMode                           managed.defaultThreadEnvMode ("worktree")
#
# ほかのキーと順は残す (jq は書き換えたキーの位置を保ち、新しいキーを末尾に足す)。同じなら書かない。書くときは同じ dir の一時ファイルから
# mv で置き換え、元の mode を保つ。無ければ (T3 を一度も起こしていない) 合わせるキーだけで作る (dir も)。次のときは書き換えずに警告して
# exit 0 で終わる: jq が無い、状態ファイルが無い・形が違う、settings.json が JSON の object として読めない・symlink・合わせるキーの型が違う、
# 書けない。動いている T3 の server が読み直すとは限らず、setup の流れでは switch (unit が世代に初めて入ると service が起き直る) の後に
# 合わせるので起き直った T3 もまだ読んでいない。そのため書いたら service を起こし直す案内を出す。
#
# ## 状態 (直さない。警告だけ)
#
#   runtime     <runtime>/.install-complete が版でない → home-manager switch (activation が写す)
#   起動        <runtime>/t3 --version が落ちる → NixOS なら programs.nix-ld.enable (配布物は /lib64 の loader を使う)
#   linger      loginctl の Linger が yes でない → service がログインの外で止まる。setup の手順 linger (--steps linger。
#               dotfiles.linger.enable。--update では、この手順より前に走って有効にする)。NixOS は nixos-config
#   service     systemctl --user の t3code.service が active でない・起動で起きる形でない (is-enabled が enabled でなく、WantedBy に
#               default.target も無い)。起動で起きても is-enabled が enabled でなければ (前の世代の unit は alias)、t3 が not enabled と
#               読むので switch を勧める (下の判定のコメント)
#   t3 の見方   t3 service status の Status: が installed でない → t3 service install (t3 の service-state.json を版に揃える)
#   claude-t3   claude-account check t3 が 0 でない → claude-t3 で /login
#   T3 Connect  t3 connect status の Environment link: を出し、NOT reachable なら t3 connect と再起動の手を出す
#
# t3 の CLI を打つのは状態を読むコマンドだけ (--version・service status・connect status)。サインイン・service の再起動はしない。

set -eu -o pipefail

state_file="${HOME}/.local/state/dotfiles/t3-code.json"
settings="${T3CODE_HOME:-${HOME}/.t3}/userdata/settings.json"

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
}

if ! command -v jq &>/dev/null; then
  warn "jq が見つかりません。T3 Code の状態ファイルを読めません。" \
    "先に home-manager switch を実行してください。この手順は飛ばします。"
  exit 0
fi

if [[ ! -r ${state_file} ]]; then
  warn "T3 Code の状態ファイルがありません: ${state_file}" \
    "dotfiles.t3Code を持つ世代へ先に home-manager switch してください (~/dotfiles/setup --update なら続けて流れます)。" \
    "この手順は飛ばします。"
  exit 0
fi

if ! jq -e '(.version | type) == "string" and (.runtime | type) == "string" and (.clearClaudeEntrypoint | type) == "boolean"
    and (.managed.claudeAgent.driver | type) == "string" and (.managed.claudeAgent.homePath | type) == "string"
    and (.managed.defaultModelSelection | type) == "object" and (.managed.defaultThreadEnvMode | type) == "string"
    and (.managed.entrypointEnvironment.name | type) == "string"' "${state_file}" &>/dev/null; then
  warn "T3 Code の状態ファイルの形が違います: ${state_file}" "この手順は飛ばします。"
  exit 0
fi

version=$(jq -r '.version' "${state_file}")
runtime=$(jq -r '.runtime' "${state_file}")
clear_entrypoint=$(jq -r '.clearClaudeEntrypoint' "${state_file}")

# --- settings.json のキーを合わせる

# 合わせるキーの型 (書き換えると壊すもの) を見る jq の式。null (無い) はよい
# shellcheck disable=SC2016 # $t は jq の変数
types_ok='type == "object"
  and ((.providerInstances | type) as $t | $t == "null" or $t == "object")
  and ((.providerInstances.claudeAgent | type) as $t | $t == "null" or $t == "object")
  and ((.providerInstances.claudeAgent.config | type) as $t | $t == "null" or $t == "object")
  and ((.providerInstances.claudeAgent.environment | type) as $t | $t == "null"
    or ($t == "array" and (.providerInstances.claudeAgent.environment | all(type == "object"))))'

# shellcheck disable=SC2016 # $m・$clear・$env などは jq の変数
merge='.providerInstances.claudeAgent.driver = $m.claudeAgent.driver
  | .providerInstances.claudeAgent.config.homePath = $m.claudeAgent.homePath
  | $m.entrypointEnvironment as $e
  | .providerInstances.claudeAgent.environment as $env
  | if $clear then
      .providerInstances.claudeAgent.environment = (
        ($env // []) as $a
        | ($a | map(.name) | index($e.name)) as $i
        | if $i == null then $a + [$e]
          else $a[:$i] + [$e] + ($a[$i + 1:] | map(select(.name != $e.name)))
          end)
    elif $env == null then .
    else .providerInstances.claudeAgent.environment = ($env | map(select(.name != $e.name)))
    end
  | .defaultModelSelection = $m.defaultModelSelection
  | .defaultThreadEnvMode = $m.defaultThreadEnvMode'

sync_settings() {
  local dir tmp mode before after
  dir=$(dirname "${settings}")
  if [[ -L ${settings} ]]; then
    warn "T3 Code の settings.json が symlink なので触りません: ${settings} -> $(readlink "${settings}")" \
      "T3 も書くファイルです。symlink をやめてから ~/dotfiles/setup --update を流し直してください。"
    return 0
  fi
  if [[ -e ${settings} ]]; then
    if ! before=$(jq -c "if (${types_ok}) then . else error(\"types\") end" "${settings}" 2>/dev/null); then
      warn "T3 Code の settings.json が JSON の object として読めないか、合わせるキー (providerInstances.claudeAgent) の型が違うので触りません: ${settings}" \
        "T3 の Settings で直すか、ファイルを直してから ~/dotfiles/setup --update を流し直してください。"
      return 0
    fi
  else
    before='{}'
  fi
  after=$(jq -c --argjson m "$(jq -c '.managed' "${state_file}")" --argjson clear "${clear_entrypoint}" "${merge}" <<<"${before}")
  if [[ -e ${settings} ]] && jq -e --argjson a "${after}" '. == $a' <<<"${before}" >/dev/null; then
    echo "T3 Code の settings.json の決めたキーはそろっています: ${settings}"
    return 0
  fi
  if ! mkdir -p "${dir}" 2>/dev/null; then
    warn "T3 Code の settings.json の dir を作れません: ${dir}" "settings.json は変えません。"
    return 0
  fi
  if ! tmp=$(mktemp "${dir}/.settings.json.dotfiles.XXXXXX" 2>/dev/null); then
    warn "T3 Code の settings.json の一時ファイルを作れません: ${dir}" "settings.json は変えません。"
    return 0
  fi
  if [[ -e ${settings} ]]; then
    mode=$(stat -c '%a' "${settings}" 2>/dev/null || stat -f '%Lp' "${settings}")
  else
    mode=$(printf '%o' $((0666 & ~$(umask))))
  fi
  if ! { jq --indent 2 . <<<"${after}" >"${tmp}" && chmod "${mode}" "${tmp}" && mv -f "${tmp}" "${settings}"; } 2>/dev/null; then
    rm -f "${tmp}"
    warn "T3 Code の settings.json を書けません: ${settings}" "settings.json は変えません。"
    return 0
  fi
  echo "T3 Code の settings.json の決めたキーを合わせました: ${settings}"
  echo "  (Claude の home・新しいスレッドの既定・CLAUDE_CODE_ENTRYPOINT。動いている T3 は、直前の switch で起き直っていてもまだ読んでいません。"
  echo "   読ませるには、スレッドが動いていない時に systemctl --user restart t3code)"
}

sync_settings

# --- 状態を出す

if [[ $(cat "${runtime}/.install-complete" 2>/dev/null) != "${version}" ]]; then
  warn "T3 Code ${version} の runtime がありません: ${runtime}" \
    "home-manager switch で置かれます (~/dotfiles/setup --update)。"
  exit 0
fi

if ! t3_version=$(timeout 30 "${runtime}/t3" --version 2>&1); then
  warn "T3 Code の t3 が起きません: ${runtime}/t3 --version (${t3_version//$'\n'/ })" \
    "配布物は /lib64 の loader を使う動的リンクの実行ファイルです。NixOS では programs.nix-ld.enable = true が要ります。"
  exit 0
fi
echo "T3 Code: ${t3_version}"

linger=$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null || true)
if [[ ${linger} != yes ]]; then
  warn "T3 Code の service がログインの外で止まります (systemd の linger が ${linger:-読めない})。" \
    "setup の手順 linger で有効にしてください: ~/dotfiles/setup --steps linger (中で sudo を呼ぶ。dotfiles.linger.enable が false のホストでは、先に true にする)。" \
    "NixOS では nixos-config に users.users.$(id -un).linger = true; を書いてください。"
fi

# 起動で起きるかは is-enabled だけで決めない。systemd は ~/.config/systemd/user/t3code.service の link をたどった先のファイル名が
# unit の名前と違うと、その unit を別の unit の別名と見て is-enabled に alias を返す。前の dotfiles の世代 (xdg.configFile の text だけで
# 置き、先が /nix/store/<hash>-hm_systemdusert3code.service) がそうで、default.target.wants の link があって起動では起きていても alias と
# 出た。そのため、is-enabled が enabled か、WantedBy に default.target があれば、起動で起きる形と読む。
#
# ただし t3 は is-enabled が enabled でないと「service-disabled」(t3 service status の needs an update or repair) と読むので、起動で
# 起きる形でも enabled でなければ、そのわけと直し方 (今の dotfiles の世代へ switch。unit は名前が t3code.service の store のファイルを
# 指す。nix/home/modules/t3-code.nix) を出す。t3 service install は勧めない (直すのは dotfiles の unit の置き方の側で、t3 の状態ではない)。
enabled=$(systemctl --user is-enabled t3code.service 2>/dev/null || true)
wanted_by=$(systemctl --user show t3code.service --property=WantedBy --value 2>/dev/null || true)
active=$(systemctl --user is-active t3code.service 2>/dev/null || true)
if [[ ${enabled} == enabled || " ${wanted_by} " == *" default.target "* ]]; then
  on_boot=yes
else
  on_boot=no
fi
if [[ ${on_boot} != yes || ${active} != active ]]; then
  warn "T3 Code の service (t3code.service) が動いていないか、起動で起きる形になっていません (is-enabled: ${enabled:-不明}・WantedBy: ${wanted_by:-なし}・is-active: ${active:-不明})。" \
    "systemctl --user daemon-reload && systemctl --user start t3code で起こし、journalctl --user -u t3code と ~/.t3/userdata/logs/boot-service.log を見てください。"
elif [[ ${enabled} != enabled ]]; then
  warn "T3 Code の service は動いていて起動でも起きます (default.target に wanted) が、is-enabled が ${enabled:-不明} なので、t3 は service を「not enabled」と読みます。" \
    "unit (~/.config/systemd/user/t3code.service) の link の先のファイル名が t3code.service でないと、systemd は alias と出します。" \
    "home-manager switch (~/dotfiles/setup --update) で今の dotfiles の unit に置き直してください (中身が同じなら service は起き直りません)。"
else
  status_line=$(timeout 30 "${runtime}/t3" service status 2>/dev/null | grep -m1 'Status:' || true)
  status_line=${status_line#"${status_line%%[![:space:]]*}"}
  if [[ ${status_line} == "Status: installed"* ]]; then
    echo "T3 Code の service: ${status_line}"
  else
    warn "T3 Code の service を t3 が current と読んでいません (${status_line:-t3 service status が読めない})。" \
      "版を上げた後なら、t3 service install で t3 の状態 (~/.t3/runtime/service-state.json) を ${version} に揃えてください (service が起き直します)。"
  fi
fi

if command -v claude-account &>/dev/null; then
  if claude_line=$(claude-account check t3 2>/dev/null); then
    echo "T3 Code の Claude (claude-t3): ${claude_line}"
  else
    warn "T3 Code の Claude のアカウント (claude-t3) にログインしていません。" \
      "端末で claude-t3 を起こして /login を打ってください (T3 の会話は ~/.claude-t3 の資格情報で動きます)。"
  fi
fi

connect=$(timeout 30 "${runtime}/t3" connect status 2>/dev/null || true)
link_line=$(grep -m1 'Environment link:' <<<"${connect}" || true)
link_line=${link_line#"${link_line%%[![:space:]]*}"}
if [[ ${connect} == *"NOT reachable"* ]]; then
  warn "T3 Connect でほかの端末からつながりません (${link_line:-Environment link: 不明})。" \
    "t3 connect でサインインし (device code)、systemctl --user restart t3code の後に t3 connect status で確かめてください。"
elif [[ -n ${link_line} ]]; then
  echo "T3 Connect: ${link_line}"
fi
