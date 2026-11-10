#!/usr/bin/env bash
# shellcheck shell=bash
#
# pjp-op-env: .env の op:// の参照を 1 回の op で解き、値を環境変数に入れて program を起こす。nix/pkgs/pjp-op-env が
# bin/pjp-op-env として包み、home/modules/op-env.nix が dotfiles.onePassword.enable のマシンの PATH に入れる。使い方は
# nix/README.md「シークレットを .env の参照から渡す (pjp-op-env)」。設計は dotfiles-private の
# docs/superpowers/specs/2026-11-10-secrets-op-env-design.md。
#
#   pjp-op-env --reason "<なぜ値を読むか>" [--env-file <path>]... [--quiet] [--] <program> [<引数>...]
#   pjp-op-env --dry-run [--env-file <path>]...
#
# ## 流れ
#
#   1. 引数を読む。--env-file が無ければ今の dir の .env を読む (複数なら後のファイルが勝つ)
#   2. .env を 1 行ずつ文字列として読む (source も eval もしない)。読めない行があれば、ファイル名と行番号だけを出して 2
#   3. 起こす program の実行ファイルを PATH から引く (.env の PATH で替わらないよう、入れる前に引く)。無ければ op を呼ばずに 127
#   4. 値の全体が op:// で始まるものを参照として集め、参照があれば op を 1 回だけ呼ぶ:
#        op [--reason "<理由> (pjp-op-env が <program> に渡す: <参照>, …)"] inject
#      stdin には、参照ごとに乱数の境界の印の行と {{ <参照> }} の行を並べたテンプレートを流し、stdout はパイプで受けて
#      bash の変数にだけ置く。--reason は pjp-op のあるマシン (~/.local/state/dotfiles/claude-op-reason.json の enable が
#      true。home/modules/op-reason.nix が書く) でだけ付ける。素の op に --reason は無い
#   5. op が 0 以外で終われば、その終了コードで終わる。出力に NUL がある・境界の印の数や順が合わないなら 70 で終わる
#   6. op の認証の環境変数 (OP_SERVICE_ACCOUNT_TOKEN・OP_CONNECT_HOST・OP_CONNECT_TOKEN・OP_SESSION_*) を外し、.env の名前と
#      値 (参照は解いた値) を export して、exec で自分を program に置き換える (argv[0] は打った名前のまま)
#
# ## 値を外に出さない
#
#   - ディスク: 一時ファイルを使わない。テンプレートは stdin のパイプで渡し、op の stdout はパイプで受ける
#   - argv: 値を引数に載せない。op に渡すのは理由と inject だけで、export は組み込みのコマンド、program へは exec で置き換わる
#     (外のコマンドを起こさない。だから package は runtimeInputs を持たず、program の PATH も変えない)
#   - 評価: .env を shell の式として読まない。値の $・`・引用符・空白は文字のまま渡す
#   - 出力: 値を表示しない。誤りの文に書くのはファイル名・行番号・名前・件数・終了コードだけ。記録は書かない
#   - xtrace: 最初の行で set +x +a (呼び手の SHELLOPTS・BASH_ENV が付けていても外す)
#   - 中の変数: 名前を _poe_ で始め、始めに同じ頭の変数を消す。呼び手が export した名前に代入すると、その値が program に
#     渡る。.env の名前を export すると同じ名前の shell の変数が替わるので、.env の _poe_* は読めない行にする
#   - lock と窓: op の出力を読み切り、op が終わってから program を起こす。WSL の op (pjp-op) は op が終わるまで lock と承認の
#     窓を持つので、op run のように program の間ずっと持たせない
#
# ## 終了コード
#
#   program の終了コード (起こした後) / 0 = --dry-run・--help / 2 = 引数・.env の誤り / 70 = op の出力の形が合わない /
#   127 = program か op が無い / op の終了コード = op が 0 以外で終わった (program は起こさない)
#
# ## テストのための口 (nix/tests/pjp-op-env.test.sh)
#
#   PJP_OP_ENV_OP   呼ぶ op (既定は PATH の op)

set +x +a
set -u -o pipefail
# パイプの最後の mapfile を今のシェルで流し、op の出力をサブシェルに渡さない (job control の無い script でだけ効く)
shopt -s lastpipe

for _poe_name in "${!_poe_@}"; do
  unset "${_poe_name}"
done
unset _poe_name

_poe_me=pjp-op-env
_poe_usage_line='使い方: pjp-op-env --reason "<なぜ値を読むか>" [--env-file <path>]... [--quiet] [--] <program> [<引数>...]'
# bash が読み取り専用にしている名前 (export できない)
_poe_readonly=' BASHOPTS BASH_VERSINFO EUID PPID SHELLOPTS UID '

_poe_say() {
  local _poe_line
  for _poe_line in "$@"; do
    printf '%s: %s\n' "${_poe_me}" "${_poe_line}" >&2
  done
}

_poe_die() {
  local _poe_code=$1
  shift
  _poe_say "$@"
  exit "${_poe_code}"
}

_poe_usage() {
  printf '%s\n' \
    "${_poe_usage_line}" \
    '       pjp-op-env --dry-run [--env-file <path>]...' \
    '' \
    '.env の op:// の参照 (op://vault/項目/欄) を 1 回の op で解き、値を環境変数に入れて program を起こします。' \
    '値はファイル・端末・引数に出さず、op が終わってから program を起こします (WSL の op の lock と承認の窓を持ち続けません)。' \
    '' \
    '  --reason <理由>    何のために何を読むかを 1 文で (必須)。WSL の op (pjp-op) では承認の窓と記録に出ます' \
    '  --env-file <path>  読む .env (繰り返せる。後のファイルが勝つ)。無ければ今の dir の .env' \
    '  --dry-run          op を呼ばず、.env の名前と種類 (参照か値か) を出します。参照でない値は出しません' \
    '  -q, --quiet        起こす前の 1 行を出しません' \
    '' \
    '.env の書き方・終了コード・安全である理由は dotfiles の nix/README.md「シークレットを .env の参照から渡す (pjp-op-env)」。'
}

# --- 引数

_poe_reason=""
_poe_have_reason=0
_poe_dry_run=0
_poe_quiet=0
_poe_files=()
while (($# > 0)); do
  case $1 in
    --reason)
      (($# >= 2)) || _poe_die 2 "--reason の後ろに理由がありません。" "${_poe_usage_line}"
      _poe_reason=$2
      _poe_have_reason=1
      shift 2
      ;;
    --reason=*)
      _poe_reason=${1#--reason=}
      _poe_have_reason=1
      shift
      ;;
    --env-file)
      (($# >= 2)) || _poe_die 2 "--env-file の後ろにファイルがありません。" "${_poe_usage_line}"
      _poe_files+=("$2")
      shift 2
      ;;
    --env-file=*)
      _poe_files+=("${1#--env-file=}")
      shift
      ;;
    --dry-run)
      _poe_dry_run=1
      shift
      ;;
    -q | --quiet)
      _poe_quiet=1
      shift
      ;;
    -h | --help)
      _poe_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*) _poe_die 2 "知らない option です: $1" "${_poe_usage_line}" ;;
    *) break ;;
  esac
done
((${#_poe_files[@]} > 0)) || _poe_files=(.env)

if ((_poe_dry_run == 0)); then
  (($# > 0)) || _poe_die 2 "起こす program がありません。" "${_poe_usage_line}"
  ((_poe_have_reason)) || _poe_die 2 "理由 (--reason) がありません。何のために何を読むかを 1 文で書いてください。" \
    '例: pjp-op-env --reason "kabu の bot を起こすのに API パスワードを読む" -- ./target/release/bot'
  # 制御文字 (改行・タブも) を空白にし、前後の空白を外す
  _poe_reason=${_poe_reason//[[:cntrl:]]/ }
  _poe_reason=${_poe_reason#"${_poe_reason%%[![:space:]]*}"}
  _poe_reason=${_poe_reason%"${_poe_reason##*[![:space:]]}"}
  [[ -n ${_poe_reason} ]] || _poe_die 2 "理由 (--reason) が空です。何のために何を読むかを 1 文で書いてください。"
fi

# --- .env を読む

_poe_keys=()  # 名前 (初めて出た順)
_poe_vals=()  # 値 (参照なら参照の文字列)
_poe_isref=() # 1 = 参照
_poe_where=() # ファイル:行
declare -A _poe_pos=()

# _poe_bad <ファイル> <行> <わけ>: 読めない行で止める。行の中身は出さない (平文の値かもしれない)
_poe_bad() {
  _poe_die 2 "$1:$2: 読めない行です ($3)。行の中身は表示しません。" \
    "書ける形: KEY=値・KEY='値'・KEY=\"値\"・KEY=op://vault/項目/欄・export KEY=値 (# で始まる行と空行は飛ばす)"
}

# _poe_put <名前> <値> <参照なら 1> <ファイル:行>: 名前と値を覚える。同じ名前は後のものが勝つ
_poe_put() {
  local _poe_i
  if [[ -n ${_poe_pos[$1]+set} ]]; then
    _poe_i=${_poe_pos[$1]}
  else
    _poe_i=${#_poe_keys[@]}
    _poe_pos[$1]=${_poe_i}
    _poe_keys[_poe_i]=$1
  fi
  _poe_vals[_poe_i]=$2
  _poe_isref[_poe_i]=$3
  _poe_where[_poe_i]=$4
}

# _poe_value <= の後ろ>: 引用符とコメントを解いた値を _poe_got に入れる。読めなければ _poe_why にわけを入れて 1
_poe_value() {
  local LC_ALL=C _poe_raw=$1 _poe_rest _poe_c
  _poe_rest=${_poe_raw#"${_poe_raw%%[![:space:]]*}"}
  case ${_poe_rest} in
    "'"*)
      # '…' は中をそのまま
      _poe_rest=${_poe_rest:1}
      if [[ ${_poe_rest} != *"'"* ]]; then
        _poe_why="引用符 ' が閉じていない"
        return 1
      fi
      _poe_got=${_poe_rest%%"'"*}
      _poe_rest=${_poe_rest#*"'"}
      ;;
    '"'*)
      # "…" は \\ と \" だけを戻し、ほかの \ はそのまま。$ と ` は展開しない
      _poe_rest=${_poe_rest:1}
      _poe_got=""
      while :; do
        if [[ -z ${_poe_rest} ]]; then
          _poe_why='引用符 " が閉じていない'
          return 1
        fi
        _poe_c=${_poe_rest:0:1}
        if [[ ${_poe_c} == \\ ]]; then
          case ${_poe_rest:1:1} in
            \\ | \")
              _poe_got+=${_poe_rest:1:1}
              _poe_rest=${_poe_rest:2}
              ;;
            *)
              _poe_got+=\\
              _poe_rest=${_poe_rest:1}
              ;;
          esac
        elif [[ ${_poe_c} == '"' ]]; then
          _poe_rest=${_poe_rest:1}
          break
        else
          _poe_got+=${_poe_c}
          _poe_rest=${_poe_rest:1}
        fi
      done
      ;;
    *)
      # 引用符なし: 空白に続く # から後ろはコメント。前後の空白を外す
      _poe_rest=${_poe_raw}
      if [[ ${_poe_rest} == *[[:space:]]'#'* ]]; then
        _poe_rest=${_poe_rest%%[[:space:]]#*}
      fi
      _poe_rest=${_poe_rest#"${_poe_rest%%[![:space:]]*}"}
      _poe_got=${_poe_rest%"${_poe_rest##*[![:space:]]}"}
      return 0
      ;;
  esac
  # 閉じた引用符の後ろに置けるのは、空白と # のコメントだけ
  if [[ ! ${_poe_rest} =~ ^[[:space:]]*(#.*)?$ ]]; then
    _poe_why="引用符の後ろに余計な文字がある"
    return 1
  fi
  return 0
}

# _poe_read <ファイル>: .env を 1 行ずつ読んで _poe_put する
_poe_read() {
  local LC_ALL=C _poe_file=$1 _poe_label=$1 _poe_n=0 _poe_line _poe_body _poe_key
  [[ -e ${_poe_file} ]] || _poe_die 2 "${_poe_file} がありません。--env-file で読むファイルを渡してください。"
  [[ ! -d ${_poe_file} && -r ${_poe_file} ]] || _poe_die 2 "${_poe_file} を読めません。"
  while IFS= read -r _poe_line || [[ -n ${_poe_line} ]]; do
    _poe_n=$((_poe_n + 1))
    _poe_line=${_poe_line%$'\r'}
    _poe_body=${_poe_line#"${_poe_line%%[![:space:]]*}"}
    [[ -n ${_poe_body} && ${_poe_body} != '#'* ]] || continue
    if [[ ${_poe_body} =~ ^export[[:space:]]+(.*)$ ]]; then
      _poe_body=${BASH_REMATCH[1]}
    fi
    [[ ${_poe_body} =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || _poe_bad "${_poe_label}" "${_poe_n}" "KEY=値 の形でない"
    _poe_key=${BASH_REMATCH[1]}
    _poe_value "${BASH_REMATCH[2]}" || _poe_bad "${_poe_label}" "${_poe_n}" "${_poe_why}"
    [[ ${_poe_key} != _poe_* ]] || _poe_bad "${_poe_label}" "${_poe_n}" "_poe_ で始まる名前は pjp-op-env が中で使う"
    [[ ${_poe_readonly} != *" ${_poe_key} "* ]] \
      || _poe_bad "${_poe_label}" "${_poe_n}" "${_poe_key} は bash が読み取り専用にしている名前"
    if [[ ${_poe_got} == op://* ]]; then
      # { } はテンプレートの {{ }} を壊し、制御文字は行の区切りを壊す
      [[ ${_poe_got} != *[{}]* && ${_poe_got} != *[[:cntrl:]]* ]] \
        || _poe_bad "${_poe_label}" "${_poe_n}" "参照に { } か制御文字がある"
      _poe_put "${_poe_key}" "${_poe_got}" 1 "${_poe_file}:${_poe_n}"
    else
      _poe_put "${_poe_key}" "${_poe_got}" 0 "${_poe_file}:${_poe_n}"
    fi
  done <"${_poe_file}"
}

for _poe_f in "${_poe_files[@]}"; do
  _poe_read "${_poe_f}"
done

_poe_refs=() # 参照 (名前の順)
for _poe_i in "${!_poe_keys[@]}"; do
  if ((_poe_isref[_poe_i])); then
    _poe_refs+=("${_poe_vals[_poe_i]}")
  fi
done

# --- --dry-run: op を呼ばず、名前と種類だけを出す (参照でない値は出さない)

if ((_poe_dry_run)); then
  _poe_nval=0
  for _poe_i in "${!_poe_keys[@]}"; do
    if ((_poe_isref[_poe_i])); then
      printf '%s\t%s\t参照\t%s\n' "${_poe_where[_poe_i]}" "${_poe_keys[_poe_i]}" "${_poe_vals[_poe_i]}"
    else
      _poe_nval=$((_poe_nval + 1))
      if [[ -z ${_poe_vals[_poe_i]} ]]; then
        printf '%s\t%s\t値 (空)\n' "${_poe_where[_poe_i]}" "${_poe_keys[_poe_i]}"
      else
        printf '%s\t%s\t値 (表示しない)\n' "${_poe_where[_poe_i]}" "${_poe_keys[_poe_i]}"
      fi
    fi
  done
  printf '参照 %d 件・値 %d 件。op は呼んでいません。\n' "${#_poe_refs[@]}" "${_poe_nval}"
  exit 0
fi

# --- 起こす program

_poe_argv0=$1
shift
_poe_prog=$(type -P -- "${_poe_argv0}") || _poe_die 127 "起こす program が見つかりません: ${_poe_argv0}"

# --- 参照を 1 回の op で解く

_poe_resolved=()
if ((${#_poe_refs[@]} > 0)); then
  _poe_op=$(type -P -- "${PJP_OP_ENV_OP:-op}") \
    || _poe_die 127 "op (1Password CLI) が見つかりません。参照を解けないので ${_poe_argv0} を起こしません。" \
      "値を平文で書いて回り込まず、op を入れるか、値の渡し方をユーザーに聞いてください。"
  [[ -n ${SRANDOM:-} ]] || _poe_die 2 "bash が古く、境界の印に使う乱数 (SRANDOM。bash 5.1 から) がありません。"

  _poe_opargs=()
  if [[ -n ${HOME:-} && -r ${HOME}/.local/state/dotfiles/claude-op-reason.json ]]; then
    _poe_state=$(<"${HOME}/.local/state/dotfiles/claude-op-reason.json")
    if [[ ${_poe_state} =~ \"enable\"[[:space:]]*:[[:space:]]*true ]]; then
      # 窓のコマンドは op inject だけになるので、読む参照 (同じものは 1 回) と渡す program を理由の後ろに足す
      _poe_list=""
      for _poe_r in "${_poe_refs[@]}"; do
        [[ ", ${_poe_list}, " == *", ${_poe_r}, "* ]] || _poe_list+=${_poe_list:+, }${_poe_r}
      done
      _poe_opargs+=(--reason "${_poe_reason} (pjp-op-env が ${_poe_argv0##*/} に渡す: ${_poe_list})")
    fi
  fi

  # テンプレート: 参照ごとに「<印>:<番号>」の行と「{{ <参照> }}」の行、最後に「<印>:end」の行。印は起動ごとの 128 bit の乱数
  printf -v _poe_mark 'pjp-op-env-%08x%08x%08x%08x' "${SRANDOM}" "${SRANDOM}" "${SRANDOM}" "${SRANDOM}"
  _poe_tmpl=""
  for _poe_j in "${!_poe_refs[@]}"; do
    _poe_tmpl+="${_poe_mark}:${_poe_j}"$'\n'"{{ ${_poe_refs[_poe_j]} }}"$'\n'
  done
  _poe_tmpl+="${_poe_mark}:end"$'\n'

  # op の stdout を mapfile で受ける。$(…) と違って末尾の改行を落とさず、NUL があれば 2 つ以上に分かれる
  _poe_chunks=()
  printf '%s' "${_poe_tmpl}" | "${_poe_op}" "${_poe_opargs[@]}" inject | mapfile -d '' _poe_chunks
  _poe_st=("${PIPESTATUS[@]}")
  _poe_rc=${_poe_st[1]:-1}
  if ((_poe_rc != 0)); then
    _poe_die "${_poe_rc}" "op が終了コード ${_poe_rc} で終わったので、${_poe_argv0} を起こしません。"
  fi
  if ((${#_poe_chunks[@]} != 1)); then
    _poe_die 70 "op の出力の形が合わない (NUL があるか空) ので、${_poe_argv0} を起こしません。出力は表示しません。"
  fi

  # _poe_split <出力>: 境界の印で区切って _poe_resolved に入れる。印の数・順・前後が合わなければ 1
  _poe_split() {
    local LC_ALL=C _poe_rest=$1 _poe_k _poe_m
    _poe_m="${_poe_mark}:0"$'\n'
    [[ ${_poe_rest} == "${_poe_m}"* ]] || return 1
    _poe_rest=${_poe_rest#"${_poe_m}"}
    for ((_poe_k = 1; _poe_k < ${#_poe_refs[@]}; _poe_k++)); do
      _poe_m=$'\n'"${_poe_mark}:${_poe_k}"$'\n'
      [[ ${_poe_rest} == *"${_poe_m}"* ]] || return 1
      _poe_resolved+=("${_poe_rest%%"${_poe_m}"*}")
      _poe_rest=${_poe_rest#*"${_poe_m}"}
    done
    _poe_m=$'\n'"${_poe_mark}:end"
    if [[ ${_poe_rest} == *"${_poe_m}"$'\n' ]]; then
      _poe_rest=${_poe_rest%"${_poe_m}"$'\n'}
    elif [[ ${_poe_rest} == *"${_poe_m}" ]]; then
      _poe_rest=${_poe_rest%"${_poe_m}"}
    else
      return 1
    fi
    _poe_resolved+=("${_poe_rest}")
    # 値の中に印が残っていれば、区切りがずれている
    for _poe_rest in "${_poe_resolved[@]}"; do
      [[ ${_poe_rest} != *"${_poe_mark}"* ]] || return 1
    done
    return 0
  }
  _poe_split "${_poe_chunks[0]}" \
    || _poe_die 70 "op の出力の形が合わない (境界の印の数か順) ので、${_poe_argv0} を起こしません。出力は表示しません。"
  unset _poe_chunks _poe_tmpl
fi

# --- 環境変数に入れて起こす

# 起こす前の 1 行 (.env の IFS などで形が替わらないよう、入れる前に作る)
if ((${#_poe_refs[@]} > 0)); then
  _poe_summary="参照 ${#_poe_refs[@]} 件を 1 回の op で解き、${#_poe_keys[@]} 個の変数を入れて ${_poe_argv0} を起こします: ${_poe_keys[*]}"
else
  _poe_summary="参照が無いので op を呼ばずに、${#_poe_keys[@]} 個の変数を入れて ${_poe_argv0} を起こします: ${_poe_keys[*]}"
fi

# op の認証は program に渡さない (program は op を知らない作り。token が子に渡ると vault を丸ごと読める)。.env に書いたものは
# この後で入る
unset OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN
for _poe_name in "${!OP_SESSION_@}"; do
  unset "${_poe_name}"
done

_poe_n=0
for _poe_i in "${!_poe_keys[@]}"; do
  if ((_poe_isref[_poe_i])); then
    export "${_poe_keys[_poe_i]}=${_poe_resolved[_poe_n]}" \
      || _poe_die 2 "${_poe_keys[_poe_i]} を環境変数に入れられません。"
    _poe_n=$((_poe_n + 1))
  else
    export "${_poe_keys[_poe_i]}=${_poe_vals[_poe_i]}" \
      || _poe_die 2 "${_poe_keys[_poe_i]} を環境変数に入れられません。"
  fi
done
unset _poe_resolved _poe_vals

((_poe_quiet)) || _poe_say "${_poe_summary}"
exec -a "${_poe_argv0}" -- "${_poe_prog}" "$@"
