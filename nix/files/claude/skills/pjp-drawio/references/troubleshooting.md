# drawio の headless エクスポートでハマるところ

`scripts/drawio-export.sh` は以下をすべて織り込んである。**素で `drawio` を叩くときの
ためのメモ**であり、スクリプト経由なら気にしなくてよい。

以下は nixpkgs の drawio 30.2.6 で確認した内容（「sandbox」の節と、xvfb-run の
`--error-file` をファイルへ向けたときの注意は 32.4.1 で確かめた）。

## 仮想ディスプレイが要る（SVG でも）

drawio CLI は Electron（＝ Chromium）なので、ディスプレイが無いと起動すらしない。

```
ERROR:ui/ozone/platform/x11/ozone_platform_x11.cc:250] Missing X server or $DISPLAY
ERROR:ui/aura/env.cc:257] The platform failed to initialize.  Exiting.
```

「SVG ならテキストベースだから不要では」とはならない。レンダリングコンテキストを
通してレイアウトが決まる。

## WSL2 (WSLg) では xvfb を使ってはいけない

**使えるディスプレイが既にあるならそれを優先する。** WSLg は `:0` を提供している。

xvfb を先に試すと失敗する。WSLg 環境の `/tmp/.X11-unix` は **read-only の tmpfs で
mode 0777**（1777 でない）ため、Xvfb がソケットを作れない。

```
_XSERVTransmkdir: Mode of /tmp/.X11-unix should be set to 1777
_XSERVTransSocketCreateListener: failed to bind listener
_XSERVTransMakeAllCOTSServerListeners: failed to create listener for unix
```

しかも **`xvfb-run` は既定で `--error-file=/dev/null`** なので、この出力は捨てられる。
症状は「何も出力せず exit 1」だけになり、原因に辿り着けない。デバッグするときは
必ず `--error-file=/dev/stderr` を渡す。

`--auth-file` の既定は `./.Xauthority`（カレントを汚す）ので、これも逃がす。

```sh
xvfb-run --auto-display --auth-file="${tmp}/Xauthority" --error-file=/dev/stderr drawio ...
```

ただし **stderr をファイルへ向けているとき（`>log 2>&1`）は `/dev/stderr` を渡さない。**
xvfb-run はコマンドが終わったあと `xauth remove … >"$ERRORFILE"` で開き直すので、log が
切り詰められ、drawio の出力（落ちた理由）まで消える。症状は同じく「何も出力せず exit 1」。
`scripts/drawio-export.sh` は出力を log に取ってノイズを落とすので、`--error-file` には別の
一時ファイルを渡し、失敗したときに drawio の出力と並べて出す（Xvfb が立たないときは、
xvfb-run が後始末の前に抜けるので、Xvfb の出力もそのファイルに残る）。端末に出すだけなら
`/dev/stderr` でよい。

nixpkgs の `drawio-headless` を使っていないのはこれが理由。あれは `xvfb-run` を
内側に抱えていて外せないので、WSLg では常に失敗する。

## `--disable-gpu`（かつての罠。30.2.6 では解消済み）

以前は、ファイルが存在するのにこう言われた。

```
Error: input file/directory not found
```

**Electron のフラグが drawio CLI（commander）の引数解析に混ざり、位置引数がずれる**
のが原因だった。

**2026-08-13 に 30.2.6 で再検証したところ、再現しない。** フラグ位置（先頭 / 中間 /
ファイル直前 / 直後）、`-o` の有無、`-o` がファイルかディレクトリか、入力が相対パスか
絶対パスか、`-x -f` と `--export --format` の両表記 — いずれの組み合わせでも正常に
書き出せた。上流で解消されたと見られる。

とはいえ**付ける利点も無い**。GPU 関連のエラー出力はもともと無害で消す必要が無く、
`scripts/drawio-export.sh` は付けないままにしてある。古い drawio を使う環境で上記の
エラーに当たったら、まずこのフラグを疑う。

`--no-sandbox` は当時から混ざらない（root で動かすときと、下の「sandbox」のマシンで要る）。

```
FATAL:electron_main_delegate.cc:312] Running as root without --no-sandbox is not supported.
```

## sandbox（一般ユーザが user namespace を使えないマシン）

2026-11-09 に drawio 32.4.1（Electron 44.7.2）・Ubuntu 24.04（kernel 7.0）で確かめた。

一般ユーザで書き出すと、起動の直後に落ちる（終了コード 133 = SIGTRAP）。

```
FATAL:sandbox/linux/suid/client/setuid_sandbox_host.cc:166] The SUID sandbox helper binary was found, but is not configured correctly. Rather than run without sandboxing I'm aborting now. You need to make sure that /nix/store/…-electron-44.7.2/libexec/electron/chrome-sandbox is owned by root and has mode 4755.
```

原因:

1. Chromium（Electron）は、一般ユーザでは unprivileged user namespace で sandbox を立てる
2. それが使えないと、setuid root の helper（`chrome-sandbox`）へ落ちる。nixpkgs の electron は
   `CHROME_DEVEL_SANDBOX` に store の `chrome-sandbox` を渡しているが、store には setuid の
   ファイルを置けないので、helper も使えない
3. どちらも使えないので、Chromium は sandbox 無しで動くのを断って落ちる

user namespace を使えないのは、kernel の設定がこうなっているマシン。

| 設定 | 値 | |
| --- | --- | --- |
| `kernel.apparmor_restrict_unprivileged_userns` | `1` | Ubuntu 23.10 以降の既定。どの AppArmor の profile にも入っていないプロセスが作った user namespace から、capability を外す（作ることはできる）。store の drawio はどの profile にも入らない |
| `kernel.unprivileged_userns_clone` | `0` | Debian の kernel の設定。一般ユーザに作らせない |
| `user.max_user_namespaces` | `0` | 作れる数の上限が 0 |

確かめ方:

```sh
sysctl kernel.apparmor_restrict_unprivileged_userns   # 1 なら当たる
unshare -Ur true   # 当たるマシンでは unshare: write failed /proc/self/uid_map: Operation not permitted
```

### `scripts/drawio-export.sh` の動き

- 上の表の設定のどれかに当たれば、drawio に `--no-sandbox` を付け、stderr に「注意:」で始まる
  2 行（当たった設定と、読ませてよい `.drawio`）を出す。root のときも付ける（注意は出さない）
- どれにも当たらなければ付けない（今までどおり sandbox の中で動く）
- 表に無い理由（コンテナの seccomp など）で sandbox が立たないときは付けず、上の FATAL を出して止まる
- AppArmor の profile で electron に `userns` を許したマシンでも、
  `kernel.apparmor_restrict_unprivileged_userns` が 1 なら付ける（profile までは読まない）

### 安全の面

sandbox は、Chromium の子プロセス（図の中身を読んで描く renderer など）が乗っ取られても、
ファイルやほかのプロセスに手を出せないようにする仕組み。外すと、renderer の脆弱性を突く図を
読ませたとき、乗っ取ったコードがユーザの権限のまま動く（`~/.ssh` やトークンを読める）。
図の中身（HTML のラベル・埋め込んだ画像や SVG・フォント）は、どれも renderer が読む。

- **sandbox の無い drawio に読ませるのは、自分たちで書いた `.drawio` だけにする**
  （この skill の使い方。Claude とユーザが repo の中で書いた図）
- 外から受け取った `.drawio`（ダウンロードしたもの・人から渡されたもの）は、そのマシンでは
  書き出さない。sandbox が立つマシンか、使い捨ての VM・コンテナの中で書き出す
- drawio を素で叩いて `--no-sandbox` を付けるときも同じ

### sandbox を残したまま通すには（どれも root が要る）

この skill は、マシンの設定を変えない。直すなら、マシンの持ち主が次のどれかを選ぶ
（Chromium の文書 <https://chromium.googlesource.com/chromium/src/+/main/docs/security/apparmor-userns-restrictions.md>）。

- electron に `userns` を許す AppArmor の profile を置く（守りを緩めるのはそのプログラムだけ）。
  今の script は profile を読まないので、置いても `--no-sandbox` を付ける。置いたら script も直す
- `sysctl kernel.apparmor_restrict_unprivileged_userns=0` で止めるのをやめる（マシン全体の守りが下がる）
- setuid root の `chrome-sandbox` を store の外に置いて使う（nixpkgs の electron の wrapper は
  `CHROME_DEVEL_SANDBOX` を store のものに書き換えるので、外から渡してもそのままでは効かない）

## `--svg-theme light` を付ける

付けないと SVG ルートが `color-scheme: light dark` になり、ダークモードのビューアで
色が反転する。

30.x では `--svg-theme light` を付けても、色は `light-dark()` 関数で出る。

```xml
<svg style="... color-scheme: light;">
  <rect fill="#ffffff" style="fill: light-dark(rgb(255, 255, 255), rgb(18, 18, 18));"/>
  <text fill="light-dark(#000000, #ffffff)">…</text>
```

ルートに `color-scheme: light` があるので、対応ビューアでは light 側に解決される。
`light-dark()` を知らないレンダラ（librsvg など）では、`style` の宣言が無効値として
捨てられて presentation attribute（`fill="#ffffff"`）に落ちるので、こちらも破綻しない。

## 白背景は出力後に差し込む

`mxGraphModel` の `background="#FFFFFF"` 属性は **SVG 出力に反映されない**
（ルートは `background: transparent` のまま）。

`scripts/drawio-export.sh` は、書き出した SVG のルート直下へ全面を覆う矩形を入れる。

```xml
<svg ...><rect x="0" y="0" width="100%" height="100%" fill="#ffffff"/><defs/>…
```

図の中に白い矩形セルを置く方法（図のサイズを知る必要がある）は要らなくなった。
入らなかった場合はエラーで止まる（黙って透過のまま出さない）。`--no-white-bg` で切れる。

PNG は drawio 側が白背景で出す（`-t` を付けたときだけ透過）。

## `--embed-svg-fonts false` でサイズが落ちる

必須ではないが効く。日本語テキストは `<text>` 要素としてそのまま残るので表示は
変わらない。リポジトリに入れる SVG ならこちらが実用的。

| | サイズ |
| --- | --- |
| 既定（埋め込みあり）| 17 KB |
| `--embed-svg-fonts false` | 3.8 KB |

小さい図でこの比なので、大きい図では MB 単位で効く。

## 無視してよいエラー出力

headless では大量に出るが、**すべて無害**。出力ファイルは正常に生成される。

```
ERROR:dbus/bus.cc:408] Failed to connect to the bus: ...
ERROR:components/viz/service/main/viz_main_impl.cc:184] Exiting GPU process due to errors during initialization
ERROR:ui/gl/angle_platform_impl.cc:47] Display.cpp:1097 (initialize): ANGLE Display::initialize error 12289: glXQueryExtensionsString returned NULL
ERROR:ui/gl/gl_display.cc:673] Initialization of all EGL display types failed.
ERROR:ui/ozone/common/gl_ozone_egl.cc:26] GLDisplayEGL::Initialize failed.
```

`scripts/drawio-export.sh` はこれらを落として、**失敗したときだけ全部出す**
（成功時のフィルタで本物のエラーを消してしまわないように、判定は終了コードで行う）。
`--keep-noise` で落とさずに見られる。

## フォント

`flake.nix` が `FONTCONFIG_FILE` を store の fonts.conf に向けている。これが無いと、
**日本語フォントを持たない環境で豆腐（□□□）になる。**

厄介なのは、**手元では効いていなくても気付けない**こと。`makeFontsConf` は
`/usr/share/fonts` や `~/.local/share/fonts` を残すので、ホストに Noto CJK があると
どちらでも同じ絵が出る。手元の結果は他環境の根拠にならない。

確かめるには、ホストのフォントが見えない nix サンドボックスで書き出す。

```nix
# test.nix
let
  pkgs = import <nixpkgs> { };
  fontsConf = pkgs.makeFontsConf {
    fontDirectories = [ pkgs.noto-fonts-cjk-sans pkgs.liberation_ttf ];
  };
in
pkgs.runCommand "font-test" { nativeBuildInputs = [ pkgs.drawio pkgs.xvfb-run ]; } ''
  export HOME=$TMPDIR XDG_CONFIG_HOME=$TMPDIR/c XDG_CACHE_HOME=$TMPDIR/k
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$out"
  export FONTCONFIG_FILE=${fontsConf}   # これを外すと豆腐になる
  cp ${./sample.drawio} in.drawio
  xvfb-run --auto-display --auth-file=$TMPDIR/xauth --error-file=/dev/stderr \
    drawio -x -f png -s 2 --disable-update -o "$out/out.png" in.drawio
''
```

サンドボックス内では `/tmp` が private なので、`xvfb-run` はそのまま動く（CI と同じ）。

- **PNG は fonts.conf が必須**（ラスタライズする）
- **SVG も入れておく**。表示は閲覧側のフォント次第だが、drawio はエクスポート時に
  フォントメトリクスでレイアウトを計算するため、無いと文字幅がずれる

可変フォント（`NotoSansCJK-VF.otf.ttc`）のままで描ける。pjp-plantuml skill が
`noto-fonts-cjk-sans-static` を使っているのは OpenJDK が可変フォントを描けないためで、
Chromium にはその制約が無い。
