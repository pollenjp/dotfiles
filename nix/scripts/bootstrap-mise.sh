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
#   claude   claude (と cursor-agent) を入れるときの MISE_MINIMUM_RELEASE_AGE (下の claude の節)
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

echo "==> cursor-agent (Cursor の CLI。役割分担の例外)"
# claude と同じ理由 (リリースの頻度が flake.lock の更新の周期に合わない) で mise に置き、同じ遅延 (claude_age) で入れる。
# 何を入れるか (mise の registry の cursor-agent と、そこから変えたところ) は ~/.config/mise/conf.d/cursor-agent.toml
# (nix/files/mise/conf.d/cursor-agent.toml) に書いてあり、ここは入れて上げるだけ。mise use -g は使わない
# (config.toml に書くと、conf.d の宣言がまるごと隠れる)。
#
# install はまだ入っていないときだけ入れ (入っていれば何もしない)、upgrade は遅延を過ぎた新しい版があれば上げる。
# mise が知る版は最新の 1 つだけ (Cursor は版の一覧を出さず、mise は公式のインストーラから今の版を読む) で、版の日付は
# 日までなので、遅延はその日の終わりから数える (1d なら 10/22 の版は 10/23 の終わりから)。それまでは取れる版が無く、
# install は落ち、upgrade は mise の警告だけを出して入っている版のまま終わる。ここで止めると後ろの bootstrap が
# 走らないので、落ちたら警告して続ける。
cursor_conf="${XDG_CONFIG_HOME:-${HOME}/.config}/mise/conf.d/cursor-agent.toml"
if [[ ! -e ${cursor_conf} ]]; then
  warn "cursor-agent (Cursor の CLI) の宣言がありません: ${cursor_conf}" \
    "先に home-manager switch してください (~/dotfiles/setup --update なら続けて流れます)。cursor-agent は入れません。"
elif ! MISE_MINIMUM_RELEASE_AGE="${claude_age}" mise install cursor-agent; then
  warn "cursor-agent (Cursor の CLI) を入れられませんでした (上の mise のエラー)。" \
    "mise が知る版は最新の 1 つだけなので、それが遅延 (${claude_age}) を過ぎるまでは取れる版がありません。" \
    "過ぎたあとの ~/dotfiles/setup --update で入ります。すぐ入れるなら mise install cursor-agent@<版> (エラーに出ている版)。"
elif ! MISE_MINIMUM_RELEASE_AGE="${claude_age}" mise upgrade cursor-agent; then
  warn "cursor-agent (Cursor の CLI) を上げられませんでした (上の mise のエラー)。入っている版のままです。"
fi

echo
echo "完了しました。現在のグローバル設定:"
mise config ls --json 2>/dev/null | head -20 || true
echo
echo "--- ~/.config/mise/config.toml ---"
cat "${XDG_CONFIG_HOME:-${HOME}/.config}/mise/config.toml"
