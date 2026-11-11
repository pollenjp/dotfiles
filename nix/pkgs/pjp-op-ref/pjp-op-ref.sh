#!/usr/bin/env bash
# shellcheck shell=bash
#
# pjp-op-ref: 1Password の参照 (op://vault/項目/[セクション/]欄) を、vault・項目・セクション・欄の ID の参照に直して出す。
# nix/pkgs/pjp-op-ref が bin/pjp-op-ref として包み (jq を PATH に足す)、home/modules/op-env.nix が dotfiles.onePassword.enable
# のマシンの PATH に入れる。使い方は nix/README.md「参照を ID の形に直す (pjp-op-ref)」。設計は dotfiles-private の
# docs/superpowers/specs/2026-11-11-op-ref-id-design.md。
#
#   pjp-op-ref --reason "<なぜ読むか>" [--quiet] [--] <参照>...
#
# ## なぜ ID の参照か
#
#   参照は vault・項目・セクション・欄のどれも、名前の代わりに ID で書ける。名前は 1Password のアプリで変えられ、変えると名前の
#   参照は切れる。項目の ID が変わるのは、項目を別の vault に移したときだけ。ID は英小文字と数字なので、.env で引用符も要らない
#   (作りつけのセクションの ID には空白のあるもの (add more など) もある)。1Password のアプリの「Copy Secret Reference」は名前の
#   参照を出す (名前に使えない文字のある部分だけが ID になる)
#
# ## 流れ
#
#   1. 引数を読む。参照を op://・3 つか 4 つの部分 (/ で区切る)・? から後ろ (attribute など。そのまま後ろに付ける) に分ける。
#      形が合わなければ、op を呼ばずに 2
#   2. 参照を項目 (vault と項目の部分の組。大文字小文字は問わない) ごとにまとめ、初めて出た順に、項目ごとに 1 回だけ op を呼ぶ:
#        op [--reason "[pjp-op-ref: 参照 <N> 件を ID の形に直す (項目 <k>/<M>)。ID だけを抜き出し、値は捨てる] <理由>"] \
#          item get <項目> --vault <vault> --format json
#      (項目 …) は項目が 2 つ以上のときだけ。--reason は pjp-op のあるマシン (~/.local/state/dotfiles/claude-op-reason.json の
#      enable が true。home/modules/op-reason.nix が書く) でだけ付ける。素の op に --reason は無い。同じ項目でも書き方 (名前か
#      ID か) が違えば別に読む (op の出力は、次の項目のために残さない)
#   3. op の stdout は jq にだけ流す。jq は vault と項目の ID を取り、セクションと欄を ID か名前 (大文字小文字は問わない) で
#      当てて、ID の参照か、当たったものの件数 (0 件・2 件以上) だけを出す。参照にセクションが無くても、欄にセクションが
#      あればセクションの ID を入れる。セクションの無い欄は op://<vault>/<項目>/<欄>
#   4. どの参照も直せたら、渡した順に 1 行ずつ stdout に出す。1 つでも直せなければ何も出さずに止まり、残りの項目は読まない
#
# ## 値を外に出さない
#
#   op item get --format json は、隠す欄 (CONCEALED) の値も含みうる。その出力は op から jq へのパイプだけを通し、shell の変数・
#   ファイル・端末・引数に入れない。
#   - jq が出すのは ID と件数だけ。jq の stderr は捨てる (jq の型の誤りの文は、入力の値を入れて出すことがある)
#   - 誤りの文に書くのは参照 (名前)・件数・終了コードだけ。記録は書かず、一時ファイルを使わない
#   - xtrace: 最初の行で set +x +a +m (呼び手の SHELLOPTS・BASH_ENV が付けていても外す。job control が付いていると lastpipe が
#     効かず、jq の出力を受け損なう)
#   - stdin は op にそのまま継ぐ (</dev/null にすると、op が空の入力として読みうる。op item create はそうなる)
#
# ## 終了コード
#
#   0 = 直せた・--help / 1 = セクションか欄が見つからない・2 件以上ある / 2 = 引数の誤り / 70 = op の出力の形が合わない /
#   127 = op か jq が無い / op の終了コード = op が 0 以外で終わった
#
# ## テストのための口 (nix/tests/pjp-op-ref.test.sh)
#
#   PJP_OP_REF_OP   呼ぶ op (既定は PATH の op)

set +x +a +m
set -u -o pipefail
# パイプの最後の mapfile を今のシェルで流す (job control の無い script でだけ効くので、上で +m)
shopt -s lastpipe

me=pjp-op-ref
usage_line='使い方: pjp-op-ref --reason "<なぜ読むか>" [--quiet] [--] <参照>...'
example='例: pjp-op-ref --reason "bot の .env に書く参照を ID の形にする" "op://Private/Example API/prod/password"'

say() {
  local line
  for line in "$@"; do
    printf '%s: %s\n' "${me}" "${line}" >&2
  done
}

die() {
  local code=$1
  shift
  say "$@"
  exit "${code}"
}

usage() {
  printf '%s\n' \
    "${usage_line}" \
    '' \
    '1Password の参照 (op://vault/項目/[セクション/]欄) を、vault・項目・セクション・欄の ID の参照に直して 1 行ずつ出します。' \
    '名前は変えられ、変えると名前の参照は切れるので、.env には ID の参照を書きます。値は出しません (op の出力から ID だけを抜き出す)。' \
    'op は項目ごとに 1 回呼びます (同じ項目の参照はまとめる)。WSL の op (pjp-op) では、そのたびに承認の画面が出ます。' \
    '' \
    '  --reason <理由>  何のために読むかを 1 文で (必須)。WSL の op (pjp-op) では承認の窓と記録に出ます' \
    '  -q, --quiet      終わりの 1 行を出しません' \
    '' \
    "${example}" \
    '詳しくは dotfiles の nix/README.md「参照を ID の形に直す (pjp-op-ref)」。'
}

# --- 引数

reason=""
have_reason=0
quiet=0
refs=()
while (($# > 0)); do
  case $1 in
    --reason)
      (($# >= 2)) || die 2 "--reason の後ろに理由がありません。" "${usage_line}"
      reason=$2
      have_reason=1
      shift 2
      ;;
    --reason=*)
      reason=${1#--reason=}
      have_reason=1
      shift
      ;;
    -q | --quiet)
      quiet=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      refs+=("$@")
      break
      ;;
    -*) die 2 "知らない option です: $1" "${usage_line}" ;;
    *)
      refs+=("$1")
      shift
      ;;
  esac
done

((have_reason)) || die 2 "理由 (--reason) がありません。何のために読むかを 1 文で書いてください。" "${example}"
# 制御文字 (改行・タブも) を空白にし、前後の空白を外す
reason=${reason//[[:cntrl:]]/ }
reason=${reason#"${reason%%[![:space:]]*}"}
reason=${reason%"${reason##*[![:space:]]}"}
[[ -n ${reason} ]] || die 2 "理由 (--reason) が空です。何のために読むかを 1 文で書いてください。"
((${#refs[@]} > 0)) || die 2 "直す参照がありません。" "${usage_line}"

# --- 参照を分ける

vaults=()
items=()
sections=() # 空 = 参照にセクションが無い
fields=()
queries=() # ? から後ろ (無ければ空)
for i in "${!refs[@]}"; do
  n=$((i + 1))
  ref=${refs[i]}
  # 前後の空白を外す (貼ったときに付きがち)
  ref=${ref#"${ref%%[![:space:]]*}"}
  ref=${ref%"${ref##*[![:space:]]}"}
  refs[i]=${ref}
  [[ ${ref} != *[[:cntrl:]]* ]] || die 2 "${n} 番目の参照に制御文字があります。"
  [[ ${ref} == op://* ]] || die 2 "${n} 番目の参照が op:// で始まっていません: ${ref}" \
    "参照の形: op://<vault>/<項目>/[<セクション>/]<欄>[?attribute=…]"
  body=${ref#op://}
  query=""
  if [[ ${body} == *'?'* ]]; then
    query="?${body#*\?}"
    body=${body%%\?*}
  fi
  slashes=${body//[^\/]/}
  case ${#slashes} in
    2 | 3) ;;
    *)
      die 2 "${n} 番目の参照の部分が 3 つか 4 つでありません: ${ref}" \
        "参照の形: op://<vault>/<項目>/[<セクション>/]<欄>[?attribute=…]"
      ;;
  esac
  vault=${body%%/*}
  rest=${body#*/}
  item=${rest%%/*}
  rest=${rest#*/}
  section=""
  if ((${#slashes} == 3)); then
    section=${rest%%/*}
    [[ -n ${section} ]] || die 2 "${n} 番目の参照のセクションが空です: ${ref}"
    rest=${rest#*/}
  fi
  field=${rest}
  [[ -n ${vault} && -n ${item} && -n ${field} ]] || die 2 "${n} 番目の参照に空の部分があります: ${ref}"
  # vault と項目は op の引数になるので、- で始まると option と読まれる
  [[ ${vault} != -* && ${item} != -* ]] \
    || die 2 "${n} 番目の参照の vault か項目が - で始まります (op が option と読む)。その部分を ID で書いてください: ${ref}"
  vaults[i]=${vault}
  items[i]=${item}
  sections[i]=${section}
  fields[i]=${field}
  queries[i]=${query}
done

# 項目ごとにまとめる (初めて出た順)
declare -A group_of=()
group_first=()   # 項目ごとの最初の参照の番号
group_members=() # 項目ごとの参照の番号 (空白区切り)
for i in "${!refs[@]}"; do
  key="${vaults[i],,}/${items[i],,}"
  if [[ -z ${group_of[${key}]+set} ]]; then
    group_of[${key}]=${#group_first[@]}
    group_first+=("${i}")
    group_members+=("")
  fi
  g=${group_of[${key}]}
  group_members[g]+="${i} "
done
ngroups=${#group_first[@]}

# --- op と jq

op=$(type -P -- "${PJP_OP_REF_OP:-op}") \
  || die 127 "op (1Password CLI) が見つかりません。参照を ID の形に直せません。" \
    "op を入れてから打ち直すか、参照を名前の形のまま書いてください。"
jq=$(type -P -- jq) || die 127 "jq が見つかりません (dotfiles の pjp-op-ref は jq を PATH に足して包みます)。"

use_reason=0
if [[ -n ${HOME:-} && -r ${HOME}/.local/state/dotfiles/claude-op-reason.json ]]; then
  state=$(<"${HOME}/.local/state/dotfiles/claude-op-reason.json")
  if [[ ${state} =~ \"enable\"[[:space:]]*:[[:space:]]*true ]]; then
    use_reason=1
  fi
fi

# jq の program。入力は op item get --format json の 1 項目。$ARGS.named の n (参照の件数) と s<k>・f<k> (k 番目の参照の
# セクションと欄。セクションが無ければ空) を読み、参照ごとに 1 行出す:
#   ok<TAB><ID の参照 (? から後ろは除く)>
#   ng<TAB><section-missing|section-many|field-missing|field-many><TAB><当たった件数>
# 項目が 1 つでない・vault か項目の ID が無い・sections や fields が配列でない・使う ID に制御文字や / や ? があれば、error で
# 止まる (終了コードが 0 でなくなる。誤りの文は捨てる)
read -r -d '' filter <<'JQ' || true
def lc: ascii_downcase;
def str: if type == "string" then . else "" end;
def arr: if . == null then [] elif type == "array" then . else error("shape") end;
def ok_id: type == "string" and . != "" and (test("[[:cntrl:]/?]") | not);
[inputs] as $all
| if ($all | length) == 1 and ($all[0] | type) == "object" then $all[0] else error("shape") end
| . as $it
| ($it.vault | if type == "object" then .id else null end) as $vid
| $it.id as $iid
| if ($vid | ok_id) and ($iid | ok_id) then . else error("shape") end
| ($it.fields | arr | map(objects
    | {id: (.id | str), label: (.label | str), sid: (.section | if type == "object" then (.id | str) else "" end)})) as $fields
| ([($it.sections | arr | .[] | objects | {id: (.id | str), label: (.label | str)}),
    ($it.fields | arr | .[] | objects | .section | objects | {id: (.id | str), label: (.label | str)})]
   | map(select(.id != "")) | unique_by(.id)) as $sections
| range(0; $ARGS.named.n | tonumber) as $k
| $ARGS.named["s\($k)"] as $s
| $ARGS.named["f\($k)"] as $f
| (if $s == "" then {sid: null}
   else [$sections[] | select((.id | lc) == ($s | lc) or (.label | lc) == ($s | lc))] as $m
   | if ($m | length) == 1 then {sid: $m[0].id}
     elif ($m | length) == 0 then {ng: "section-missing", n: 0}
     else {ng: "section-many", n: ($m | length)} end
   end) as $sec
| if $sec.ng then "ng\t\($sec.ng)\t\($sec.n)"
  else [$fields[] | select($sec.sid == null or .sid == $sec.sid)
      | select(.id != "" and ((.id | lc) == ($f | lc) or (.label | lc) == ($f | lc)))] as $m
  | if ($m | length) == 0 then "ng\tfield-missing\t0"
    elif ($m | length) > 1 then "ng\tfield-many\t\($m | length)"
    elif ($m[0].id | ok_id) and ($m[0].sid == "" or ($m[0].sid | ok_id)) then
      "ok\top://\($vid)/\($iid)/" + (if $m[0].sid == "" then "" else "\($m[0].sid)/" end) + $m[0].id
    else error("shape") end
  end
JQ

# --- 項目ごとに 1 回 op を呼ぶ

out=()
for ((g = 0; g < ngroups; g++)); do
  first=${group_first[g]}
  read -r -a members <<<"${group_members[g]}"
  opargs=()
  if ((use_reason)); then
    count=""
    ((ngroups == 1)) || count=" (項目 $((g + 1))/${ngroups})"
    opargs+=(--reason "[pjp-op-ref: 参照 ${#members[@]} 件を ID の形に直す${count}。ID だけを抜き出し、値は捨てる] ${reason}")
  fi
  jqargs=(--arg n "${#members[@]}")
  for k in "${!members[@]}"; do
    jqargs+=(--arg "s${k}" "${sections[members[k]]}" --arg "f${k}" "${fields[members[k]]}")
  done
  where="${vaults[first]}/${items[first]}"
  left=$((ngroups - g - 1))
  rest_note=""
  ((left == 0)) || rest_note="残りの項目 ${left} 件は読んでいません。"

  # op の stdout は jq にだけ渡す。jq の stdout (ID と件数) は mapfile で受ける
  lines=()
  "${op}" "${opargs[@]}" item get "${items[first]}" --vault "${vaults[first]}" --format json \
    | "${jq}" -n -r "${jqargs[@]}" "${filter}" 2>/dev/null \
    | mapfile -t lines
  st=("${PIPESTATUS[@]}")
  op_rc=${st[0]:-1}
  jq_rc=${st[1]:-1}
  if ((op_rc != 0)); then
    # jq が先に止まって op が SIGPIPE で終わったときは、出力の形の誤りとして扱う
    if ((op_rc == 141 && jq_rc != 0)); then
      die 70 "op の出力 (${where}) の形が合わないので止めます。出力は表示しません。${rest_note}"
    fi
    die "${op_rc}" "op が終了コード ${op_rc} で終わったので止めます (${where})。${rest_note}"
  fi
  if ((jq_rc != 0 || ${#lines[@]} != ${#members[@]})); then
    die 70 "op の出力 (${where}) の形が合わないので止めます。出力は表示しません。${rest_note}"
  fi

  errors=()
  for k in "${!members[@]}"; do
    i=${members[k]}
    line=${lines[k]}
    label="$((i + 1)) 番目の参照 ${refs[i]}"
    case ${line} in
      ok$'\t'op://*)
        out[i]=${line#ok$'\t'}${queries[i]}
        ;;
      ng$'\t'section-missing$'\t'*)
        errors+=("${label}: セクション「${sections[i]}」が項目にありません (0 件)。")
        ;;
      ng$'\t'section-many$'\t'*)
        errors+=("${label}: セクション「${sections[i]}」に当たるセクションが ${line##*$'\t'} 件あります。セクションの ID で書いてください。")
        ;;
      ng$'\t'field-missing$'\t'*)
        errors+=("${label}: 欄「${fields[i]}」が${sections[i]:+セクション「${sections[i]}」に}ありません (0 件)。")
        ;;
      ng$'\t'field-many$'\t'*)
        errors+=("${label}: 欄「${fields[i]}」に当たる欄が ${line##*$'\t'} 件あります。セクションを足すか、欄の ID で書いてください。")
        ;;
      *) die 70 "op の出力 (${where}) の形が合わないので止めます。出力は表示しません。${rest_note}" ;;
    esac
  done
  if ((${#errors[@]} > 0)); then
    die 1 "${errors[@]}" "直せない参照があるので、何も出しません。${rest_note}"
  fi
done

# --- 出す

spaced=0
for i in "${!refs[@]}"; do
  printf '%s\n' "${out[i]}"
  [[ ${out[i]} != *[[:space:]]* ]] || spaced=1
done
if ((quiet == 0)); then
  if ((spaced)); then
    say '空白を含む参照があります。.env には引用符で囲んで書いてください (KEY="op://…")。'
  fi
  say "参照 ${#refs[@]} 件を ID の形に直しました (op を ${ngroups} 回呼びました)。"
fi
