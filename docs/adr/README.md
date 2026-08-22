# ADR (Architecture Decision Record)

構造や運用に影響する決定を、決めた理由ごと残す場所。
「なぜこうなっているのか」を後から辿れるようにするためのもの。

## 一覧

| # | 決定 | 日付 |
| --- | --- | --- |
| [001](./001_home_manager_migration_20260808T163454JST/README.md) | dotfiles 管理を Nix home-manager へ移行する | 2026-08-08 |
| [002](./002_nix_hosts_and_local_flake_20260810T153848JST/README.md) | マシン固有設定の表現と、実行の入口となるパスを決める | 2026-08-10 |
| [003](./003_nix_ssh_config_20260810T210714JST/README.md) | ssh の設定を Nix 管理に載せる範囲を決める | 2026-08-10 |
| [004](./004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md) | WSL の ssh ラッパーを Nix 管理に載せる | 2026-08-11 |
| [005](./005_nix_flake_lock_min_release_age_20260813T184522JST/README.md) | flake.lock に入れる revision へ最小経過日数を課す | 2026-08-13 |
| [006](./006_nix_closure_sbom_osv_scan_20260823T004634JST/README.md) | 閉包を SBOM 化して OSV ベースでスキャンし、pin と先端の差分を照合する | 2026-08-23 |

## ディレクトリ名

```bash
ymdt=$(TZ='Asia/Tokyo' date '+%Y%m%dT%H%M%S%Z')
adr_dir="docs/adr/<adr_index>_<short_title>_${ymdt}"
```

例: `docs/adr/001_id_token_20260626T211959JST/`

- `<adr_index>` は 3 桁の連番。既存の最大値 + 1
- `<short_title>` は snake_case の短い題
- 時刻は **JST**。作成時刻で固定し、あとから変えない

## 書き方

決定そのものより **なぜそう決めたか** と **何を捨てたか** を残す。
既存の ADR を雛形として使う。おおむね次の構成。

| 節 | 中身 |
| --- | --- |
| 背景 (Context) | 何が困っていたか。決定の前提 |
| 決定 (Decision) | 何をどうすると決めたか |
| 変更点の詳細 | どのファイルがどう変わったか |
| 検討した代替案 | 採らなかった案と、採らなかった理由 |
| 影響 (Consequences) | 良くなること / 注意が必要なこと |
| 検証 (Verification) | どう確かめたか |
| 移行・運用手順 | 実際に叩くコマンド |

## 更新の方針

ADR は**決めた時点の記録**なので、あとから決定が変わっても本文は書き換えない。
代わりに新しい ADR を起こし、古い方の冒頭に後続 ADR へのポインタを置く。

ただし **手順書として読まれる部分**（「移行・運用手順」や `textbook/` のような
補足資料）は例外で、現行の形に追従させる。読んだ人がそのまま叩けてしまうため。
どちらを更新してどちらを記録として残したかは、ポインタに明記する。
