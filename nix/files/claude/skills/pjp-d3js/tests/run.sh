#!/usr/bin/env bash
# shellcheck shell=bash
#
# d3js-export.sh と d3js-vendor.sh を一通り流して、出力を確かめる。
# scripts/ を直したとき・版を上げたとき (package-lock.json・flake.lock) に流す。
#
#   nix/files/claude/skills/pjp-d3js/tests/run.sh
#
# fixtures/ を一時ディレクトリへ写してから流すので、repo は汚さない。
# devShell の外で呼ばれたら 1 回だけ入り直す (中で呼ぶ script が毎回入り直さないように)。

set -eu -o pipefail

tests_dir=$(
  cd -- "$(dirname -- "$(readlink -f -- "$0")")" &>/dev/null
  pwd -P
)
skill_dir=$(dirname -- "${tests_dir}")

if [[ -z ${PJP_D3JS_NODE_MODULES:-} ]]; then
  if [[ -z ${D3JS_TESTS_REEXEC:-} ]] && command -v nix &>/dev/null; then
    export D3JS_TESTS_REEXEC=1
    exec nix develop "path:${skill_dir}" --command "$0" "$@"
  fi
  echo "PJP_D3JS_NODE_MODULES がありません (nix が要る)" >&2
  exit 1
fi

export_sh=${skill_dir}/scripts/d3js-export.sh
vendor_sh=${skill_dir}/scripts/d3js-vendor.sh

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
log=${work}/last.log
: >"${log}"

passed=0
failed=0

# check <名前> <コマンド...>: コマンドが成功すれば ok。失敗したら直前のログも見せる
check() {
  local name=$1
  shift
  if "$@"; then
    echo "ok    ${name}"
    passed=$((passed + 1))
  else
    echo "FAIL  ${name}"
    if [[ -s ${log} ]]; then
      sed 's/^/      | /' "${log}"
    fi
    failed=$((failed + 1))
  fi
}

# run <コマンド...>: 出力を ${log} に残して流す。終了コードはそのまま返す
run() {
  "$@" >"${log}" 2>&1
}

# fails_with <文字列> <コマンド...>: 失敗し、出力に <文字列> を含む
fails_with() {
  local want=$1
  shift
  if run "$@"; then
    return 1
  fi
  grep -qF -- "${want}" "${log}"
}

eq() {
  [[ $1 == "$2" ]]
}

# not_in_log <文字列>: 直前のログに <文字列> が無い
not_in_log() {
  ! grep -qF -- "$1" "${log}"
}

# 先頭の子要素が白い rect か (属性の順は linkedom が決めるので問わない)
starts_with_white_rect() {
  grep -qE '^<svg[^>]*><rect [^>]*fill="#ffffff"' "$1"
}

# 先頭の rect の属性 <名前> の値
first_rect_attr() {
  grep -oE '^<svg[^>]*><rect [^>]*>' "$1" | grep -oE " $2=\"[^\"]*\"" | head -n 1 | cut -d '"' -f 2
}

# PNG の幅と高さ (IHDR の 16〜23 バイト目) を "W H" で出す
png_size() {
  od -An -tu1 -j16 -N8 "$1" | awk '{ print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4, $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 }'
}

cp -R "${tests_dir}/fixtures" "${work}/fx"
# 配置後の skill (store のコピー) から流すと、写したものも読み取り専用になる。
# 書き出しも、終わったあとの rm -rf も通るよう、書き込めるようにしておく。
chmod -R u+w "${work}/fx"
ok_dir=${work}/fx/ok

echo "## 書き出し (d3js-export.sh)"

cd "${ok_dir}"
check "ok/ を SVG と PNG に書き出せる" run "${export_sh}" -f svg,png
for name in 01_d3_axis 02_plot_bars 03_force 04_no_viewbox "05 日本語の名前" 06_body_a 07_body_b 08_escape; do
  check "${name}.svg がある" test -f "out/${name}.svg"
  check "${name}.svg に xmlns がある" grep -qF 'xmlns="http://www.w3.org/2000/svg"' "out/${name}.svg"
  check "${name}.svg の先頭に白背景" starts_with_white_rect "out/${name}.svg"
  check "${name}.png がある" test -s "out/${name}.png"
done
check "_ で始まる部品は書き出さない" test ! -e out/_palette.svg
check "JSON の import が効く" grep -qF '東京' out/01_d3_axis.svg
check "部品 (_palette.mjs) の import が効く" grep -qF '#2a78d6' out/01_d3_axis.svg
check "viewBox の左上から白背景を敷く" eq "$(first_rect_attr out/03_force.svg x) $(first_rect_attr out/03_force.svg y) $(first_rect_attr out/03_force.svg width) $(first_rect_attr out/03_force.svg height)" "-200 -120 400 240"
check "viewBox が無ければ width / height で敷く" eq "$(first_rect_attr out/04_no_viewbox.svg width) $(first_rect_attr out/04_no_viewbox.svg height)" "300 150"
check "PNG の大きさは width × height" eq "$(png_size out/01_d3_axis.png)" "640 320"
check "属性値の & と < をエスケープする" grep -qF 'aria-label="R&amp;D &lt;推移&gt;"' out/08_escape.svg
check "文字の & と < をエスケープする" grep -qF '>A &amp; B &lt;C&gt;<' out/08_escape.svg
check "URL の & もエスケープする" grep -qF 'href="https://example.com/?a=1&amp;b=2"' out/08_escape.svg
check "xlink:href はそのまま書く" grep -qF 'xlink:href="#dot"' out/08_escape.svg
check "xlink を使ったら xmlns:xlink を宣言する" grep -qF 'xmlns:xlink="http://www.w3.org/1999/xlink"' out/08_escape.svg
check "要素名の大文字を保つ (clipPath・linearGradient)" grep -qE '<clipPath .*<linearGradient ' out/08_escape.svg

check "2 回目も書き出せる" run "${export_sh}" -o out2
for name in 01_d3_axis 02_plot_bars 03_force; do
  check "${name}.svg が 1 回目と同じ" cmp -s "out/${name}.svg" "out2/${name}.svg"
done

check "--transparent で書き出せる" run "${export_sh}" --transparent -o out3 01_d3_axis.mjs
check "--transparent では白背景を敷かない" eval '! starts_with_white_rect out3/01_d3_axis.svg'

check "-f png -s 2 で書き出せる" run "${export_sh}" -f png -s 2 -o out4 01_d3_axis.mjs
check "-s 2 の PNG は 2 倍" eq "$(png_size out4/01_d3_axis.png)" "1280 640"
check "-f png だけなら SVG を残さない" test ! -e out4/01_d3_axis.svg

cd "${work}/fx"
check "パス付きで渡しても out/ の下に書く" run "${export_sh}" -o out5 ok/03_force.mjs
check "パス付きの出力がある" test -f out5/03_force.svg

mkdir -p dup
cp ok/03_force.mjs dup/03_force.mjs
check "名前がぶつかると止まる" fails_with "ぶつかります" "${export_sh}" -o out6 ok/03_force.mjs dup/03_force.mjs
check "名前がぶつかったら何も書かない" test ! -e out6/03_force.svg

check "return を忘れたら止まる" fails_with "何も返していません" "${export_sh}" -o out7 ng/returns_nothing.mjs
check "Plot の <figure> は止まる" fails_with "<figure>" "${export_sh}" -o out7 ng/plot_figure.mjs
check "default export が無ければ止まる" fails_with "default export が関数ではありません" "${export_sh}" -o out7 ng/no_default.mjs
check "chart module の例外を見せる" fails_with "boom" "${export_sh}" -o out7 ng/throws.mjs
check "無いパッケージは名前を出して止まる" fails_with "left-pad" "${export_sh}" -o out7 ng/bad_import.mjs

check "1 つ失敗しても残りは書く (終了コードは失敗)" fails_with "失敗した chart module があります" "${export_sh}" -o out8 ok/01_d3_axis.mjs ng/throws.mjs
check "失敗と一緒に渡した図も書けている" test -f out8/01_d3_axis.svg

check "止まらない timer があっても終わる" run timeout 60 "${export_sh}" -o out10 timer/10_interval.mjs
check "timer が残ったら知らせる" grep -qF "timer が動いたまま" "${log}"
check ".stop() を忘れた力学グラフでも書き出せる" run timeout 60 "${export_sh}" -o out10 timer/09_force_nostop.mjs
check ".stop() を忘れた力学グラフも知らせる" grep -qF "timer が動いたまま" "${log}"
check ".stop() した力学グラフを書き出せる" run "${export_sh}" -o out11 ok/03_force.mjs
check ".stop() した力学グラフでは知らせない" not_in_log "timer が動いたまま"

mkdir -p empty
cd empty
check ".mjs が無ければ止まる" fails_with "対象の .mjs がありません" "${export_sh}"
cd "${ok_dir}"
check "知らない形式は止まる" fails_with "知らない形式" "${export_sh}" -f pdf
check "devShell の外から呼んでも書き出せる" run env -u PJP_D3JS_NODE_MODULES -u PJP_D3JS_FONTS_DIR -u D3JS_SKILL_REEXEC "${export_sh}" -o out9 01_d3_axis.mjs
check "devShell の外から呼んだ出力がある" test -f out9/01_d3_axis.svg

echo "## 写す (d3js-vendor.sh)"

page=${work}/page
check "d3.min.js と plot.umd.min.js を写せる" run "${vendor_sh}" --plot "${page}/assets"
check "d3.min.js がある" test -s "${page}/assets/d3.min.js"
check "plot.umd.min.js がある" test -s "${page}/assets/plot.umd.min.js"
check "d3.min.js は d3 7.9.0" grep -qF 'd3js.org v7.9.0' "${page}/assets/d3.min.js"
check "plot.umd.min.js は Plot 0.6.17" grep -qF '@observablehq/plot v0.6.17' "${page}/assets/plot.umd.min.js"
check "写したファイルに書き込める" test -w "${page}/assets/d3.min.js"
check "写し直せる" run "${vendor_sh}" --plot "${page}/assets"
check "貼る <script> の行を出す" grep -qF '<script src="assets/d3.min.js"></script>' "${log}"
check "--plot なしなら d3.min.js だけ写せる" run "${vendor_sh}" "${work}/page2/assets"
check "--plot なしなら plot.umd.min.js は無い" test ! -e "${work}/page2/assets/plot.umd.min.js"
check "写す先が無ければ止まる" fails_with "写す先の DIR" "${vendor_sh}"

echo
echo "${passed} ok / ${failed} FAIL"
((failed == 0))
