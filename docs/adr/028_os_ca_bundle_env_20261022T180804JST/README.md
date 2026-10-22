# ADR: 自前の証明書の束を持つツールを、環境変数で OS の信頼ストアに寄せる (Linux の全ホスト)

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 置き場所 (dotfiles で Linux の全ホスト) は 2026-10-22 にユーザーが選んで承認。`REQUESTS_CA_BUNDLE` を残し、flake で入れる変数を選べるようにすること (C) も、同じ日に PR を見てユーザーが決めた。書き方はこちらで決め、PR でレビュー |
| 日付 | 2026-10-22 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-312](https://app.notion.com/p/certifi-uv-gcloud-OS-home-manager-Linux-4-40179149a66f818d924cc4928784b541) (束ねたチケット: [TKT-308](https://app.notion.com/p/eMudhra-CA-PC-40179149a66f81ae8798ebef5a97eb08)) |
| 関連 | nixos-config の [PR #11](https://github.com/pollenjp/nixos-config/pull/11) (TKT-309。NixOS の OS の束で、eMudhra の侵害に関わるルート 4 つを不信任にした) |
| 運用手順 | [`nix/README.md`「証明書の束を OS の信頼ストアに寄せる」](../../../nix/README.md#証明書の束を-os-の信頼ストアに寄せる) |

---

## 1. 背景 (Context)

2026-10-20 に、eMudhra の中間 CA 8 個の秘密鍵の侵害が公表された (CVE-2026-111943。
[勧告](https://emudhra.we-have-a-problem.com/))。指揮役の PC (lavie、NixOS) は nixos-config の PR #11 で OS の束
(`/etc/ssl/certs/ca-certificates.crt`) から 4 つのルートを外し、OpenSSL と Go で TLS を張るもの (curl・gh・mise・
nixpkgs の Node) はテスト用ホスト (`https://dv-g3b-emudhra.we-have-a-problem.com/`) を拒否するようになった。

自前の束を持つツールは、OS の束を直しても通したまま残る。ユーザーの指示は次のとおり。

> devShell や repo ごとの mise 設定 (例: my-cloud/gcp-sdbx/mise.toml)、globalなmiseで入れているツール群などもチェックして欲しい。

指揮役が点検し、次の 4 つの環境変数で OS の束に向けられることが分かった。どれも OS の束を指すだけなので、
もともと OS の束を読むもの (OpenSSL・Go) は変わらない。

| ツール | 自前の束 | OS の束に向ける変数 |
| --- | --- | --- |
| nixpkgs の python の requests | nixpkgs の certifi (変数があればその束を返すよう nixpkgs が直している) | `NIX_SSL_CERT_FILE` |
| uv (nixpkgs) | 中に持つ webpki-roots | `SSL_CERT_FILE` |
| venv に入れた PyPI の requests | PyPI の certifi | `REQUESTS_CA_BUNDLE` |
| gcloud | SDK の中の certifi (設定の `core/custom_ca_certs_file` で差し替えられる) | `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` |

置き場所 (dotfiles で Linux の全ホスト / nixos-config / repo ごと) をユーザーに聞き、「dotfiles で全マシン」が選ばれた。
WSL の Ubuntu と GCP の VM でも、OS の束を直すだけでこれらが揃って直るようにするため。

## 2. 決定 (Decision)

### A. Linux のホストの session で、4 つを OS の束に向ける

新しい module `nix/home/modules/os-ca-bundle.nix` が、home-manager の `hm-session-vars.sh` の末尾
(`home.sessionVariablesExtra`) に次を書く。Linux のホストだけ (`pkgs.stdenv.hostPlatform.isLinux`)。

```sh
if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
  export SSL_CERT_FILE="${SSL_CERT_FILE:-${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}}"
  export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"
  export REQUESTS_CA_BUNDLE="${REQUESTS_CA_BUNDLE:-$SSL_CERT_FILE}"
  export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="${CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE:-$SSL_CERT_FILE}"
fi
```

- bash は login の shell の `~/.profile` が `hm-session-vars.sh` を読む。fish は `config.fish` が、babelfish で fish に
  直した `hm-session-vars.fish` をすべての fish で読む。1 か所に書けば両方に届く
- 次の事件でも、OS の束を直せば (NixOS は nixos-config、Ubuntu は ca-certificates) これらのツールも揃って直る

### B. 束が無いホストでは入れず、すでに束を指している変数があればそれに揃える

- **束が無ければ何もしない。** 無いホスト (ca-certificates を入れていないコンテナ・パスの違う Fedora 系) で
  入れると、`NIX_SSL_CERT_FILE` を読む nix 自身も含めて TLS が通らなくなる
- **すでに束を指している変数があれば、残りをそれに揃える。** 揃える先は `SSL_CERT_FILE`、無ければ
  `NIX_SSL_CERT_FILE` の値で、どちらも無ければ OS の束。値がある (空でない) 変数は書き換えない。OS や管理者が
  別の束 (社内の CA を足したものなど) を指しているとき、壊さず、ツールごとに違う束を読むこともないようにする
  - `SSL_CERT_FILE` を先に見るのは、Ubuntu などでは Nix の installer の profile の script (`nix-daemon.sh`) が
    `NIX_SSL_CERT_FILE` を自動で OS の束に立てるため。`SSL_CERT_FILE` の方が、人が選んだ値であることが多い
  - 揃えずに「すでにある値は残し、無いものは OS の束」とすると、`SSL_CERT_FILE` だけがある NixOS で
    `NIX_SSL_CERT_FILE` が OS の束になる。nixpkgs の OpenSSL は `NIX_SSL_CERT_FILE` を先に読むので、残したはずの
    `SSL_CERT_FILE` が python の標準の https・git などに届かなくなる (PR のレビューで見つかり、この形に直した)
- 束が無ければ何もしない・値があれば触らない点は、Nix の installer の `nix-daemon.sh` が `NIX_SSL_CERT_FILE` に
  していることと同じ (「Allow users to override the NIX_SSL_CERT_FILE」・束があるパスを順に探す)

### C. 入れる変数を option で 3 つから選べる (既定は 4 つ)

`nix/home/options.nix` に `dotfiles.osCaBundle` を置き、ホストの module (dotfiles-private の `nix/hosts/` のファイルか、
ローカル flake の tmp の `modules`) で選ぶ。

| `enable` | `requestsCaBundle.enable` | 入る変数 |
| --- | --- | --- |
| `true` (既定) | `true` (既定) | 4 つとも |
| `true` | `false` | `REQUESTS_CA_BUNDLE` 以外の 3 つ |
| `false` | (意味を持たない) | 入れない |

- ユーザーの答え (PR を見たあと、指揮役から):

  > 残す。
  > ただし、 flake でこの環境変数一式を外す設定もできるようにして欲しい。
  > 4つ適用するかREQUESTS_CA_BUNDLE以外を適用するか、環境変数適用しないか。

- `REQUESTS_CA_BUNDLE` だけを外せるのは、requests がこれを、アプリが `Session` に置いた `verify` より先に使うため
  (5 の注意)。そういう script をよく動かすホストで、残りの 3 つは生かしたまま外せる
- 形はこの repo の option の決まり (親が false なら子は意味を持たない、という入れ子。`dotfiles.wsl` と同じ) に合わせ、
  bool 2 つにした
- 1 台だけ別の束に向けたいときは、ホストの module で `home.sessionVariables.SSL_CERT_FILE` を書けば、
  `hm-session-vars.sh` のこの if より前で export され、残りもそれに揃う (B)

### D. 方針の承認のあとに、こちらで決めたこと

| 問い | 決めたこと | 理由 |
| --- | --- | --- |
| 置き場所 | 新しい module `os-ca-bundle.nix` (`shell-common.nix` に足さない) | 理由と条件をファイルの頭に書け、ファイル名で引ける。`shell-common.nix` は旧経路から移した値の置き場 |
| 書き方 | `home.sessionVariablesExtra` に shell の if で書く | `home.sessionVariables` は条件を書けない (B が書けない) |
| `home.sessionVariablesExtra` が home-manager の internal な option であること | 使う | 書き足した行は `hm-session-vars.sh` にそのまま入り、babelfish が fish に直す (ビルドして確かめた)。home-manager 自身も `targets.genericLinux` で使っている |
| 束を探すパスを Nix の installer のように増やすか | `/etc/ssl/certs/ca-certificates.crt` だけ | 使っているホスト (NixOS・Ubuntu) はどれもこのパス。ほかの distro は B で何もしない側に倒れる |
| systemd の user の environment.d (`systemd.user.sessionVariables`) にも入れるか | 入れない | `KEY=VALUE` しか書けず、B の条件を書けない |
| `REQUESTS_CA_BUNDLE` が requests の `Session` の `verify` より先に効くこと (5 の注意) | 既定で入れ、副作用と 1 回だけ外す打ち方 (`REQUESTS_CA_BUNDLE= <コマンド>`) を README に書く。ホストごとに外せる (C) | 古い certifi の venv が OS の束に従う効き目が大きい (今回も certifi 2026.06.17 の venv は通した)。副作用は検証に失敗する側に倒れ、黙って検証を外すことはない。PR で聞き、ユーザーが「残す。flake で外せるように」と答えた |
| option の名前と形 | `dotfiles.osCaBundle.enable` と `dotfiles.osCaBundle.requestsCaBundle.enable` (bool 2 つ、既定 true)。書くのは `modules` (`mkHome` の引数には足さない) | repo の option は入れ子の bool で、enum の option は無い。`mkHome` の引数は組 (`wsl`・`onePassword`・`claude`) だけで、ほかの option (`dotfiles.cleanup.enable`・`dotfiles.ccPages.port`) は `modules` に書く |
| ローカル flake の雛形 (tmp の例のコメント) に足すか | 足さない。README の「足したホストに書く値」と options.nix の説明に書く | 雛形は本文から版の印を計算するので、コメントを 1 行足すだけで全マシンに「前の雛形から作られています」が出る |
| 空の変数の扱い | 4 つとも値が無いものとして扱う (`${X:-…}`) | 空の `SSL_CERT_FILE` は OpenSSL の束の読み込みを壊す。変数ごとに扱いを変えると分かりにくい |
| ADR の番号 | 028 | open の PR (#153) は ADR を足していない。#152 は merge 済みで ADR なし |

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/home/modules/os-ca-bundle.nix` | 新規。A・B の if を `home.sessionVariablesExtra` に書く (Linux で `osCaBundle.enable` のときだけ。`REQUESTS_CA_BUNDLE` の行は `requestsCaBundle.enable` のときだけ) |
| `nix/home/options.nix` | `dotfiles.osCaBundle.enable`・`dotfiles.osCaBundle.requestsCaBundle.enable` (C) |
| `nix/home/default.nix` | `os-ca-bundle.nix` を import |
| `nix/tests/os-ca-bundle.nix` | 新規。C の 3 つの選び方ごとに、評価時に if の形 (Linux) と無いこと (darwin・入れない) を、ビルド時に生成した `hm-session-vars.sh` / `.fish` を bash と fish で読んだ値を確かめる |
| `nix/flake.nix` | checks に `os-ca-bundle-state` |
| `nix/README.md` | 節「証明書の束を OS の信頼ストアに寄せる」(効き方・入れる変数を選ぶ・効かないところと副作用・反映・確かめ方)。「足したホストに書く値」の表に C の 2 つ |
| `docs/adr/README.md` | 一覧に 028 |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| 何もせず、各ツールの束の更新を待つ (certifi・uv の webpki-roots・gcloud の SDK) | 更新の時期がツールごとにばらばらで、古い venv や固定した版は直らない。次の事件でも同じことになる |
| ツールごとの設定ファイルに書く (gcloud の `core/custom_ca_certs_file`・pip.conf・uv.toml) | 書き方がツールごとに違い、venv の requests には置き場が無い。ツールが増えるたびに足す |
| repo ごとの `mise.toml` の `[env]`・devShell に書く | repo ごとに書き漏れる。repo の外で打つ global のツールに効かない |
| nixos-config (NixOS の `environment.variables`) に書く | NixOS のホストにしか効かない。WSL の Ubuntu・GCP の VM が漏れる |
| `home.sessionVariables` に値だけ書く | 条件を書けない。束の無いホストで TLS を全部落とし、すでにある値を上書きする |
| すでにある値は残し、無いものは OS の束にする (この PR の最初の形) | B。`SSL_CERT_FILE` だけがある NixOS で、nixpkgs の OpenSSL が OS の束を読むようになる |
| `REQUESTS_CA_BUNDLE` を入れない | 古い certifi を入れた venv の requests が直らない。副作用は 1 回だけ外せ、ホストごとにも外せる (C・D) |
| fish.nix と bash.nix に別々に書く | 同じ条件を 2 か所に持つ。`hm-session-vars` の「session で 1 回」とも揃わない |
| option にしない (最初の形) | ユーザーが flake で選べるようにと決めた (C) |
| 3 つの値の enum の option 1 つ (`"all"`・`"exceptRequests"`・`"none"` など) | 意味を持たない組み合わせは無くなるが、repo の option は入れ子の bool で揃えていて、enum の option は無い |

## 5. 影響 (Consequences)

良くなること。

- OS の束を直せば、nixpkgs の python の requests・uv・gcloud・venv の requests も揃って従う (cacert を含む devShell の
  中は除く。下の注意)
- もともと OS の束を読むもの (OpenSSL・Go・nix 自身) は、同じファイルを指すだけで変わらない

注意が必要なこと。

- **OS の束が直っていないホストでは、自前の束が先に直ったツールがむしろ通すようになる。** 例えば PyPI の certifi
  2026.10.19 は emSign のルートを外していて、それを入れた venv の requests は変数が無くてもテスト用ホストを拒否する。
  `REQUESTS_CA_BUNDLE` で直っていない OS の束に向けると通す。OS の束を先に (遅くとも同時に) 直す
- **反映は新しい login から。** `hm-session-vars` は 1 つの session で 1 回しか読まない (`__HM_SESS_VARS_SOURCED` を
  子へ継ぐ)。switch の前から続く process (herdr の server など) の下で開いた shell には入らない
- **cacert を含む devShell の中では、`NIX_SSL_CERT_FILE` が nixpkgs の cacert の束に戻る。** cacert の setup hook が
  立て、`nix develop` は derivation の値を残す (呼び出し元の値を残すのは `SSL_CERT_FILE` だけ)。nixpkgs の python の
  certifi が cacert を propagate するので、python の devShell はこれに当たる。その中の nixpkgs の certifi と OpenSSL
  (python の標準の https など) は OS の束を読まない。repo ごとに `shellHook` で向け直す (README)
- **`REQUESTS_CA_BUNDLE` は、アプリが requests の `Session` に置いた `verify` (私設 CA の束・`False`) より先に効く。**
  そういう script は検証に失敗するようになる。`REQUESTS_CA_BUNDLE= <コマンド>` (空) で打てば `Session` の値に戻る。
  よく動かすホストは `REQUESTS_CA_BUNDLE` だけを外す (C)
- `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE` は、gcloud の設定の `core/custom_ca_certs_file` より先に効く
- shell を通らずに起動するもの (systemd の user service・デスクトップのランチャーから直に開くアプリ) には入らない
- この 4 つを読まないツールは、自前の束のまま (OS の束に寄せたいものが見つかったら、この module に足す)

## 6. 検証 (Verification)

`feat/TKT-312-os-ca-bundle-env` で実施。lavie (NixOS。PR #11 で OS の束を直し済み) の上。

| 確認 | 方法 | 結果 |
| --- | --- | --- |
| 生成した設定 | `homeConfigurations."pollenjp@x86_64-linux".activationPackage` を build し、`hm-session-vars.sh` と `config.fish` が読む `hm-session-vars.fish` を見る | 両方に 4 つの if がある (fish は `if [ -f … ]` と `set -gx … (test -n "$X" && echo "$X" \|\| echo …)`) |
| 新しく開いた shell | build した `config.fish`・`.profile`・`.bash_profile`・`.bashrc` を偽の HOME に置き、`__HM_SESS_VARS_SOURCED` を外した env で開く | fish (login・login でない)・bash (login)・fish から開いた bash の 4 通りとも 4 つが入る。`__HM_SESS_VARS_SOURCED=1` を継いだ fish には入らない。`SSL_CERT_FILE=/opt/corp.pem` があれば、4 つともそれに揃う |
| テスト用ホスト | 変数なしと、上の新しい login の fish の env とで繋ぐ | 下の表 |
| テスト | `nix/tests/os-ca-bundle.nix` (checks の `os-ca-bundle-state`) | 評価時 11 件・ビルド時 22 件。4 つ: bash と fish × 束がある・無い・`SSL_CERT_FILE` がある・`NIX_SSL_CERT_FILE` だけある・両方ある・空・空白を含む。`REQUESTS_CA_BUNDLE` 以外: 束がある・`REQUESTS_CA_BUNDLE` がある。入れない: 束がある・`SSL_CERT_FILE` がある。どれも子の `printenv` で見る。最初の形で、module の import を外すと評価で落ち、期待値をずらすとビルドで落ちることを確かめた。darwin と aarch64-linux の check も評価が通る |
| 3 つの選び方の `hm-session-vars.sh` | `lib.mkHome` に `modules` を渡した 3 つの home の `home.sessionVariablesPackage` を build して読む | 既定は 4 つの `export`、`requestsCaBundle.enable = false` は `REQUESTS_CA_BUNDLE` の行だけが無い 3 つ、`enable = false` は if が無い |
| PR のレビューで見つかったこと | 通信なしの python と使い捨ての flake で確かめた | nixpkgs の python の `ssl.create_default_context()` は、`SSL_CERT_FILE` に 1 枚の束・`NIX_SSL_CERT_FILE` なしで 1 個、`NIX_SSL_CERT_FILE` に OS の束を足すと 172 個の CA を読む (B)。requests 2.34.2 は `REQUESTS_CA_BUNDLE` があると `Session.verify` (私設の束・`False`) より env の値を使い、空にすると `Session.verify` に戻る。cacert を含む devShell の中では、呼び出し元に 4 つがあっても `NIX_SSL_CERT_FILE` が nixpkgs の cacert 3.126 の束になり、python の urllib がテスト用ホストに 200 で繋がる (requests は拒否) |

テスト用ホスト `https://dv-g3b-emudhra.we-have-a-problem.com/` への接続:

| ツール | 変数なし | 新しい shell の env | 正しいホスト (新しい shell の env) |
| --- | --- | --- | --- |
| nixpkgs の python 3.14.7 + requests 2.34.2 (certifi 2026.06.17) | HTTP 200 (通す) | SSLError (certificate rejected) | pypi.org: 200 |
| nixpkgs の uv 0.12.17 (`uv pip compile` の `--index-url`) | TLS が通る (Content-Type の誤り) | invalid peer certificate: UnknownIssuer | pypi.org: `idna==3.20` |
| mise の gcloud 564.0.0 (`components list` の取得先を差し替え) | TLS が通る (一覧を読めない) | SSLError | 既定の dl.google.com: 版を読めた |
| venv の PyPI の requests 2.34.2 (certifi 2026.06.17) | HTTP 200 (通す) | SSLError (certificate rejected) | pypi.org: 200 |
| venv の PyPI の requests 2.34.2 (certifi 2026.10.19) | SSLError (certifi が元から外している) | SSLError (certificate rejected) | — |
| mise の uv 0.13.5 | 拒否 (CertDistrusted。元から) | 拒否 (CertDistrusted) | — |
| mise の node v24.22.1 | 拒否 (CERT_REVOKED。元から) | 拒否 (CERT_REVOKED) | — |

## 7. 移行・運用手順

merge したあと、各 Linux のホストで:

```sh
# OS の束が直っているか (証明書のエラーになれば直っている)。直っていなければ先に直す (5 の注意)
curl -sS -o /dev/null https://dv-g3b-emudhra.we-have-a-problem.com/

~/dotfiles/setup --update
```

そのあと、新しい login (ssh を張り直す・ログインし直す) から開いた shell で確かめる。herdr の pane に入れるには
server を止めて、新しい login から開き直す (手順は README の節)。

```sh
printenv SSL_CERT_FILE   # /etc/ssl/certs/ca-certificates.crt
```
