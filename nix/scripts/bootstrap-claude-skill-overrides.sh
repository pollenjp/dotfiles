#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の skill の見え方 (skillOverrides) を ~/.claude/settings.json に書く (host option・pack・同期された skill)。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 60
#
# ^ setup.sh が読む実行順。bootstrap-claude-skills.sh (既定の 50) が ~/.claude/skills へ張った skill の SKILL.md
#   (pack の割り当て) と入口の skill (pjp-pack-<pack>) を読むので、その後に走らせる。仕組みは nix/README.md
#   「bootstrap の実行順」。
#
# ## 何のために
#
# skill の見え方 (Claude の一覧に説明つきで出るか・名前だけか・出ないか、`/` から呼べるか) は settings.json の
# skillOverrides でしか変えられない。ここで 3 種類の key を書く (nix/README.md「Claude Code の skill を host ごとに
# 止める」と「skill の一覧を枠に収める」):
#
#   host option の skill  使う skill はマシンごとに違う (例: 会社のマシンでは Notion Dev Tracker の pjp-dev-tracker を
#                         発火させない) ので、その宣言は host option (dotfiles.claude.devTracker.enable) に置き、ここで
#                         写す。user の settings.json では option が正で、手で変えても次の実行で戻る
#   pack の skill         Claude Code は skill の名前と説明の一覧を毎ターン context に入れ、一覧は context の 1% の枠に
#                         収められる (あふれると、呼ばれた回数の少ない skill から説明が落ちる)。話題ごとの skill の組
#                         (pack) は "name-only" (一覧に名前だけ。Skill tool で名前を指せば呼べる) にし、どの会話でも要る
#                         skill (常駐) と pack の入口の skill (pjp-pack-<pack>) だけを説明つきで見せる
#   同期された skill      claude.ai から同期された skill (anthropic-skills:<名前>) は "user-invocable-only" にする (Claude の
#                         一覧から消え、ユーザーは / から呼べる)。plugin ではないので enabledPlugins では切れない
#                         (Claude Code 2.1.316 で、"anthropic-skills@synced": false を書いても一覧に残った)
#
# ## 何を読むか
#
#   ~/.local/state/dotfiles/claude-skill-overrides.json
#       home-manager が置く host option の値 (nix/home/modules/claude.nix)。skillOverrides に merge する map そのもの
#       ({"pjp-dev-tracker":"off"})。無ければ、option を含む世代へまだ switch していないので、警告してこの分だけ飛ばす。
#       --no-host-option では読まない (home-manager の無い cloud の VM。claude-cloud/bootstrap-claude-cloud.sh が渡す)
#   ~/.claude/skills/*/SKILL.md
#       frontmatter の metadata の pjp-pack (pack の割り当て)。yq の無いマシン (cloud の VM) でも読めるよう、決まった形
#       だけを awk で読む (下の skill_pack)。その pack の入口は ~/.claude/skills/pjp-pack-<pack>/SKILL.md
#   ~/.claude/skills/synced/*/<名前>/SKILL.md と ~/.claude-<アカウント>/skills/synced/*/<名前>/SKILL.md
#       claude.ai から同期された skill。アカウントは ~/.local/state/dotfiles/claude-accounts.json の一覧
#       (bootstrap-claude-accounts.sh と同じ)。settings.json はアカウントの間で共有なので、どのアカウントの分も書く
#   ~/.local/state/dotfiles/claude-skill-overrides.applied.json
#       この script が書いた key と値の控え ({"version":1,"keys":{"pjp-plantuml":"name-only",…}})
#
# ## 何をするか
#
# host option の key は上書きする。pack の skill と同期された skill の key は、書きたい値・settings.json の今の値・
# 控えで決める:
#
#   今の値が無い                 書いて控える
#   今の値が書きたい値と同じ     控える (前から同じ値が書いてあった key も、自分の key として控える。あとで戻すとき、
#                                既定の見え方 (説明つき) の側に倒れるように)
#   今の値が控えた値と同じ       書きたい値に書き換えて控える
#   それ以外                     手で書いた値なので触らない (控えない。stdout に知らせる)
#
# 書きたくなくなった key (入口が消えた・skill が pack から外れた・同期された skill が消えた) は、今の値が控えた値と同じ
# なら消して既定の見え方に戻し、違えば (手で変えた) 触らない。どちらも控えから外す。
#
#   - 入口の無い pack の skill は名前だけにしない (呼ぶきっかけが消えるため)。入口が 1 つも無い (claude-skills を取れない
#     マシン・入口がまだ無い版) なら 1 行出すだけにし、ほかの pack の入口はあるなら、その pack の分を警告する
#   - 入口の skill 自身・mod を兼ねる skill (.claude-plugin/plugin.json がある。plugin の skill には skillOverrides が効かない)
#     に pjp-pack があれば、警告して名前だけにしない。pjp-pack の値が pack の名前として読めないときも同じ
#   - host option の key と同じ名前の skill は、host option の値だけを書く
#   - settings.json のほかのキーと、ここで決めない skillOverrides の key はそのまま。同じ内容なら書き直さない
#
# 実行中の Claude Code には効かない (一覧は session の始めに送られる)。新しい session から反映される。
#
# ## 止まるとき
#
# settings.json が JSON の object として読めない・その skillOverrides が object でない・host option のファイルが object で
# ないときは、何も書かずに exit 1。jq が無いときも exit 1。知らない引数は exit 2。
#
# ## なぜ Nix でやらないのか
#
# settings.json は Claude Code 自身が書き換える (権限の「常に許可」など) ため、
# store 上の read-only ファイルにできない。bootstrap-claude-env.sh とまったく同じ切り分け。
# home.activation で書く手も採らない。store 管理でないファイルを switch が作ると
# 「Nix 管理か否か」の線が曖昧になる (bootstrap-local-env.sh と同じ理由)。
# pack の割り当てと入口は claude-skills (private) の作業クローンにもあり、Nix からは見えない。
#
# macOS の /bin/bash (3.2) でも動くように書く (連想配列・mapfile を使わない。表は jq で組む)。

set -eu -o pipefail
shopt -s nullglob

usage() {
  cat <<'EOS'
Claude Code の skill の見え方 (skillOverrides) を ~/.claude/settings.json に書く。

使い方:
  bootstrap-claude-skill-overrides.sh                   書く
  bootstrap-claude-skill-overrides.sh --no-host-option  host option の値 (home-manager が置くファイル) を読まない (cloud の VM)
  bootstrap-claude-skill-overrides.sh --quiet           stdout に何も出さない (警告は stderr に出す)
  bootstrap-claude-skill-overrides.sh -h, --help        これ

書く key と値:
  host option の skill (pjp-dev-tracker)        on / off (dotfiles.claude.devTracker.enable)
  pack の skill (SKILL.md の metadata.pjp-pack)  name-only (その pack の入口 pjp-pack-<pack> があるときだけ)
  claude.ai から同期された skill                anthropic-skills:<名前> を user-invocable-only

書いた key は ~/.local/state/dotfiles/claude-skill-overrides.applied.json に控え、書かなくなったら戻す。
手で別の値を書いた key には触らない。
EOS
}

host_option=1
quiet=0
for arg in "$@"; do
  case ${arg} in
    --no-host-option) host_option=0 ;;
    --quiet) quiet=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

settings="${HOME}/.claude/settings.json"
skills_dir="${HOME}/.claude/skills"
state_dir="${HOME}/.local/state/dotfiles"
generated="${state_dir}/claude-skill-overrides.json"
accounts_file="${state_dir}/claude-accounts.json"
record_file="${state_dir}/claude-skill-overrides.applied.json"

# pack の名前 (入口のディレクトリ名 pjp-pack-<pack> の後ろ)・同期された skill とアカウントの名前として受けるもの
pack_re='^[a-z0-9]+(-[a-z0-9]+)*$'
plain_re='^[A-Za-z0-9._-]+$'

# --quiet でなければ stdout に出す
note() {
  if [[ ${quiet} == 0 ]]; then
    printf '%s\n' "$*"
  fi
}

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

# skill_pack <SKILL.md>: frontmatter の metadata の pjp-pack の値を出す (無ければ何も出さない)。
#
# yq を前提にしない (cloud の VM には無い) ので、次の形だけを読む。値は引用符で囲んでもよく、値の後ろの「 #」から先は
# コメントとして外す。metadata の直下 (最初の子の字下げ) の pjp-pack だけを見る。
#
#   metadata:
#     pjp-pack: <pack>
#
# ほかの形 (metadata: {pjp-pack: …} など) は読まない。pack の無い skill として説明つきのまま残る (安全な側に倒れる)。
# frontmatter は 1 行目の --- から次の --- の行まで (Claude Code と同じく、--- の後ろの空白と CRLF は受ける)。
skill_pack() {
  awk -v q="'" '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 !~ /^---[ \t]*$/) exit; next }
    /^---[ \t]*$/ { exit }
    /^[^ \t#]/ { in_meta = ($0 ~ /^metadata:[ \t]*(#.*)?$/); depth = -1; next }
    !in_meta || /^[ \t]*(#.*)?$/ { next }
    {
      match($0, /^[ \t]*/)
      if (depth < 0) depth = RLENGTH
      if (RLENGTH != depth) next
      v = substr($0, RLENGTH + 1)
      if (v !~ /^pjp-pack:/) next
      sub(/^pjp-pack:[ \t]*/, "", v)
      sub(/[ \t]+#.*$/, "", v)
      sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ ("^" q ".*" q "$")) v = substr(v, 2, length(v) - 2)
      print v
      exit
    }
  ' "$1"
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

# ---- 書く前に読めるかを確かめる ----

current='{}'
if [[ -e ${settings} ]]; then
  if ! jq -e 'type == "object"' "${settings}" >/dev/null 2>&1; then
    echo "${settings} が JSON のオブジェクトとして読めません。手で直してください。" >&2
    exit 1
  fi
  # merge 先が object でないと jq の加算が生エラーで落ちる。host option のファイルと同じく型を見る。
  if ! jq -e '(.skillOverrides // {}) | type == "object"' "${settings}" >/dev/null 2>&1; then
    echo "${settings} の skillOverrides が map (JSON object) ではありません。手で直してください。" >&2
    exit 1
  fi
  current=$(cat -- "${settings}")
fi

host_values='{}'
if [[ ${host_option} == 1 ]]; then
  if [[ ! -r ${generated} ]]; then
    warn "生成ファイルがありません: ${generated}" \
      "dotfiles.claude.devTracker.enable を持つ世代へ先に home-manager switch してください。" \
      "host option の skill (pjp-dev-tracker) の分は飛ばします。"
  elif ! host_values=$(jq -c -e 'if type == "object" then . else error("not an object") end' "${generated}" 2>/dev/null); then
    echo "${generated} が skillOverrides の map (JSON object) ではありません。" >&2
    exit 1
  fi
fi

record='{}'
if [[ -e ${record_file} ]]; then
  if ! record=$(jq -c -e '
    if .version == 1 and (.keys | type) == "object" and all(.keys[]; type == "string")
    then .keys else error("bad record") end' "${record_file}" 2>/dev/null); then
    warn "控えが読めません: ${record_file}" \
      "無いものとして進めます (前に書いた key のうち、今は書かないものは戻せません。今も書く key はまた控えます)。"
    record='{}'
  fi
fi

# ---- 書きたい key と値を集める ("<key>\t<値>" の行) ----

want_rows=""

# pack の skill ("<skill>\t<pack>" の行)
pack_rows=""
for f in "${skills_dir}"/*/SKILL.md; do
  [[ -f ${f} ]] || continue
  skill_dir=$(dirname -- "${f}")
  skill=$(basename -- "${skill_dir}")
  pack=$(skill_pack "${f}")
  [[ -n ${pack} ]] || continue
  if ! [[ ${pack} =~ ${pack_re} ]]; then
    warn "${f} の metadata の pjp-pack が、pack の名前として読めません: ${pack}" \
      "pack の名前は小文字の英数字とハイフン (diagram など) です。この skill は説明つきのまま残します。"
    continue
  fi
  if [[ ${skill} == pjp-pack-* ]]; then
    warn "入口の skill ${skill} に metadata の pjp-pack があります (${pack})。入口は常駐なので、名前だけにはしません。" \
      "${f} から pjp-pack を外してください。"
    continue
  fi
  if [[ -f ${skill_dir}/.claude-plugin/plugin.json ]]; then
    warn "mod を兼ねる skill ${skill} に metadata の pjp-pack があります (${pack})。" \
      "plugin として読まれ skillOverrides が効かないので、名前だけにはしません。"
    continue
  fi
  pack_rows+="${skill}"$'\t'"${pack}"$'\n'
done

any_entry=0
for f in "${skills_dir}"/pjp-pack-*/SKILL.md; do
  if [[ -f ${f} ]]; then
    any_entry=1
    break
  fi
done

no_entry_count=0
packs=$(printf '%s' "${pack_rows}" | cut -f 2 | sort -u)
while IFS= read -r pack; do
  [[ -n ${pack} ]] || continue
  members=$(printf '%s' "${pack_rows}" | awk -F '\t' -v p="${pack}" '$2 == p { print $1 }' | sort)
  if [[ -f ${skills_dir}/pjp-pack-${pack}/SKILL.md ]]; then
    while IFS= read -r skill; do
      want_rows+="${skill}"$'\t'"name-only"$'\n'
    done <<<"${members}"
  elif [[ ${any_entry} == 1 ]]; then
    warn "pack ${pack} の入口 ${skills_dir}/pjp-pack-${pack} がありません。次の skill は説明つきのまま残します: ${members//$'\n'/, }" \
      "claude-skills の clone が古いか、入口の名前が変わった・消えたか、skill の metadata の pjp-pack を書き違えています。"
  else
    no_entry_count=$((no_entry_count + $(wc -l <<<"${members}")))
  fi
done <<<"${packs}"
if [[ ${no_entry_count} -gt 0 ]]; then
  note "pack の入口 (${skills_dir}/pjp-pack-*) が 1 つも無いので、pack の skill (${no_entry_count} 本) は説明つきのまま残します (claude-skills を取れないマシン・入口がまだ無い版)。"
fi

# claude.ai から同期された skill。settings.json を共有するアカウントの dir の分も読む
config_dirs=("${HOME}/.claude")
if [[ -r ${accounts_file} ]]; then
  accounts=$(jq -r 'if type == "array" then .[] | strings else empty end' "${accounts_file}" 2>/dev/null || true)
  while IFS= read -r account; do
    if [[ ${account} =~ ${plain_re} ]]; then
      config_dirs+=("${HOME}/.claude-${account}")
    fi
  done <<<"${accounts}"
fi
for dir in "${config_dirs[@]}"; do
  for f in "${dir}"/skills/synced/*/*/SKILL.md; do
    synced=$(basename -- "$(dirname -- "${f}")")
    if [[ ${synced} =~ ${plain_re} && ${synced} != . && ${synced} != .. ]]; then
      want_rows+="anthropic-skills:${synced}"$'\t'"user-invocable-only"$'\n'
    fi
  done
done

want=$(printf '%s' "${want_rows}" | jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries')

# ---- settings.json の skillOverrides と控えを組む ----

# 出すもの: {settings: 書いた後の settings.json, record: 控える key と値, log: [{act, key, value, …}]}
#   act: host (host option の値を書いた)・add (書いた)・update (控えた値から書き換えた)・revert (戻した)・
#        keep (手で書いた値を残した)
# shellcheck disable=SC2016 # jq の式の $ は jq の変数
result=$(jq -c --argjson host "${host_values}" --argjson want "${want}" --argjson rec "${record}" '
  . as $doc
  | ($doc.skillOverrides // {}) as $before
  | ($want | with_entries(select(.key as $k | $host | has($k) | not))) as $want
  | reduce ([$want, $rec] | map(keys[]) | unique[]) as $k (
      {s: $before, rec: {}, log: []};
      $want[$k] as $d | $rec[$k] as $r | .s[$k] as $cur
      | if $d != null then
          if $cur == null then .s[$k] = $d | .rec[$k] = $d | .log += [{act: "add", key: $k, value: $d}]
          elif $cur == $d then .rec[$k] = $d
          elif $r != null and $cur == $r then
            .s[$k] = $d | .rec[$k] = $d | .log += [{act: "update", key: $k, value: $d, from: $cur}]
          else .log += [{act: "keep", key: $k, value: $cur, want: $d}]
          end
        elif $cur != null and $cur == $r then .s |= del(.[$k]) | .log += [{act: "revert", key: $k, value: $r}]
        else .
        end)
  | .log += [$host | to_entries[] | select($before[.key] != .value) | {act: "host", key, value}]
  | .s += $host
  | . as $st
  | {
      settings: (if $st.s == {} and ($doc | has("skillOverrides") | not) then $doc else $doc | .skillOverrides = $st.s end),
      record: $st.rec,
      log: $st.log
    }
' <<<"${current}")

new_settings=$(jq '.settings' <<<"${result}")
new_record=$(jq -c '{version: 1, keys: .record}' <<<"${result}")

tmp=""
# jq が落ちたときに settings.json の隣へ中間ファイルを残さない。
trap 'if [[ -n ${tmp} ]]; then rm -f "${tmp}"; fi' EXIT

wrote=0
if ! jq -e --argjson new "${new_settings}" '. == $new' <<<"${current}" >/dev/null; then
  mkdir -p "$(dirname "${settings}")"
  tmp=$(mktemp "${settings}.XXXXXX")
  printf '%s\n' "${new_settings}" >"${tmp}"
  mv "${tmp}" "${settings}"
  tmp=""
  wrote=1
fi

# 控えは中身が変わったときだけ書く。控える key が無く、ファイルも無ければ作らない
if [[ -e ${record_file} ]] || ! jq -e '.keys == {}' <<<"${new_record}" >/dev/null; then
  if [[ ! -e ${record_file} ]] || ! jq -e --argjson new "${new_record}" '. == $new' "${record_file}" >/dev/null 2>&1; then
    mkdir -p "${state_dir}"
    tmp=$(mktemp "${record_file}.XXXXXX")
    printf '%s\n' "${new_record}" >"${tmp}"
    mv "${tmp}" "${record_file}"
    tmp=""
  fi
fi

# 何をしたかを、した事と値ごとに 1 行で出す
# shellcheck disable=SC2016 # jq の式の $ は jq の変数
log_lines=$(jq -r '
  .log | group_by([.act, .value, .want]) | .[]
  | .[0] as $e | (map(.key) | join(", ")) as $keys
  | if $e.act == "host" then "host option の値を書きました (\($e.value)): \($keys)"
    elif $e.act == "add" then "書きました (\($e.value)): \($keys)"
    elif $e.act == "update" then "書き換えました (\($e.value)): \($keys)"
    elif $e.act == "revert" then "戻しました (\($e.value) を消した): \($keys)"
    else "手で書いた値を残しました (\($e.value)。この script が書くなら \($e.want)): \($keys)"
    end
' <<<"${result}")
if [[ -n ${log_lines} ]]; then
  note "${log_lines}"
fi

if [[ ${wrote} == 1 ]]; then
  note "書き直しました: ${settings} の skillOverrides"
  note "新しい Claude Code の session から効きます (実行中の session は再起動するか /compact)。確認: /skills"
else
  note "書き直すものはありません: ${settings} の skillOverrides"
fi
