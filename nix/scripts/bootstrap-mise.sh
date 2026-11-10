#!/usr/bin/env bash
# shellcheck shell=bash
#
# mise のグローバル設定 (~/.config/mise/config.toml) を初期化する。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 10
#
# ^ setup.sh が読む実行順。既定は 50 で、小さいほど先に走る。
#   bootstrap-claude-plugins.sh が claude を要求し、その claude を入れるのは
#   ここなので、辞書順 (bootstrap-mise は最後尾) より前に出す必要がある。
#
# mise-tools: aqua:jdx/usage go node claude
#
# ^ setup.sh が読む、この script が mise use -g で config.toml の [tools] に書く名前 (版は除く)。
#   setup の「残りの手作業」の手順 5 は、[tools] のうちこれ以外の名前 (前の setup や旧経路が書いた
#   もの・Nix に移した道具など) を、手で消すものとして並べる。下の mise use -g を足す・変える・消す
#   ときは、ここも直す (nix/tests/bootstrap-mise.test.sh が突き合わせる)。cursor-agent は [tools] に
#   書かない (on のホストだけ、conf.d に版を指した宣言を書く。下の cursor-agent の節) ので並べない。
#
# ## なぜ Nix で管理しないのか
#
# このファイルは mise 自身が実行時に書き換える (mise use --pin など)。
# store 上のファイルは read-only なので Nix 管理下には置けない。
#
# 投入も mise のコマンドで行う。config.toml は mise のスキーマであり、
# Nix 側にスナップショットを持たせると mise が形式を変えたときに
# 追随が必要になるため。`mise settings set` なら該当キーだけを触るので
# 既存の [tools] エントリも壊さない。
#
# ## なぜ home.activation でやらないのか
#
# `mise use -g` はネットワークアクセスとインストールを伴う。
# home-manager switch は hermetic に保ちたいので分けている。
#
# ## 役割分担
#
#   グローバルな CLI ツール    -> Nix (nix/home/modules/packages.nix。例外は下の claude と cursor-agent)
#   言語ランタイム (go/node)   -> mise (このスクリプト)
#   プロジェクト毎のツール固定 -> mise (各リポジトリの mise.toml)
#
# ## 遅延 (minimum_release_age) と、期間を区切った上書き (ADR 030)
#
# 遅延は dotfiles.mise.minimumReleaseAge (既定 9d)、期間を区切って緩める上書きは
# dotfiles.mise.releaseAgeOverrides (nix/home/options.nix)。home-manager が置く
# ~/.local/state/dotfiles/mise-release-age.json (nix/home/modules/mise-release-age.nix) を読み、
# 今日の日付 (Asia/Tokyo) から minimum_release_age に書く値を決める。home-manager の評価は
# 今日の日付を読めないので、上書きが始まったか・終わったかはここで決める。
#
#   上限      項目の from + zeroDays − 1 の日の終わり (23:59:59+09:00)。この時までに出た版を取る。
#             上限が先のうちは mise は 0d と同じに新しい版を取り、過ぎると遅延が 1 日ずつ伸びる
#   上書き中  from の日 ≤ 今日 ≤ 上限の日 + 既定の日数。上書き中の項目のうち、上限がいちばん新しいものを書く
#   終わった  今日 > 上限の日 + 既定の日数。写さず、list から消すよう警告する (写さないので消し忘れても害は無い)
#   まだ      今日 < from の日。写さず、1 行で知らせる
#
# 上書き中の項目が無ければ既定を書く。上書き中は 1 行で知らせるだけで、入っている tool は上げない
# (新しい版は mise up で入れる)。毎日流す timer は置かない: 流さない日が続いても mise には上限の日時が
# 残るだけで、ずれるのは新しい版を取らない側 (守りは緩まない)。次の --update で既定に戻る。
#
# 状態ファイルが無い (switch の前の世代)・形が違う・jq が無いときは、警告して 9d (option の既定) を書く。
# 守りを緩めない側に倒し、setup は止めない (この手順が止まると、後ろの bootstrap が走らない)。

set -eu -o pipefail

state_file="${HOME}/.local/state/dotfiles/mise-release-age.json"
# 状態ファイルを読めないときに書く遅延 (dotfiles.mise.minimumReleaseAge の既定と同じ)
fallback_age=9d
# 今の時刻 (UNIX 秒)。テストで差し替える
now=${BOOTSTRAP_MISE_NOW:-$(date +%s)}

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

if ! command -v mise &>/dev/null; then
  echo "mise が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

# 状態ファイルの形。from は往復して同じ日付になるか (2026-02-30 のような無い日を通さない) も見る
# (Nix の評価でも止めているが、jq の strptime は無い日を黙って翌月へ繰り越すため)
shape_jq='
  def isDate:
    type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
    and (try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch null) == .;
  (.minimumReleaseAge | type == "string" and test("^[0-9]+d$"))
  and (.releaseAgeOverrides | type == "array")
  and all(.releaseAgeOverrides[];
    type == "object"
    and (.from | isDate)
    and (.zeroDays | type == "number" and . >= 1 and . == floor)
    and (.reason | type == "string"))
'

# 書く値を決める (冒頭の「遅延と、期間を区切った上書き」の表)。出すもの:
#
#   setting  minimum_release_age に書く値 (上書き中なら上限の日時、無ければ既定)
#   claude   claude を入れるとき・cursor-agent の版を引くときの MISE_MINIMUM_RELEASE_AGE (下の claude と cursor-agent の節)
#   age      既定 (minimumReleaseAge)
#   use      上限を書く項目 (無ければ null)。ended (終わった)・pending (まだ) は from・zeroDays・reason の順に並べる
#            (list の順は home-manager の module system が決めるので頼らない。上限が同じ項目のどれを出すかも決まる)
#
# 日付は 1970-01-01 からの日数にして比べる (day・date)。今日は Asia/Tokyo の日で、夏時間が無いので
# UNIX 秒に 9 時間を足して日に割る (tzdata の無い環境でも同じ日になる)。claude は 1d に縮める
# (既定がそれより短ければ既定。$claudeAge) ので、上限を使うのは上限が「今 − その日数」より新しいあいだ
# (今日 ≤ 上限の日 + その日数) だけ。
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
plan_jq='
  def day: strptime("%Y-%m-%d") | mktime / 86400 | floor;
  def date: . * 86400 | strftime("%Y-%m-%d");
  (.minimumReleaseAge | rtrimstr("d") | tonumber) as $age
  | (($now + 9 * 3600) / 86400 | floor) as $today
  | ([1, $age] | min) as $claudeAge
  | ([ .releaseAgeOverrides[]
      | (.from | day) as $from
      | ($from + .zeroDays - 1) as $capDay
      | . + {
          capDay: $capDay,
          cap: (($capDay | date) + "T23:59:59+09:00"),
          end: ($capDay + $age | date),
          state: (if $today < $from then "pending" elif $today > $capDay + $age then "ended" else "active" end)
        }
    ] | sort_by(.from, .zeroDays, .reason)) as $items
  | ($items | map(select(.state == "active")) | max_by(.capDay)) as $use
  | {
      setting: (if $use then $use.cap else .minimumReleaseAge end),
      claude: (if $use and $today <= $use.capDay + $claudeAge then $use.cap else "\($claudeAge)d" end),
      age: .minimumReleaseAge,
      use: $use,
      ended: ($items | map(select(.state == "ended"))),
      pending: ($items | map(select(.state == "pending")))
    }
'

setting=${fallback_age}
claude_age=1d
decided=""
if ! command -v jq &>/dev/null; then
  warn "jq が見つかりません。mise の遅延 (dotfiles.mise) の状態ファイルを読めません。" \
    "先に home-manager switch を実行してください。遅延は既定と同じ ${fallback_age} を書きます。"
elif [[ ! -r ${state_file} ]]; then
  warn "mise の遅延の状態ファイルがありません: ${state_file}" \
    "dotfiles.mise を持つ世代へ先に home-manager switch してください (~/dotfiles/setup --update なら続けて流れます)。" \
    "遅延は既定と同じ ${fallback_age} を書きます。"
elif ! jq -e "${shape_jq}" "${state_file}" &>/dev/null; then
  warn "mise の遅延の状態ファイルの形が違います: ${state_file}" \
    "({\"minimumReleaseAge\": \"<数>d\", \"releaseAgeOverrides\": [{\"from\": \"YYYY-MM-DD\", \"zeroDays\": <1 以上>, \"reason\": \"…\"}]})" \
    "遅延は既定と同じ ${fallback_age} を書きます。"
elif ! decided=$(jq -c --argjson now "${now}" "${plan_jq}" "${state_file}"); then
  warn "mise の遅延を決められませんでした (上の jq のエラー): ${state_file}" \
    "遅延は既定と同じ ${fallback_age} を書きます。"
  decided=""
else
  setting=$(jq -r '.setting' <<<"${decided}")
  claude_age=$(jq -r '.claude' <<<"${decided}")
fi

echo "==> settings"
# 複製元: .config_tmpl/mise/config.toml の [settings]
#
# NOTE: テンプレートの install_before は現在の mise では minimum_release_age に
#       改名されている。install_before は `mise settings ls --all` に存在せず、
#       set しても黙って書き込まれるだけで **無視される** (エラーにならないので
#       気付きにくい)。
mise settings set minimum_release_age "${setting}"
mise settings set lockfile true
mise settings set fetch_remote_versions_timeout 14d

# 上書きの様子: 上書き中の 1 行・まだ始まっていない項目・終わった項目の警告。
# reason は空のことがあるので、どれも最後の欄に置く (read は tab の続く空の欄を詰める)
if [[ -n ${decided} ]]; then
  age=$(jq -r '.age' <<<"${decided}")
  if IFS=$'\t' read -r cap_day end reason < <(jq -r '.use // empty | [.cap[0:10], .end, .reason] | @tsv' <<<"${decided}"); then
    echo "==> mise の遅延を上書き中${reason:+ (理由: ${reason})}: ${cap_day} の終わりまでに出た版を取る。${end} の終わりで上書きが終わり、その後の setup --update で既定の ${age} に戻す。入っている tool の新しい版は mise up で入れられる (setup は上げない)"
  fi
  while IFS=$'\t' read -r from zero reason; do
    echo "  まだ始まっていない上書き: ${from} から 0d を ${zero} 日${reason:+ (理由: ${reason})}"
  done < <(jq -r '.pending[] | [.from, .zeroDays, .reason] | @tsv' <<<"${decided}")
  ended=()
  while IFS=$'\t' read -r from zero end reason; do
    ended+=("from ${from}・zeroDays ${zero}${reason:+・理由: ${reason}} (${end} の終わりで終わった)")
  done < <(jq -r '.ended[] | [.from, .zeroDays, .end, .reason] | @tsv' <<<"${decided}")
  if [[ ${#ended[@]} -gt 0 ]]; then
    warn "mise の遅延の上書き (dotfiles.mise.releaseAgeOverrides) に、終わった項目が残っています (写していません):" \
      "${ended[@]/#/  }" \
      "書いた所 (dotfiles-private の nix/shared/*.nix か、ホストの modules (nix/hosts/<ホスト>.nix・ローカル flake の tmp)) から消してください。" \
      "消し忘れても害はありません (終わった項目は写さない)。"
  fi
fi

echo "==> 言語ランタイム"
# CLI ツール (bat/eza/fd/ripgrep/fzf/jq/...) は Nix が管理するので入れない。
# ここに書くのはプロジェクト毎の切り替えが必要なものだけ (例外は下の claude と cursor-agent)。
# 短縮名 `usage` は registry に 3 つの backend を持つ
# (aqua:jdx/usage / asdf:mise-plugins/mise-usage / cargo:usage-cli)。
# 短縮名のままだとどれが選ばれるかを mise に委ねることになるので、
# prebuilt が降ってくる aqua を明示する。
#
# バージョンを省いているのは意図的。省くと `mise use` は **既に入っている
# 中の最高版**へ解決し、`@latest` を書いたときだけ remote の先端を取りに行く。
# config.toml へ書かれる値はどちらも `latest` で同じなので、差が出るのは
# この場の install だけ。このスクリプトは --update で毎回走るため、
# `@latest` にしておくと更新のたびに新しい版が積み上がる。
# 上げたいときは明示的に `mise up go` を打つ。
mise use -g aqua:jdx/usage # mise 自身の補完に必要
mise use -g go
mise use -g node@24

echo "==> claude (役割分担の例外)"
# claude は「グローバルな CLI」なので、上の役割分担どおりなら Nix
# (packages.nix) 側が筋。nixpkgs にも claude-code は在り、wrapper が
# DISABLE_AUTOUPDATER を立てるので Nix 管理でも動作自体は問題ない。
#
# それでも mise に置くのは **リリース頻度が flake.lock の更新周期に
# 合わない**ため。nixpkgs pin にすると、版は flake.lock を上げるまで動かない。
#
# 遅延も claude だけ上の既定 (9d) ではなく 1d に縮める (対話シェルの `mise1` と同じ。
# script では alias が効かないので env を直接書く)。claude は新しい版をこまめに
# 使いたいことが多いが、ほぼ毎日出るので 9d を課すと手元の版が常に 9 日ぶん遅れる。
# 1d でも公開から 1 日経っていない版は取らないので、repo の「先端は取らない」方針
# (flake-lock-age.sh) の線は残る。env が効くのはこの 1 回だけで、config.toml の
# minimum_release_age は上で書いた値のまま。既定が 1d より短ければ既定で入れる。
#
# 上書き中で、上書きの上限の方が 1d より新しい版を取るあいだ (上限の日の翌日まで) は、
# claude も上限で入れる (claude_age。冒頭の「遅延と、期間を区切った上書き」)。
#
# ここで入れておかないと bootstrap-claude-plugins.sh が動けない。
# そのためヘッダの `order: 10` で bootstrap-* の先頭に出してある。
#
# 上の go / usage と違ってここだけ `@latest` を明示するのは、まさにその
# 「自動で上がってほしい」を成立させるため。省くと --update を何度回しても
# 入った版で固まり、mise に置いた理由 (nixpkgs pin より速い刻み) が消える。
MISE_MINIMUM_RELEASE_AGE="${claude_age}" mise use -g claude@latest

echo "==> cursor-agent (Cursor の CLI。役割分担の例外。dotfiles.cursorAgent.enable のホストだけ)"
# claude と同じ理由 (リリースの頻度が flake.lock の更新の周期に合わない) で mise に置く。入れるのは host option
# dotfiles.cursorAgent.enable (既定 false) のホストだけ。home-manager が on / off を状態ファイル
# (~/.local/state/dotfiles/cursor-agent.json。nix/home/modules/cursor-agent.nix) に置き、ここで読む。
#
# 宣言 (~/.config/mise/conf.d/dotfiles-cursor-agent.toml) は home-manager ではなくここで書き、version に版そのもの
# (2026.11.05-86047df の形) を書く。latest を宣言すると素の mise install が落ちる: mise が知る版は最新の 1 つだけ
# (Cursor は版の一覧を出さず、mise は公式のインストーラから今の版を読む) で、それが遅延 (config.toml の
# minimum_release_age。既定 9d) の中にあると候補が 0 になる。Cursor はおおむね 1〜3 日おきに出すので、9d を過ぎた
# 最新の版がある日はほとんど来ない。版を指した宣言なら mise は遅延を見ないので、どのディレクトリの mise install も落ちない。
#
# 版の決め方 (on。--update のたび):
#
#   1. claude と同じ遅延 (claude_age) で mise latest cursor-agent を引く (遅延の中なら何も出さずに 0 で終わる。版の日付は
#      日までなので、遅延はその日の終わりから数える)
#   2. 出なければ今の宣言の版 (版の形のときだけ。手で latest に書き換えたものは使わない)、それも無ければ入っている
#      一番新しい版 (前の作りで入れた版もここで拾う)
#   3. どれも無ければ宣言を書かずに警告する (版を指していない宣言が残っていれば消す。次の --update で入る)
#   4. 雛形 (nix/files/mise/conf.d/cursor-agent.toml) の @version@ を版に替えて宣言に書き、mise install cursor-agent を
#      打つ (版を指すので遅延の env は付けない。postinstall も宣言から効く)。落ちたら宣言を前の中身に戻し (無かったら
#      消し)、警告する
#
# mise upgrade cursor-agent は使わない (上げるのは宣言の版を書き換えること)。mise use -g cursor-agent も打たない
# (config.toml の宣言は conf.d より強く、まるごと置き換わり、bin_path が registry の dist-package に戻る)。
#
# 宣言の名前を前の home-manager の宣言 (cursor-agent.toml) と変えたのは、home-manager の古い世代へ戻したとき、その世代が
# 張る symlink がここで書いた普通のファイルにぶつかって activate が止まるため。mise は global の conf.d を名前の順に読み、
# 同じツールの宣言は後ろのファイルが勝つ (mise 2026.10.17 で確かめた) ので、古い世代の latest の宣言が並んでも、辞書順で
# 後ろのこの宣言が勝つ。
#
# ここで書いた宣言は 1 行目の印 (cursor_mark) で見分け、印の無いファイル・symlink は手で置いたものとして消さない・
# 書き換えない。off なら印つきの宣言を消し、入っている版は消さない (dotfiles.cleanup.enable のマシンなら週 1 回の掃除の
# mise prune が消す。今すぐなら mise uninstall --all cursor-agent)。状態ファイルが無い・形が違う・jq が無いときは、警告して
# 宣言に触らない。どの場合もここでは止めない (止めると後ろの bootstrap が走らない)。
cursor_state="${HOME}/.local/state/dotfiles/cursor-agent.json"
cursor_decl="${XDG_CONFIG_HOME:-${HOME}/.config}/mise/conf.d/dotfiles-cursor-agent.toml"
# ここで書いた宣言の 1 行目の頭。見るのは頭だけで、後ろの文言は変えてよい
cursor_mark="# dotfiles-managed: nix/scripts/bootstrap-mise.sh"

# 宣言の場所に何かあるか (壊れた symlink も数える)
cursor_decl_exists() { [[ -e ${cursor_decl} || -L ${cursor_decl} ]]; }

# 宣言がここで書いたものか (symlink でない普通のファイルで、1 行目が印で始まる)
cursor_decl_is_ours() {
  local first=""
  [[ -f ${cursor_decl} && ! -L ${cursor_decl} ]] || return 1
  IFS= read -r first <"${cursor_decl}" || [[ -n ${first} ]] || return 1
  [[ ${first} == "${cursor_mark}"* ]]
}

# 宣言の最初の version = "<版>" の版を出す (無ければ何も出さない)
cursor_decl_version() {
  local line
  while IFS= read -r line || [[ -n ${line} ]]; do
    if [[ ${line} =~ ^version\ =\ \"([^\"]*)\"$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"${cursor_decl}"
  return 0
}

# 版の形 (Cursor の版は 2026.11.05-86047df のように数字で始まる)。TOML の文字列を壊す文字と、latest・lts のような語を
# 通さない (印つきの宣言を手で latest に書き換えられても、それを版として書き戻さない。latest の宣言では素の mise install が
# 遅延で落ちる)
cursor_version_ok() { [[ $1 =~ ^[0-9][0-9A-Za-z._+-]*$ ]]; }

# 宣言の雛形のパス (この script のいる checkout の nix/files/mise/conf.d/cursor-agent.toml)
cursor_template() {
  local dir
  dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P) || return 1
  printf '%s\n' "${dir%/scripts}/files/mise/conf.d/cursor-agent.toml"
}

# 宣言の中身を出す: 印と説明の行に続けて、雛形の [tools.cursor-agent] の行から終わりまでを、@version@ を $1 に替えて。
# 雛形が読めない・[tools.cursor-agent] の行が無い・version = "@version@" の行がちょうど 1 つでないときは 1 を返す
cursor_render() {
  local ver=$1 tmpl line started=0 holes=0 text=""
  tmpl=$(cursor_template) || return 1
  [[ -f ${tmpl} && -r ${tmpl} ]] || return 1
  while IFS= read -r line || [[ -n ${line} ]]; do
    if ((started == 0)); then
      [[ ${line} == '[tools.cursor-agent]' ]] || continue
      started=1
    fi
    if [[ ${line} == 'version = "@version@"' ]]; then
      holes=$((holes + 1))
      line="version = \"${ver}\""
    fi
    text+="${line}"$'\n'
  done <"${tmpl}"
  ((started == 1 && holes == 1)) || return 1
  printf '%s が書いた cursor-agent の宣言 (dotfiles.cursorAgent.enable)。手で直しても次の ~/dotfiles/setup --update で書き直す\n' "${cursor_mark}"
  printf '# 雛形は dotfiles の nix/files/mise/conf.d/cursor-agent.toml (何を変えているか・なぜ版そのものかはそちら)\n'
  printf '%s' "${text}"
}

# 宣言に $1 を書く (conf.d を作り、同じディレクトリの一時ファイルに書いて mv で置き換える)。書けなければ 1
cursor_write() {
  local text=$1 dir tmp
  dir=${cursor_decl%/*}
  mkdir -p -- "${dir}" || return 1
  # 名前が .toml で終わらないので、書いている間も mise は読まない
  tmp=$(mktemp "${dir}/.dotfiles-cursor-agent.toml.XXXXXX") || return 1
  if printf '%s\n' "${text}" >"${tmp}" && chmod 644 -- "${tmp}" && mv -f -- "${tmp}" "${cursor_decl}"; then
    return 0
  fi
  rm -f -- "${tmp}"
  return 1
}

# on: 版を決めて宣言に書き、入れる (上の「版の決め方」)
cursor_on() {
  local had=0 changed=0 prev="" cur="" before="宣言が無かった" latest="" target="" from="" text="" back="" dropped=""
  if cursor_decl_exists && ! cursor_decl_is_ours; then
    warn "cursor-agent の宣言の場所に、setup が書いたものでないファイルがあります: ${cursor_decl}" \
      "1 行目が印 (${cursor_mark}) で始まらない・symlink なので書き換えず、cursor-agent も入れません (mise はそのファイルの宣言を使います)。" \
      "setup に任せるなら、そのファイルを消してから ~/dotfiles/setup --update を流してください。"
    return 0
  fi
  if cursor_decl_exists; then
    had=1
    prev=$(cat -- "${cursor_decl}") || prev=""
    cur=$(cursor_decl_version)
    before=${cur:-版の無い宣言}
  fi

  if ! latest=$(MISE_MINIMUM_RELEASE_AGE="${claude_age}" mise latest cursor-agent); then
    echo "  遅延 (${claude_age}) を過ぎた版を引けませんでした (上の mise のエラー)。今の宣言か、入っている版で入れます"
    latest=""
  fi
  if [[ -n ${latest} ]]; then
    target=${latest}
    from="遅延 (${claude_age}) を過ぎた一番新しい版"
  elif [[ -n ${cur} ]] && cursor_version_ok "${cur}"; then
    target=${cur}
    from="遅延 (${claude_age}) を過ぎた版が無いので、今の宣言の版"
  else
    # 宣言の版が版の形でない (手で latest に書き換えたなど) ときは、その版を使わずに入っている版へ進む
    if [[ -n ${cur} ]]; then
      echo "  今の宣言の版 (${cur}) は版の形でないので使いません。入っている一番新しい版で書き直します"
    fi
    if target=$(mise latest --installed cursor-agent) && [[ -n ${target} ]]; then
      from="遅延 (${claude_age}) を過ぎた版も、版を指した宣言も無いので、入っている一番新しい版"
    else
      # ここに来て宣言があるなら、その宣言は版を指していない。残すと素の mise install が遅延で落ちうる (入っている版も
      # 無いので、消しても使える cursor-agent は減らない)
      dropped=""
      if ((had)) && rm -f -- "${cursor_decl}"; then
        dropped="版を指していない宣言 (${before}) は消しました。"
      fi
      warn "cursor-agent の版を決められませんでした: 遅延 (${claude_age}) を過ぎた版も、版を指した宣言も、入っている版もありません。" \
        "${dropped}宣言は書かず、cursor-agent は入れません。出てから ${claude_age} を過ぎた後の ~/dotfiles/setup --update で入ります。"
      return 0
    fi
  fi
  if ! cursor_version_ok "${target}"; then
    warn "cursor-agent の版の形が違うので使いません: ${target} (${from})" \
      "宣言には触らず、cursor-agent は入れません。"
    return 0
  fi
  if ! text=$(cursor_render "${target}"); then
    warn "cursor-agent の宣言の雛形が無いか、形が違います: $(cursor_template || echo nix/files/mise/conf.d/cursor-agent.toml)" \
      "[tools.cursor-agent] の行と、version = \"@version@\" の行がちょうど 1 つ要ります。宣言には触らず、cursor-agent は入れません。"
    return 0
  fi

  if ((had)) && [[ ${prev} == "${text}" ]]; then
    echo "  宣言は ${target} のまま (${from}): ${cursor_decl}"
  elif cursor_write "${text}"; then
    changed=1
    echo "  ${target} を宣言に書いた (${from}。前は ${before}): ${cursor_decl}"
  else
    warn "cursor-agent の宣言を書けませんでした: ${cursor_decl}" "cursor-agent は入れません。"
    return 0
  fi

  if ! mise install cursor-agent; then
    if ((changed == 0)); then
      back="宣言は ${target} のままです"
    elif ((had)); then
      if cursor_write "${prev}"; then
        back="宣言は前の中身 (${before}) に戻しました"
      else
        back="宣言を前の中身 (${before}) に戻せませんでした (${cursor_decl} を確かめてください)"
      fi
    elif rm -f -- "${cursor_decl}"; then
      back="書いた宣言は消しました (前は無かった)"
    else
      back="書いた宣言を消せませんでした (${cursor_decl} を確かめてください)"
    fi
    warn "cursor-agent (Cursor の CLI) の ${target} を入れられませんでした (上の mise のエラー)。" \
      "${back}。次の ~/dotfiles/setup --update で入れ直します。"
  fi
  return 0
}

# off: ここで書いた宣言を消す。入っている版は消さない (週 1 回の掃除の mise prune が消す)
cursor_off() {
  local left=""
  echo "  入れない (dotfiles.cursorAgent.enable = false)"
  if cursor_decl_is_ours; then
    if rm -f -- "${cursor_decl}"; then
      echo "  setup が前に書いた宣言を消した: ${cursor_decl}"
    else
      warn "cursor-agent の宣言を消せませんでした: ${cursor_decl}" \
        "dotfiles.cursorAgent.enable = false ですが、mise はこの宣言の cursor-agent を使い続けます。手で消してください。"
    fi
  elif cursor_decl_exists; then
    echo "  ${cursor_decl} は setup が書いたものでない (1 行目が印で始まらない・symlink) ので残す (mise はその宣言を使う)"
    return 0
  fi
  if left=$(mise latest --installed cursor-agent 2>/dev/null) && [[ -n ${left} ]]; then
    echo "  入っている cursor-agent の版が残っています (一番新しいもの: ${left})。dotfiles.cleanup.enable (既定 true) のマシンなら、どの設定も使っていなければ週 1 回の掃除 (mise prune) で消えます。今すぐ消すなら: mise uninstall --all cursor-agent"
  fi
  return 0
}

# 状態ファイルを読み、on なら cursor_on、off なら cursor_off。読めなければ警告して宣言に触らない
cursor_agent() {
  local enable=""
  if ! command -v jq &>/dev/null; then
    warn "jq が見つかりません。cursor-agent を入れるか (dotfiles.cursorAgent) の状態ファイルを読めません。" \
      "先に home-manager switch を実行してください。cursor-agent の宣言には触りません。"
    return 0
  fi
  if [[ ! -r ${cursor_state} ]]; then
    warn "cursor-agent を入れるかの状態ファイルがありません: ${cursor_state}" \
      "dotfiles.cursorAgent を持つ世代へ先に home-manager switch してください (~/dotfiles/setup --update なら続けて流れます)。" \
      "cursor-agent の宣言には触りません。"
    return 0
  fi
  # 空のファイル (jq は何も出さずに 0 で終わる) や JSON が 2 つ並んだファイル (値を 2 行出す) も形が違うに数えるので、
  # 出たものが true か false のちょうど 1 語かで分ける (jq -e は false を出すと 1 で終わるので使わない)
  enable=$(jq -r 'if type == "object" and (.enable | type) == "boolean" then .enable else error("形が違う") end' \
    "${cursor_state}" 2>/dev/null) || enable=""
  case ${enable} in
    true) cursor_on ;;
    false) cursor_off ;;
    *)
      warn "cursor-agent を入れるかの状態ファイルの形が違います: ${cursor_state}" \
        "({\"enable\": true か false}) cursor-agent の宣言には触りません。"
      ;;
  esac
}

cursor_agent

echo
echo "完了しました。現在のグローバル設定:"
mise config ls --json 2>/dev/null | head -20 || true
echo
echo "--- ~/.config/mise/config.toml ---"
cat "${XDG_CONFIG_HOME:-${HOME}/.config}/mise/config.toml"
