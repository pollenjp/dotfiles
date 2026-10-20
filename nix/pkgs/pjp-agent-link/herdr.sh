#!/usr/bin/env bash
# shellcheck shell=bash
#
# herdr を包む (ADR 025)。home の bin/herdr (~/.nix-profile/bin/herdr) はこれで、最後に本物の herdr を exec する。
#
# herdr --remote (hr) は ssh 先で、ログイン shell の command -v herdr で見つけた絶対パス (= これ) を
# `exec <パス> [--session <名前>] remote-client-bridge` で直に打つ。shell の関数を通らないので、server に固定名を
# 渡す役はこの実行ファイルに置く (前は fish・bash の herdr 関数だった。ADR 008)。
#
# server を起こしうる呼び出しでは、SSH_AUTH_SOCK をその session の固定名にしてから exec する (server と pane は
# それを継ぐ)。attach する呼び出しでは、pjp-agent-link open attach で向け先を決め直してから渡す。
#
#   attach (決め直す)   herdr (サブコマンドなし)・herdr session attach <名前>・herdr remote-client-bridge [...]
#   start (渡すだけ)    herdr server (headless の server を起こす)
#   それ以外            何もしない (status・pane・server stop・--remote・--version など)
#
# herdr 0.9.1 で server を起こすのは auto_detect_launch (サブコマンドなしと session attach) と
# ensure_remote_server_running (remote-client-bridge) の 2 か所。server live-handoff と update --handoff は、動いている
# server が新しい server を起こす (server の env を継ぐ) ので何もしない。session は herdr と同じく、`--` より前の
# --session <名前>・--session=<名前>、session attach <名前>、HERDR_SESSION、default の順に決める。
#
# 気を付けること:
#   - bridge の stdin は herdr の通信なので、pjp-agent-link には </dev/null を渡して 1 byte も読ませない。
#     stdout は $(…) で受け、stderr は捨てる (bridge の stdout・stderr に何も混ぜない)
#   - PATH は変えない (server と pane が継ぐ)。pjp-agent-link と本物の herdr は store の絶対パスで呼ぶ
#   - pjp-agent-link が失敗しても、時間切れ (10 秒) でも、元の env のまま herdr を exec する
#
# 下の real・agent・timeout の値は herdr.nix が store のパスに置き換える (テストは偽物に置き換えた写しを流す)。

real=@herdr@
agent=@agentLink@
timeout=@timeout@

session=""
session_given=0
want_session=0
passthru=0
pos=()
for arg in "$@"; do
  if ((want_session)); then
    session=${arg}
    want_session=0
    continue
  fi
  case ${arg} in
    --) break ;;
    --session)
      want_session=1
      session_given=1
      ;;
    --session=*)
      session=${arg#--session=}
      session_given=1
      ;;
    -h | --help | -V | --version | --default-config | --skill | --remote | --remote=* | --remote-keybindings | \
      --remote-keybindings=* | --machine | --machine=*)
      passthru=1
      ;;
    -*) ;;
    *) pos+=("${arg}") ;;
  esac
done
# 値の無い --session (末尾の --session・--session=) は herdr がエラーにするので、何もしない
if ((want_session)) || { ((session_given)) && [[ -z ${session} ]]; }; then
  passthru=1
fi

mode=""
if ((! passthru)); then
  if ((${#pos[@]} == 0)) || [[ ${pos[0]} == remote-client-bridge ]]; then
    mode=attach
  elif [[ ${pos[0]} == session && ${pos[1]-} == attach && ${#pos[@]} == 3 && ${pos[2]} != help ]]; then
    mode=attach
    session=${pos[2]}
  elif [[ ${pos[0]} == server && ${#pos[@]} == 1 ]]; then
    mode=start
  fi
fi

if [[ -n ${mode} ]]; then
  if sock=$("${timeout}" -k 1 10 "${agent}" open "${mode}" "${session:-${HERDR_SESSION:-default}}" </dev/null 2>/dev/null) \
    && [[ ${sock} == /* ]]; then
    export SSH_AUTH_SOCK=${sock}
  fi
fi

exec "${real}" "$@"
