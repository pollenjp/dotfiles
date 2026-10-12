# Google 日本語入力と PowerToys の設定を repo のテキストから組み立て直して配る Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows 側の Google 日本語入力 (設定・キー設定・ユーザー辞書) と PowerToys の Keyboard Manager の割り当てを、repo のテキストから `setup --update` で安全に組み立て直して配れるようにする。

**Architecture:** テキストとバイナリを行き来する CLI `pjp-google-ime` (Python + protobuf、Mozc の `.proto` の写しを記述子にして読む) を `nix/pkgs/` に置き、新しい bootstrap `bootstrap-windows-google-ime.sh` (order 98) がそれで組み立て・時刻を除いた比較・退避・配置・変換サーバーの再起動をする。PowerToys の 2 ファイルは今の `win/manifest.toml` で配り、`bootstrap-windows-powertoys.sh` (order 91) が名前付きイベントで読み直させる。辞書は private repo `pollenjp/dotfiles-private` に置き、`bootstrap-dotfiles-private.sh` (order 50) が ghq の下へ clone / pull する。

**Tech Stack:** Python 3.14 + protobuf 7.36.1 (固定した nixpkgs のもの)、protoc (記述子を作るだけ)、bash (`set -eu -o pipefail`・shfmt・shellcheck)、Nix flake (`packages` / `checks`)、home-manager、GitHub Actions。

**Spec:** `docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md` (承認済み)。設計の経緯は cc-page の 0001〜0003 と TKT-139 (https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)。

## Global Constraints

- branch は `feat/TKT-139-google-ime-powertoys` (作業ツリーは `/home/pollenjp/.herdr/worktrees/dotfiles/worktree-calm-stone-6931`)。コマンドはこの作業ツリーの直下で打つ
- commit の題は repo の慣習どおり `type(scope): 日本語の一文 (TKT-139)`。本文の末尾に次の 2 行を必ず付ける
  - `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm`
- Mozc の `.proto` は `google/mozc` の commit `18e76511af9371a9a4409b1d13c3e30884b53e9c` から、手を加えずに写す (BSD-3-Clause。`LICENSE` も写す)
- Python の依存は固定した nixpkgs の `python3.withPackages (ps: [ ps.protobuf ])` だけ。`pip install` はしない。protobuf 7.x の `FieldDescriptor` には `label` が無いので `is_repeated` を使う
- 実行時に LLM は使わない。同じテキストからは毎回同じバイト列を組み立てる (`SerializeToString(deterministic=True)`、時刻も乱数も入れない)
- 置き場所 (Windows 側): Google 日本語入力は `<windowsHome>/AppData/LocalLow/Google/Google Japanese Input/`、PowerToys は `<windowsHome>/AppData/Local/Microsoft/PowerToys/Keyboard Manager/` (どちらも空白を含む)
- 記録と退避 (WSL 側): `~/.local/state/dotfiles/google-japanese-input/deployed.json`・`~/.local/state/dotfiles/google-japanese-input/backup/<UTC の時刻>-<pid>/` (新しい方から 10 回分)・`~/.local/state/dotfiles/powertoys-keyboard-manager.reloaded`
- order: `bootstrap-dotfiles-private.sh` 50、`bootstrap-windows-powertoys.sh` 91、`bootstrap-windows-google-ime.sh` 98。`# order:` の行は説明の 1 行目より後ろに書く (前に書くと setup のメニューの説明に拾われる)
- 終了コード: 0 = 済んだ・飛ばした、1 = 衝突・テキストが壊れている・設定画面が開いている・変換サーバーを落とせない、2 = 知らない引数。`bootstrap-windows-powertoys.sh` と `bootstrap-dotfiles-private.sh` は 2 以外で 0 以外を返さない
- 名前付きイベントは `PowerToys_KeyboardManager_Event_Settings`。変換サーバーは `GoogleIMEJaConverter.exe`、設定画面と辞書ツールは `GoogleIMEJaTool.exe`
- dotfiles-private の clone の場所は `$DOTFILES_PRIVATE_DIR` → `$(ghq root)/github.com/pollenjp/dotfiles-private` → `~/ghq/github.com/pollenjp/dotfiles-private` の順。URL は `$DOTFILES_PRIVATE_URL` (既定 `git@github.com:pollenjp/dotfiles-private.git`)
- **ユーザー辞書の中身 (登録した単語) は、public のこの repo・PR・Notion・ログに出さない**。辞書の TSV は dotfiles-private にだけ置く
- Task 1〜7 では Windows 側に書かない (`bootstrap-windows-files.sh` を `--dry-run` / `--check` なしで流さない・`setup --update` を流さない・本物の `taskkill.exe` を打たない)。Windows 側に触るのは、ユーザーと一緒に進める Task 8〜9 だけ
- メッセージとコメントは日本語 (repo の慣習)。`.sh` は shfmt (`.editorconfig` の設定) と shellcheck、`.nix` は nixfmt を通す

## Review Focus

- `keymap.tsv` を CRLF や末尾の改行なしで保存した → LF・末尾に改行の形と同じバイト列に組み立てる (Task 1 の `test_crlf_keymap_builds_same_bytes`・`test_missing_final_newline_builds_same_bytes`)
- Windows 側の `config1.db` が壊れていて読めない → traceback を出さず衝突として止まる (Task 3 のテスト 16)
- 画面で付けた辞書の名前がファイル名にできない (`/` を含むなど) → `--import` は何も書かずに止まる (Task 1 の `test_import_refuses_bad_dictionary_name_without_writing`)
- dotfiles-private はあるが辞書のディレクトリが無い (取れていない・まだ取り込んでいない) → 辞書を飛ばし、Windows 側の辞書を空で上書きしない (Task 3 のテスト 17)
- 日本語の Windows で `tasklist.exe` が「情報: 指定された条件に一致するタスクは…」と出す → 設定画面が開いていない扱いにする (CSV の `"GoogleIMEJaTool.exe"` だけを見る。Task 3 の偽の tasklist.exe が日本語の行を出す)

---

### Task 1: テキストとバイナリを行き来する CLI `pjp-google-ime` を足す

**Files:**
- Create: `nix/pkgs/pjp-google-ime/proto/config.proto`、`nix/pkgs/pjp-google-ime/proto/user_dictionary_storage.proto`、`nix/pkgs/pjp-google-ime/proto/LICENSE` (Mozc から写す)
- Create: `nix/pkgs/pjp-google-ime/proto/README.md`
- Create: `nix/pkgs/pjp-google-ime/test_google_ime.py`
- Create: `nix/pkgs/pjp-google-ime/google_ime.py`
- Create: `nix/pkgs/pjp-google-ime/default.nix`
- Modify: `nix/flake.nix` (checks の let に `googleIme`、checks に `pjp-google-ime-unittest`、packages に `pjp-google-ime`、コメント)

**Interfaces:**
- Consumes: なし
- Produces:
  - コマンド `pjp-google-ime` (PATH に置かれる名前)。サブコマンドと終了コード (0 成功 / 1 `TextError` / 2 使い方の誤り):
    - `build --config-dir DIR [--dictionary-dir DIR] --out DIR` → `DIR/config1.db` と (辞書があれば) `DIR/user_dictionary.db` を書く
    - `check --config-dir DIR [--dictionary-dir DIR]` → 検証だけ。通れば `OK: …` を 1 行
    - `decode --kind config|dictionary FILE --out DIR` → config なら `DIR/config.txtpb`・`DIR/keymap.tsv`・(あれば) `DIR/romaji.tsv`、dictionary なら `DIR/dictionaries/<名前>.tsv`
    - `digest --kind config|dictionary FILE` → 比べるための sha256 (16 進 64 文字) を 1 行
    - `import --windows-dir DIR --config-dir DIR [--dictionary-dir DIR]` → Windows 側の `config1.db` (と `user_dictionary.db`) からテキストを書き直す (検証が通ってから書く。無い表・辞書のファイルは消す)
  - Nix: `pkgs.callPackage ./pkgs/pjp-google-ime { }` が `writeShellApplication` を返し、`passthru.python` (protobuf 入りの python) と `passthru.descriptors` (記述子のファイル) を持つ。flake の `packages.x86_64-linux.pjp-google-ime`

- [ ] **Step 1: Mozc の `.proto` と LICENSE を写す**

```bash
rev=18e76511af9371a9a4409b1d13c3e30884b53e9c
mkdir -p nix/pkgs/pjp-google-ime/proto
for f in src/protocol/config.proto src/protocol/user_dictionary_storage.proto LICENSE; do
  gh api -H "Accept: application/vnd.github.raw" "repos/google/mozc/contents/${f}?ref=${rev}" >"nix/pkgs/pjp-google-ime/proto/$(basename "${f}")"
done
grep -c 'PosType\|SessionKeymap' nix/pkgs/pjp-google-ime/proto/*.proto
head -1 nix/pkgs/pjp-google-ime/proto/LICENSE
```

Expected: 2 つの `.proto` にそれぞれ 1 以上の数、LICENSE の 1 行目が `Copyright 2010-2018, Google Inc.`。

- [ ] **Step 2: 写しの出典を書く `nix/pkgs/pjp-google-ime/proto/README.md`**

````markdown
# Mozc の .proto の写し

`pjp-google-ime` が Google 日本語入力の `config1.db` と `user_dictionary.db` を読み書きするための、
Mozc の protobuf の定義。手を加えずに写している (ライセンスは `LICENSE`、BSD-3-Clause)。

| ファイル | 写した元 |
| --- | --- |
| `config.proto` | `google/mozc` の `src/protocol/config.proto` |
| `user_dictionary_storage.proto` | `google/mozc` の `src/protocol/user_dictionary_storage.proto` |
| `LICENSE` | `google/mozc` の `LICENSE` |

写した commit: `18e76511af9371a9a4409b1d13c3e30884b53e9c` (2026-10-09)。

## 新しくするとき

新しい版の Google 日本語入力が項目を足すと、`bootstrap-windows-google-ime.sh --import` が
「今の .proto に無い項目がある」で止まる。そのときは同じ 3 つを新しい commit から写し直し、
上の commit を書き換えて、`nix build ./nix#checks.x86_64-linux.pjp-google-ime-unittest` を流す。

```sh
rev=<commit>
for f in src/protocol/config.proto src/protocol/user_dictionary_storage.proto LICENSE; do
  gh api -H "Accept: application/vnd.github.raw" "repos/google/mozc/contents/${f}?ref=${rev}" >"nix/pkgs/pjp-google-ime/proto/$(basename "${f}")"
done
```

辞書の品詞の名前 (`google_ime.py` の `POS_NAMES`) は `user_dictionary_storage.proto` のコメントと
突き合わせてある (`test_google_ime.py`)。品詞が増えたらテストが落ちるので、`POS_NAMES` を足す。
````

- [ ] **Step 3: テストを書く `nix/pkgs/pjp-google-ime/test_google_ime.py`**

```python
"""google_ime の組み立て・取り込み・比べ方のテスト。

Mozc の .proto の写し (proto/) から作った記述子を PJP_GOOGLE_IME_DESCRIPTORS で受け取る
(flake の checks の pjp-google-ime-unittest が設定する)。Windows には触らない。
"""

import contextlib
import io
import os
import pathlib
import re
import tempfile
import unittest

import google_ime as g

HERE = pathlib.Path(__file__).resolve().parent

TXTPB = 'session_keymap: CUSTOM\npunctuation_method: TOUTEN_KUTEN\ncharacter_form_rules {\n  group: "ア"\n  preedit_character_form: FULL_WIDTH\n}\n'
KEYMAP = "status\tkey\tcommand\nDirectInput\tF13\tIMEOn\nPrecomposition\tF13\tIMEOff\nComposition\tF13\tIMEOff\n"
ROMAJI = "a\tあ\nkk\tっ\tk\n"
KEYMAP_HEADER_ONLY = "status\tkey\tcommand\n"
DICT = "てすと\tテスト\t名詞\t\nぐーぐる\tGoogle\t固有名詞\t会社\n"


def setUpModule():
    if not os.environ.get("PJP_GOOGLE_IME_DESCRIPTORS"):
        raise unittest.SkipTest("PJP_GOOGLE_IME_DESCRIPTORS が無い (nix の checks から流す)")


def cfg(txtpb=TXTPB, keymap=KEYMAP, romaji=None):
    return g.config_from_text(txtpb, keymap, romaji)


def with_general_config(c, t):
    """画面で保存したときのように general_config (時刻・版・OS) を入れたものを返す"""
    c2 = type(c)()
    c2.CopyFrom(c)
    c2.general_config.config_version = 1
    c2.general_config.last_modified_time = t
    c2.general_config.platform = "Windows.10.0.0.0"
    return c2


def run(*argv):
    """main を呼び、(終了コード, stdout, stderr) を返す"""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = g.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class TestPosNames(unittest.TestCase):
    def test_match_proto_comments(self):
        text = (HERE / "proto" / "user_dictionary_storage.proto").read_text(encoding="utf-8")
        found = re.findall(r'^\s*[A-Z0-9_]+ = (\d+);\s*// "(.+?)"', text, re.M)
        names = tuple(name for _, name in sorted(found, key=lambda t: int(t[0])))
        self.assertEqual(names, g.POS_NAMES)

    def test_count_matches_enum(self):
        _, storage_cls = g.messages()
        pos = storage_cls.DESCRIPTOR.fields_by_name["dictionaries"].message_type.enum_types_by_name["PosType"]
        self.assertEqual(len(pos.values), len(g.POS_NAMES))


class TestConfigText(unittest.TestCase):
    def test_roundtrip(self):
        txtpb, keymap, romaji = g.config_to_text(cfg(romaji=ROMAJI))
        self.assertTrue(txtpb.startswith("#"))
        self.assertIn('group: "ア"', txtpb)  # 日本語は 8 進数にせず UTF-8 のまま
        self.assertEqual(keymap, KEYMAP)
        self.assertEqual(romaji, ROMAJI)
        self.assertEqual(g.serialize(g.config_from_text(txtpb, keymap, romaji)), g.serialize(cfg(romaji=ROMAJI)))

    def test_build_is_deterministic(self):
        self.assertEqual(g.serialize(cfg()), g.serialize(cfg()))

    def test_no_general_config_in_build(self):
        self.assertFalse(cfg().HasField("general_config"))

    def test_crlf_keymap_builds_same_bytes(self):
        self.assertEqual(g.serialize(cfg(keymap=KEYMAP.replace("\n", "\r\n"))), g.serialize(cfg()))

    def test_missing_final_newline_builds_same_bytes(self):
        self.assertEqual(g.serialize(cfg(keymap=KEYMAP.rstrip("\n"))), g.serialize(cfg()))

    def test_rejects_general_config_in_txtpb(self):
        with self.assertRaisesRegex(g.TextError, "general_config"):
            cfg(txtpb=TXTPB + "general_config { config_version: 1 }\n")

    def test_rejects_keymap_table_in_txtpb(self):
        with self.assertRaisesRegex(g.TextError, "keymap.tsv に置く"):
            cfg(txtpb=TXTPB + 'custom_keymap_table: "status\\tkey\\tcommand\\n"\n')

    def test_parse_error_names_file(self):
        with self.assertRaisesRegex(g.TextError, r"^config\.txtpb:\d+:\d+"):
            cfg(txtpb="no_such_field: 1\n")

    def test_custom_keymap_needs_keymap_tsv(self):
        with self.assertRaisesRegex(g.TextError, "CUSTOM なのに keymap.tsv が無い"):
            cfg(keymap=None)


class TestKeymapCheck(unittest.TestCase):
    def test_header_required(self):
        with self.assertRaisesRegex(g.TextError, r"keymap\.tsv:1:"):
            g.check_keymap("DirectInput\tF13\tIMEOn\n")

    def test_three_columns(self):
        with self.assertRaisesRegex(g.TextError, r"keymap\.tsv:3:"):
            g.check_keymap(KEYMAP_HEADER_ONLY + "DirectInput\tF13\tIMEOn\nPrecomposition\tF13\n")

    def test_unknown_state(self):
        with self.assertRaisesRegex(g.TextError, r"keymap\.tsv:2: 状態名 'Directinput'"):
            g.check_keymap(KEYMAP_HEADER_ONLY + "Directinput\tF13\tIMEOn\n")

    def test_empty_table_rejected(self):
        with self.assertRaisesRegex(g.TextError, "1 つも無い"):
            g.check_keymap(KEYMAP_HEADER_ONLY)

    def test_unknown_command_is_allowed(self):
        # コマンド名は版で増減するので確かめない
        g.check_keymap(KEYMAP_HEADER_ONLY + "DirectInput\tF13\tSomeFutureCommand\n")



class TestRomajiCheck(unittest.TestCase):
    def test_two_or_three_columns(self):
        g.check_romaji(ROMAJI)
        with self.assertRaisesRegex(g.TextError, r"romaji\.tsv:1:"):
            g.check_romaji("a\n")

    def test_output_or_pending_required(self):
        g.check_romaji("n\t\tん\n")
        with self.assertRaisesRegex(g.TextError, r"romaji\.tsv:1:"):
            g.check_romaji("n\t\t\n")


class TestConfigDigest(unittest.TestCase):
    def test_ignores_general_config(self):
        c = cfg()
        self.assertEqual(g.config_digest(with_general_config(c, 1)), g.config_digest(c))
        self.assertEqual(g.config_digest(with_general_config(c, 1)), g.config_digest(with_general_config(c, 2)))

    def test_changes_with_settings(self):
        self.assertNotEqual(g.config_digest(cfg()), g.config_digest(cfg(txtpb=TXTPB + "suggestions_size: 5\n")))


class TestUnknownFields(unittest.TestCase):
    def test_config_with_unknown_field_is_refused(self):
        config_cls, _ = g.messages()
        # 番号 999 の varint (新しい版が足した項目に見立てる)
        data = g.serialize(cfg()) + bytes([0xB8, 0x3E, 0x01])
        c = config_cls.FromString(data)
        self.assertTrue(g.has_unknown(c))
        with self.assertRaisesRegex(g.TextError, r"\.proto に無い項目"):
            g.config_to_text(c)


class TestDictionaries(unittest.TestCase):
    def test_roundtrip(self):
        files = {"ユーザー辞書 1": DICT, "空の辞書": ""}
        self.assertEqual(g.dictionaries_to_tsv(g.dictionaries_from_tsv(files)), files)

    def test_ids_from_name_and_sorted(self):
        st = g.dictionaries_from_tsv({"b": DICT, "a": DICT})
        self.assertEqual([d.name for d in st.dictionaries], ["a", "b"])
        self.assertEqual(st.dictionaries[0].id, g.dictionary_id("a"))
        self.assertNotEqual(g.dictionary_id("a"), g.dictionary_id("b"))

    def test_comment_is_always_present(self):
        e = g.dictionaries_from_tsv({"x": DICT}).dictionaries[0].entries[0]
        self.assertTrue(e.HasField("comment"))
        self.assertEqual(e.comment, "")

    def test_three_columns_mean_empty_comment(self):
        self.assertEqual(
            g.serialize(g.dictionaries_from_tsv({"x": "てすと\tテスト\t名詞\n"})),
            g.serialize(g.dictionaries_from_tsv({"x": "てすと\tテスト\t名詞\t\n"})),
        )

    def test_unknown_pos(self):
        with self.assertRaisesRegex(g.TextError, r"x\.tsv:1: 品詞 '名刺'"):
            g.dictionaries_from_tsv({"x": "てすと\tテスト\t名刺\t\n"})

    def test_bad_columns(self):
        with self.assertRaisesRegex(g.TextError, r"x\.tsv:3:"):
            g.dictionaries_from_tsv({"x": DICT + "だけ\n"})

    def test_bad_names(self):
        for name in ("", ".hidden", "a/b", "a\\b"):
            with self.subTest(name=name), self.assertRaises(g.TextError):
                g.check_dictionary_name(name)

    def test_tab_in_value_cannot_be_written(self):
        st = g.dictionaries_from_tsv({"x": DICT})
        st.dictionaries[0].entries[0].value = "テ\tスト"
        with self.assertRaisesRegex(g.TextError, "タブか改行"):
            g.dictionaries_to_tsv(st)

    def test_digest_ignores_id_and_order(self):
        st = g.dictionaries_from_tsv({"a": DICT, "b": "あ\t亜\t名詞\t\n"})
        other = type(st)()
        for d in reversed(st.dictionaries):  # 並びを逆にし、id を画面が作るような値にする
            c = other.dictionaries.add()
            c.CopyFrom(d)
            c.id = 11262860659733797146
        self.assertEqual(g.dictionary_digest(other), g.dictionary_digest(st))

    def test_digest_changes_with_words(self):
        self.assertNotEqual(
            g.dictionary_digest(g.dictionaries_from_tsv({"a": DICT})),
            g.dictionary_digest(g.dictionaries_from_tsv({"a": DICT + "あ\t亜\t名詞\t\n"})),
        )


class TestCommands(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp))
        self.conf = self.tmp / "conf"
        self.dicts = self.tmp / "dicts"
        self.conf.mkdir()
        self.dicts.mkdir()
        (self.conf / "config.txtpb").write_text(TXTPB, encoding="utf-8")
        (self.conf / "keymap.tsv").write_text(KEYMAP, encoding="utf-8")
        (self.dicts / "ユーザー辞書 1.tsv").write_text(DICT, encoding="utf-8")

    def build(self, out):
        return run("build", "--config-dir", str(self.conf), "--dictionary-dir", str(self.dicts), "--out", str(out))

    def test_build_writes_both_files_deterministically(self):
        self.assertEqual(self.build(self.tmp / "o1")[0], 0)
        self.assertEqual(self.build(self.tmp / "o2")[0], 0)
        for name in ("config1.db", "user_dictionary.db"):
            self.assertEqual((self.tmp / "o1" / name).read_bytes(), (self.tmp / "o2" / name).read_bytes())

    def test_build_without_dictionary_dir(self):
        rc, _, _ = run("build", "--config-dir", str(self.conf), "--out", str(self.tmp / "o"))
        self.assertEqual(rc, 0)
        self.assertFalse((self.tmp / "o" / "user_dictionary.db").exists())

    def test_check_reports_line(self):
        (self.conf / "keymap.tsv").write_text(KEYMAP + "Precomposition\tF14\n", encoding="utf-8")
        rc, _, err = run("check", "--config-dir", str(self.conf))
        self.assertEqual(rc, 1)
        self.assertIn("keymap.tsv:5:", err)

    def test_digest_of_build(self):
        self.build(self.tmp / "o")
        rc, out, _ = run("digest", "--kind", "config", str(self.tmp / "o" / "config1.db"))
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), g.config_digest(cfg()))

    def test_digest_of_broken_file(self):
        broken = self.tmp / "broken.db"
        broken.write_bytes(b"\xff\xff\xff")
        rc, _, err = run("digest", "--kind", "config", str(broken))
        self.assertEqual(rc, 1)
        self.assertIn("読めない", err)

    def test_decode_writes_texts(self):
        self.build(self.tmp / "o")
        out = self.tmp / "decoded"
        self.assertEqual(run("decode", "--kind", "config", str(self.tmp / "o" / "config1.db"), "--out", str(out))[0], 0)
        self.assertEqual(run("decode", "--kind", "dictionary", str(self.tmp / "o" / "user_dictionary.db"), "--out", str(out))[0], 0)
        self.assertEqual((out / "keymap.tsv").read_text(encoding="utf-8"), KEYMAP)
        self.assertFalse((out / "romaji.tsv").exists())
        self.assertEqual((out / "dictionaries" / "ユーザー辞書 1.tsv").read_text(encoding="utf-8"), DICT)

    def test_import_mirrors_windows_side(self):
        win = self.tmp / "win"
        win.mkdir()
        # Windows 側: 画面で保存した (general_config あり)・romaji は無い・辞書は 1 つ
        (win / "config1.db").write_bytes(g.serialize(with_general_config(cfg(), 1782652220)))
        (win / "user_dictionary.db").write_bytes(g.serialize(g.dictionaries_from_tsv({"新しい辞書": DICT})))
        # repo 側: romaji.tsv と、Windows 側に無い辞書がある
        (self.conf / "romaji.tsv").write_text(ROMAJI, encoding="utf-8")
        rc, out, err = run("import", "--windows-dir", str(win), "--config-dir", str(self.conf), "--dictionary-dir", str(self.dicts))
        self.assertEqual(rc, 0, err)
        self.assertFalse((self.conf / "romaji.tsv").exists())
        self.assertEqual(sorted(p.name for p in self.dicts.glob("*.tsv")), ["新しい辞書.tsv"])
        self.assertIn("消した:", out)
        # 取り込んだテキストから組み立てると、Windows 側と同じ digest になる
        self.build(self.tmp / "o")
        self.assertEqual(
            g.config_digest(g.read_config_db(self.tmp / "o" / "config1.db")), g.config_digest(g.read_config_db(win / "config1.db"))
        )

    def test_import_twice_reports_no_change(self):
        win = self.tmp / "win"
        win.mkdir()
        (win / "config1.db").write_bytes(g.serialize(cfg()))
        run("import", "--windows-dir", str(win), "--config-dir", str(self.conf))
        rc, out, _ = run("import", "--windows-dir", str(win), "--config-dir", str(self.conf))
        self.assertEqual(rc, 0)
        self.assertIn("同じです", out)

    def test_import_refuses_unknown_fields_without_writing(self):
        win = self.tmp / "win"
        win.mkdir()
        (win / "config1.db").write_bytes(g.serialize(cfg(txtpb=TXTPB + "suggestions_size: 9\n")) + bytes([0xB8, 0x3E, 0x01]))
        before = (self.conf / "config.txtpb").read_text(encoding="utf-8")
        rc, _, err = run("import", "--windows-dir", str(win), "--config-dir", str(self.conf))
        self.assertEqual(rc, 1)
        self.assertIn(".proto に無い項目", err)
        self.assertEqual((self.conf / "config.txtpb").read_text(encoding="utf-8"), before)

    def test_import_refuses_bad_dictionary_name_without_writing(self):
        win = self.tmp / "win"
        win.mkdir()
        (win / "config1.db").write_bytes(g.serialize(cfg(txtpb=TXTPB + "suggestions_size: 9\n")))
        st = g.dictionaries_from_tsv({"ok": DICT})
        st.dictionaries[0].name = "a/b"
        (win / "user_dictionary.db").write_bytes(g.serialize(st))
        before = (self.conf / "config.txtpb").read_text(encoding="utf-8")
        rc, _, err = run("import", "--windows-dir", str(win), "--config-dir", str(self.conf), "--dictionary-dir", str(self.dicts))
        self.assertEqual(rc, 1)
        self.assertIn("ファイル名にできない", err)
        self.assertEqual((self.conf / "config.txtpb").read_text(encoding="utf-8"), before)
        self.assertTrue((self.dicts / "ユーザー辞書 1.tsv").exists())


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: パッケージ `nix/pkgs/pjp-google-ime/default.nix` を書く**

```nix
# Google 日本語入力の設定 (config1.db) とユーザー辞書 (user_dictionary.db) を、repo のテキストと
# 行き来させる CLI (ADR 015)。Windows には触らない (置くのと変換サーバーを落とすのは
# scripts/bootstrap-windows-google-ime.sh)。
#
# Mozc の .proto の写し (proto/) から、ビルドのときに protoc で記述子 (FileDescriptorSet) を作り、
# Python の protobuf がそれを読む。protoc で *_pb2.py を生成しないのは、生成したコードが
# protoc と runtime の版の組み合わせに縛られるため (記述子なら、どちらの版にもよらない)。
{
  runCommand,
  writeShellApplication,
  protobuf,
  python3,
}:

let
  descriptors = runCommand "mozc-descriptors.pb" { nativeBuildInputs = [ protobuf ]; } ''
    protoc --include_imports --descriptor_set_out=$out -I ${./proto} config.proto user_dictionary_storage.proto
  '';
  python = python3.withPackages (ps: [ ps.protobuf ]);
in
writeShellApplication {
  name = "pjp-google-ime";
  runtimeInputs = [ python ];
  text = ''
    export PJP_GOOGLE_IME_DESCRIPTORS=${descriptors}
    exec python3 -I ${./google_ime.py} "$@"
  '';
  # flake の checks (pjp-google-ime-unittest) が、同じ python と記述子でテストを流すために使う
  passthru = { inherit descriptors python; };
}
```

- [ ] **Step 5: `nix/flake.nix` に check と package を足す**

checks の `let` の `pkgs = …;` の次の行に足す:

```nix
          googleIme = pkgs.callPackage ./pkgs/pjp-google-ime { };
```

checks の冒頭のコメント (`#   claude-notion.nix …` の行) の後ろに足す:

```nix
      #
      # pjp-google-ime (ADR 015) の unittest と bootstrap-windows-google-ime.test.sh は、protobuf の入った
      # python と記述子 (Mozc の .proto から作る) が要るので、unittest / scriptTest ではなく専用に組む。
```

`lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux { … }` の checks の最後 (`bootstrap-claude-hook-test = …;` の次) に足す:

```nix
          pjp-google-ime-unittest =
            pkgs.runCommand "pjp-google-ime-unittest"
              {
                nativeBuildInputs = [ googleIme.python ];
                PJP_GOOGLE_IME_DESCRIPTORS = googleIme.descriptors;
              }
              ''
                cd ${./pkgs/pjp-google-ime}
                PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -v -p 'test_*.py'
                touch $out
              '';
```

packages の Linux だけの塊 (`pjp-who-is-asking = …;` の次) に足し、その上のコメント (`#   nix run ./nix#pjp-who-is-asking` の行) の後ろに 3 行足す:

```nix
        #
        # Google 日本語入力の設定とテキストを行き来させる道具 (ADR 015) も、WSL のマシンでしか使わない。
        # home には home/modules/windows-files.nix が入れる。CI の lint は nix shell ./nix#pjp-google-ime で借りる。
```

```nix
          pjp-google-ime = pkgs.callPackage ./pkgs/pjp-google-ime { };
```

- [ ] **Step 6: テストが落ちることを確かめる (本体がまだ無い)**

Run: `git add -N nix/pkgs/pjp-google-ime && nix build --no-link -L './nix#checks.x86_64-linux.pjp-google-ime-unittest' 2>&1 | tail -5`
Expected: FAIL。`ModuleNotFoundError: No module named 'google_ime'` (`google_ime.py` がまだ無いので `default.nix` の `${./google_ime.py}` で評価が止まるなら、それも可)。

- [ ] **Step 7: 本体 `nix/pkgs/pjp-google-ime/google_ime.py` を書く**

```python
"""Google 日本語入力の設定 (config1.db) とユーザー辞書 (user_dictionary.db) を、repo のテキストと
行き来させる (docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md)。

Windows には触らない。読み書きするのは渡されたパスのファイルだけで、Windows 側へ置くのと
変換サーバーを落とすのは nix/scripts/bootstrap-windows-google-ime.sh がやる。

テキストの形:

  <config-dir>/config.txtpb    config1.db のうち、general_config・custom_keymap_table・
                               custom_roman_table を除いた全項目 (protobuf のテキスト形式)
  <config-dir>/keymap.tsv      custom_keymap_table の文字列そのもの (キー設定の画面のエクスポートと同じ)
  <config-dir>/romaji.tsv      custom_roman_table の文字列そのもの (カスタムしたときだけ置く)
  <dictionary-dir>/<名前>.tsv  辞書 1 つ。「読み<TAB>単語<TAB>品詞<TAB>コメント」(辞書ツールのエクスポートと同じ)

同じテキストからは毎回同じバイト列を組み立てる。直列化は deterministic にし、時刻も乱数も入れない
(general_config は書かず、辞書の id は名前の sha256 から作る)。

Mozc の .proto の写し (proto/) から作った記述子を、環境変数 PJP_GOOGLE_IME_DESCRIPTORS で受け取る
(default.nix が設定する)。
"""

import argparse
import functools
import hashlib
import os
import pathlib
import sys

from google.protobuf import descriptor_pb2, descriptor_pool, message_factory, text_format, unknown_fields
from google.protobuf.message import DecodeError

CONFIG_DB = "config1.db"
DICTIONARY_DB = "user_dictionary.db"
TXTPB = "config.txtpb"
KEYMAP = "keymap.tsv"
ROMAJI = "romaji.tsv"

TXTPB_HEADER = (
    "# Google 日本語入力の設定 (config1.db) のうち、キー設定 (keymap.tsv)・ローマ字テーブル (romaji.tsv)・\n"
    "# general_config を除いた全項目。protobuf のテキスト形式 (Mozc の mozc.config.Config)。\n"
    "# 画面で変えたら nix/scripts/bootstrap-windows-google-ime.sh --import で書き直す (ADR 015)。\n"
)

KEYMAP_HEADER = "status\tkey\tcommand"
# Mozc の session/keymap.cc が受け付ける状態名 (Direct は DirectInput の別名)。
# コマンド名は版によって増減し、古い名前も別名で通るので確かめない (ADR 015 §1 の 4)。
KEYMAP_STATES = frozenset(
    {
        "DirectInput",
        "Direct",
        "Precomposition",
        "Composition",
        "Conversion",
        "ZeroQuerySuggestion",
        "Suggestion",
        "Prediction",
    }
)

# 辞書の品詞の名前。添え字が mozc.user_dictionary.UserDictionary.PosType の値で、並びは
# Mozc の data/rules/user_pos.def と同じ (test_google_ime.py が .proto のコメントと突き合わせる)。
POS_NAMES = (
    "品詞なし",
    "名詞",
    "短縮よみ",
    "サジェストのみ",
    "固有名詞",
    "人名",
    "姓",
    "名",
    "組織",
    "地名",
    "名詞サ変",
    "名詞形動",
    "数",
    "アルファベット",
    "記号",
    "顔文字",
    "副詞",
    "連体詞",
    "接続詞",
    "感動詞",
    "接頭語",
    "助数詞",
    "接尾一般",
    "接尾人名",
    "接尾地名",
    "動詞ワ行五段",
    "動詞カ行五段",
    "動詞サ行五段",
    "動詞タ行五段",
    "動詞ナ行五段",
    "動詞マ行五段",
    "動詞ラ行五段",
    "動詞ガ行五段",
    "動詞バ行五段",
    "動詞ハ行四段",
    "動詞一段",
    "動詞カ変",
    "動詞サ変",
    "動詞ザ変",
    "動詞ラ変",
    "形容詞",
    "終助詞",
    "句読点",
    "独立語",
    "抑制単語",
)
POS_INDEX = {name: i for i, name in enumerate(POS_NAMES)}

# Mozc の dictionary/user_dictionary_storage.cc の上限
MAX_DICTIONARIES = 100
MAX_ENTRIES = 1_000_000


class TextError(Exception):
    """テキストかバイナリが、組み立て・取り込みの決まりに合わない"""


# ------------------------------------------------------------------ protobuf


@functools.cache
def messages():
    """記述子から (Config, UserDictionaryStorage) のクラスを作る"""
    path = os.environ.get("PJP_GOOGLE_IME_DESCRIPTORS")
    if not path:
        raise TextError("PJP_GOOGLE_IME_DESCRIPTORS が設定されていない (pjp-google-ime から呼ぶ)")
    fds = descriptor_pb2.FileDescriptorSet.FromString(pathlib.Path(path).read_bytes())
    pool = descriptor_pool.DescriptorPool()
    for f in fds.file:
        pool.Add(f)
    config = message_factory.GetMessageClass(pool.FindMessageTypeByName("mozc.config.Config"))
    storage = message_factory.GetMessageClass(pool.FindMessageTypeByName("mozc.user_dictionary.UserDictionaryStorage"))
    return config, storage


def serialize(msg):
    """deterministic に直列化する (同じ中身なら毎回同じバイト列)"""
    return msg.SerializeToString(deterministic=True)


def has_unknown(msg):
    """msg か、その中の message に、今の .proto に無い項目が残っているか"""
    if len(unknown_fields.UnknownFieldSet(msg)) > 0:
        return True
    for field, value in msg.ListFields():
        if field.message_type is None:
            continue
        values = value if field.is_repeated else [value]
        if any(has_unknown(v) for v in values):
            return True
    return False


def parse(cls, data, path):
    """バイナリを読む。読めなければ TextError"""
    try:
        return cls.FromString(data)
    except DecodeError:
        raise TextError(f"{path} を読めない (壊れているか、Google 日本語入力のファイルではない)") from None


# ------------------------------------------------------------------ 設定 (config1.db)


def split_lines(text):
    """CRLF を LF にそろえ、末尾の改行を除いた行の list にする"""
    lines = text.replace("\r\n", "\n").split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def check_keymap(text):
    """keymap.tsv を確かめ、config1.db に入れる形 (LF・末尾に改行) にして返す"""
    lines = split_lines(text)
    if not lines or lines[0] != KEYMAP_HEADER:
        raise TextError(f"{KEYMAP}:1: 1 行目は見出しの「status<TAB>key<TAB>command」にする")
    if len(lines) == 1:
        raise TextError(f"{KEYMAP}: キーの行が 1 つも無い (空のキー設定は配らない)")
    for n, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        if len(fields) != 3 or not all(fields):
            raise TextError(f"{KEYMAP}:{n}: 「状態<TAB>キー<TAB>コマンド」の 3 列になっていない: {line!r}")
        if fields[0] not in KEYMAP_STATES:
            states = "・".join(sorted(KEYMAP_STATES))
            raise TextError(f"{KEYMAP}:{n}: 状態名 {fields[0]!r} は Mozc に無い ({states} のどれか)")
    return "\n".join(lines) + "\n"


def check_romaji(text):
    """romaji.tsv を確かめ、config1.db に入れる形 (LF・末尾に改行) にして返す"""
    lines = split_lines(text)
    if not lines:
        raise TextError(f"{ROMAJI}: 行が 1 つも無い (カスタムしないなら {ROMAJI} を置かない)")
    for n, line in enumerate(lines, start=1):
        fields = line.split("\t")
        if not 2 <= len(fields) <= 3 or not fields[0] or not any(fields[1:]):
            raise TextError(f"{ROMAJI}:{n}: 「入力<TAB>出力[<TAB>次の入力]」になっていない: {line!r}")
    return "\n".join(lines) + "\n"


def config_from_text(txtpb, keymap=None, romaji=None):
    """テキストから Config を組み立てる"""
    config_cls, _ = messages()
    cfg = config_cls()
    try:
        text_format.Parse(txtpb, cfg)
    except text_format.ParseError as e:
        raise TextError(f"{TXTPB}:{e}") from None
    for name, hint in (
        ("general_config", "書かない (時刻・版・OS は Google 日本語入力が保存のたびに入れる)"),
        ("custom_keymap_table", f"書かずに {KEYMAP} に置く"),
        ("custom_roman_table", f"書かずに {ROMAJI} に置く"),
    ):
        if cfg.HasField(name):
            raise TextError(f"{TXTPB}: {name} は{hint}")
    if keymap is not None:
        cfg.custom_keymap_table = check_keymap(keymap).encode()
    if romaji is not None:
        cfg.custom_roman_table = check_romaji(romaji).encode()
    custom = cfg.DESCRIPTOR.fields_by_name["session_keymap"].enum_type.values_by_name["CUSTOM"].number
    if cfg.HasField("session_keymap") and cfg.session_keymap == custom and keymap is None:
        raise TextError(f"{TXTPB}: session_keymap が CUSTOM なのに {KEYMAP} が無い")
    return cfg


def config_to_text(cfg):
    """Config を (config.txtpb, keymap.tsv か None, romaji.tsv か None) の中身にする"""
    if has_unknown(cfg):
        raise TextError(
            f"{CONFIG_DB} に今の .proto に無い項目がある (新しい版の Google 日本語入力が足した項目)。"
            "nix/pkgs/pjp-google-ime/proto/ の写しを新しくする"
        )
    rest = type(cfg)()
    rest.CopyFrom(cfg)
    tables = []
    for name, file in (("custom_keymap_table", KEYMAP), ("custom_roman_table", ROMAJI)):
        if not rest.HasField(name):
            tables.append(None)
            continue
        try:
            tables.append(getattr(rest, name).decode())
        except UnicodeDecodeError:
            raise TextError(f"{CONFIG_DB} の {name} が UTF-8 ではないので {file} に書けない") from None
        rest.ClearField(name)
    rest.ClearField("general_config")
    return TXTPB_HEADER + text_format.MessageToString(rest, as_utf8=True), tables[0], tables[1]


def config_digest(cfg):
    """比べるための sha256。general_config (時刻・版・OS) は外す"""
    c = type(cfg)()
    c.CopyFrom(cfg)
    c.ClearField("general_config")
    return hashlib.sha256(serialize(c)).hexdigest()


# ------------------------------------------------------------------ 辞書 (user_dictionary.db)


def dictionary_id(name):
    """辞書の id。乱数ではなく名前から作る (0 は使わない)"""
    return int.from_bytes(hashlib.sha256(name.encode()).digest()[:8], "big") or 1


def check_dictionary_name(name):
    if not name or name.startswith(".") or any(c in name for c in "/\\\t\n\r\0"):
        raise TextError(f"辞書の名前 {name!r} はファイル名にできない (画面で名前を変える)")


def dictionaries_from_tsv(files):
    """{辞書の名前: TSV の中身} から UserDictionaryStorage を組み立てる"""
    _, storage_cls = messages()
    if len(files) > MAX_DICTIONARIES:
        raise TextError(f"辞書が {len(files)} 個ある (Mozc の上限は {MAX_DICTIONARIES} 個)")
    storage = storage_cls()
    for name in sorted(files):
        check_dictionary_name(name)
        lines = split_lines(files[name])
        if len(lines) > MAX_ENTRIES:
            raise TextError(f"{name}.tsv: 語が {len(lines)} 個ある (Mozc の上限は {MAX_ENTRIES} 個)")
        d = storage.dictionaries.add()
        d.id = dictionary_id(name)
        d.name = name
        for n, line in enumerate(lines, start=1):
            fields = line.split("\t")
            if len(fields) == 3:
                fields.append("")
            if len(fields) != 4 or not fields[0] or not fields[1]:
                raise TextError(f"{name}.tsv:{n}: 「読み<TAB>単語<TAB>品詞<TAB>コメント」になっていない: {line!r}")
            if fields[2] not in POS_INDEX:
                raise TextError(f"{name}.tsv:{n}: 品詞 {fields[2]!r} は Mozc に無い")
            e = d.entries.add()
            e.key = fields[0]
            e.value = fields[1]
            # 画面で作った語は、コメントが空でも必ず「ある」扱いで入っている。そろえる
            e.comment = fields[3]
            e.pos = POS_INDEX[fields[2]]
    return storage


def dictionaries_to_tsv(storage):
    """UserDictionaryStorage を {辞書の名前: TSV の中身} にする"""
    if has_unknown(storage):
        raise TextError(
            f"{DICTIONARY_DB} に今の .proto に無い項目がある (新しい版の Google 日本語入力が足した項目)。"
            "nix/pkgs/pjp-google-ime/proto/ の写しを新しくする"
        )
    files = {}
    for d in storage.dictionaries:
        check_dictionary_name(d.name)
        if d.name in files:
            raise TextError(f"辞書の名前 {d.name!r} が 2 つある (画面で名前を変える)")
        rows = []
        for e in d.entries:
            if e.locale:
                raise TextError(f"辞書 {d.name!r} の語 {e.key!r} に locale が付いていて、TSV に書けない")
            if any(c in v for v in (e.key, e.value, e.comment) for c in "\t\n\r"):
                raise TextError(f"辞書 {d.name!r} の語 {e.key!r} にタブか改行が入っていて、TSV に書けない")
            rows.append(f"{e.key}\t{e.value}\t{POS_NAMES[e.pos]}\t{e.comment}\n")
        files[d.name] = "".join(rows)
    return files


def dictionary_digest(storage):
    """比べるための sha256。辞書の id と辞書の並びは外す (画面で作った辞書の id は乱数のため)"""
    s = type(storage)()
    s.CopyFrom(storage)
    s.ClearField("dictionaries")
    for d in sorted(storage.dictionaries, key=lambda d: d.name):
        c = s.dictionaries.add()
        c.CopyFrom(d)
        c.ClearField("id")
    return hashlib.sha256(serialize(s)).hexdigest()


# ------------------------------------------------------------------ ファイル


def read_text(path):
    try:
        return pathlib.Path(path).read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise TextError(f"{path} が UTF-8 ではない") from None


def read_config_dir(config_dir):
    """<config-dir> から (config.txtpb, keymap.tsv か None, romaji.tsv か None) を読む"""
    d = pathlib.Path(config_dir)
    if not (d / TXTPB).is_file():
        raise TextError(f"{d / TXTPB} が無い")
    keymap = read_text(d / KEYMAP) if (d / KEYMAP).is_file() else None
    romaji = read_text(d / ROMAJI) if (d / ROMAJI).is_file() else None
    return read_text(d / TXTPB), keymap, romaji


def read_dictionary_dir(dictionary_dir):
    """<dictionary-dir> の *.tsv を {辞書の名前: 中身} にする"""
    return {p.name[: -len(".tsv")]: read_text(p) for p in sorted(pathlib.Path(dictionary_dir).glob("*.tsv")) if p.is_file()}


def read_config_db(path):
    config_cls, _ = messages()
    return parse(config_cls, pathlib.Path(path).read_bytes(), path)


def read_dictionary_db(path):
    _, storage_cls = messages()
    return parse(storage_cls, pathlib.Path(path).read_bytes(), path)


def write_if_changed(path, text, changed):
    if path.is_file() and read_text(path) == text:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    changed.append(f"書いた: {path}")


def remove_if_exists(path, changed):
    if path.is_file():
        path.unlink()
        changed.append(f"消した: {path}")


def write_config_texts(config_dir, txtpb, keymap, romaji):
    """設定のテキストを書く。無い表のファイルは消す。書いた・消したファイルの行を返す"""
    d = pathlib.Path(config_dir)
    changed = []
    write_if_changed(d / TXTPB, txtpb, changed)
    for name, text in ((KEYMAP, keymap), (ROMAJI, romaji)):
        if text is None:
            remove_if_exists(d / name, changed)
        else:
            write_if_changed(d / name, text, changed)
    return changed


def write_dictionary_texts(dictionary_dir, files):
    """辞書の TSV を書く。無くなった辞書の TSV は消す。書いた・消したファイルの行を返す"""
    d = pathlib.Path(dictionary_dir)
    changed = []
    for name, text in sorted(files.items()):
        write_if_changed(d / f"{name}.tsv", text, changed)
    if d.is_dir():
        for p in sorted(d.glob("*.tsv")):
            if p.name[: -len(".tsv")] not in files:
                remove_if_exists(p, changed)
    return changed


# ------------------------------------------------------------------ 組み立てと検証


def build_config(config_dir):
    """<config-dir> から Config を組み立て、読み直しても同じ中身に戻ることを確かめる"""
    cfg = config_from_text(*read_config_dir(config_dir))
    config_cls, _ = messages()
    again = config_from_text(*config_to_text(parse(config_cls, serialize(cfg), TXTPB)))
    if serialize(again) != serialize(cfg):
        raise TextError(f"{config_dir}: 組み立てたものを読み直すと中身が変わる")
    return cfg


def build_dictionaries(dictionary_dir):
    """<dictionary-dir> から UserDictionaryStorage を組み立て、読み直しても同じ中身に戻ることを確かめる"""
    storage = dictionaries_from_tsv(read_dictionary_dir(dictionary_dir))
    _, storage_cls = messages()
    again = dictionaries_from_tsv(dictionaries_to_tsv(parse(storage_cls, serialize(storage), DICTIONARY_DB)))
    if serialize(again) != serialize(storage):
        raise TextError(f"{dictionary_dir}: 組み立てたものを読み直すと中身が変わる")
    return storage


# ------------------------------------------------------------------ サブコマンド


def cmd_build(a):
    out = pathlib.Path(a.out)
    cfg = build_config(a.config_dir)
    storage = build_dictionaries(a.dictionary_dir) if a.dictionary_dir else None
    out.mkdir(parents=True, exist_ok=True)
    (out / CONFIG_DB).write_bytes(serialize(cfg))
    if storage is not None:
        (out / DICTIONARY_DB).write_bytes(serialize(storage))


def cmd_check(a):
    build_config(a.config_dir)
    n = 0
    if a.dictionary_dir:
        n = len(build_dictionaries(a.dictionary_dir).dictionaries)
    print(f"OK: {a.config_dir}" + (f" と辞書 {n} 個 ({a.dictionary_dir})" if a.dictionary_dir else ""))


def cmd_decode(a):
    out = pathlib.Path(a.out)
    if a.kind == "config":
        write_config_texts(out, *config_to_text(read_config_db(a.file)))
    else:
        write_dictionary_texts(out / "dictionaries", dictionaries_to_tsv(read_dictionary_db(a.file)))


def cmd_digest(a):
    if a.kind == "config":
        print(config_digest(read_config_db(a.file)))
    else:
        print(dictionary_digest(read_dictionary_db(a.file)))


def cmd_import(a):
    win = pathlib.Path(a.windows_dir)
    if not (win / CONFIG_DB).is_file():
        raise TextError(f"{win / CONFIG_DB} が無い")
    cfg = read_config_db(win / CONFIG_DB)
    texts = config_to_text(cfg)
    if config_digest(config_from_text(*texts)) != config_digest(cfg):
        raise TextError(f"{CONFIG_DB} をテキストに戻すと中身が変わる (テキストで表せない項目がある)")
    files = None
    if a.dictionary_dir:
        _, storage_cls = messages()
        p = win / DICTIONARY_DB
        storage = read_dictionary_db(p) if p.is_file() else storage_cls()
        files = dictionaries_to_tsv(storage)
        if dictionary_digest(dictionaries_from_tsv(files)) != dictionary_digest(storage):
            raise TextError(f"{DICTIONARY_DB} をテキストに戻すと中身が変わる (TSV で表せない項目がある)")
    # ここまで通ってから書く (途中で止まっても、テキストを半端に書き換えない)
    changed = write_config_texts(a.config_dir, *texts)
    if files is not None:
        changed += write_dictionary_texts(a.dictionary_dir, files)
    for line in changed:
        print(line)
    if not changed:
        print("テキストは今のままで同じです。")


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="pjp-google-ime",
        description="Google 日本語入力の設定とユーザー辞書を、repo のテキストと行き来させる (ADR 015)",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="テキストから config1.db (と user_dictionary.db) を組み立てる")
    b.add_argument("--config-dir", required=True)
    b.add_argument("--dictionary-dir")
    b.add_argument("--out", required=True)

    c = sub.add_parser("check", help="テキストを確かめるだけ (何も書かない)")
    c.add_argument("--config-dir", required=True)
    c.add_argument("--dictionary-dir")

    d = sub.add_parser("decode", help="バイナリをテキストに戻す (--out の下に書く)")
    d.add_argument("--kind", choices=("config", "dictionary"), required=True)
    d.add_argument("file")
    d.add_argument("--out", required=True)

    g = sub.add_parser("digest", help="比べるための sha256 を出す (時刻・辞書の id と並びは外す)")
    g.add_argument("--kind", choices=("config", "dictionary"), required=True)
    g.add_argument("file")

    i = sub.add_parser("import", help="Windows 側のファイルを読み、テキストを書き直す")
    i.add_argument("--windows-dir", required=True)
    i.add_argument("--config-dir", required=True)
    i.add_argument("--dictionary-dir")

    a = p.parse_args(argv)
    commands = {"build": cmd_build, "check": cmd_check, "decode": cmd_decode, "digest": cmd_digest, "import": cmd_import}
    try:
        commands[a.cmd](a)
    except TextError as e:
        print(f"pjp-google-ime: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 8: テストが通ることを確かめる**

Run: `git add -N nix/pkgs/pjp-google-ime && nix build --no-link -L './nix#checks.x86_64-linux.pjp-google-ime-unittest' 2>&1 | grep -E 'Ran [0-9]+ tests|^.*OK$|FAIL|Error' | tail -5`
Expected: `Ran 41 tests` と `OK`。`skipped` が出たら `PJP_GOOGLE_IME_DESCRIPTORS` が渡っていない (Step 5 の check の書き方を見直す)。

Run: `nix run ./nix#pjp-google-ime -- --help | head -3`
Expected: `usage: pjp-google-ime [-h] {build,check,decode,digest,import} ...`

- [ ] **Step 9: nixfmt を通す**

Run: `nix develop ./nix --command nixfmt --check nix/flake.nix nix/pkgs/pjp-google-ime/default.nix`
Expected: 何も出ずに終了コード 0 (出たら `nixfmt` を付けずに流して直す)。

- [ ] **Step 10: Commit**

```bash
git add nix/pkgs/pjp-google-ime nix/flake.nix
git commit -F - <<'EOF'
feat(nix): Google 日本語入力の設定とテキストを行き来させる pjp-google-ime を足す (TKT-139)

Mozc の .proto の写しから記述子を作り、config1.db / user_dictionary.db と repo のテキスト
(config.txtpb・keymap.tsv・romaji.tsv・辞書の TSV) を行き来させる。比べるための digest は
general_config (時刻・版・OS) と辞書の id・並びを外す。ADR 015 の B。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 2: この PC の今の設定を `win/google-japanese-input/` のテキストにする

**Files:**
- Create: `win/google-japanese-input/config.txtpb`、`win/google-japanese-input/keymap.tsv` (どちらも `pjp-google-ime import` が書く。手で書かない)

**Interfaces:**
- Consumes: Task 1 の `pjp-google-ime import` / `build` / `digest` / `check`
- Produces: `win/google-japanese-input/config.txtpb` と `keymap.tsv` (Task 3 の bootstrap と CI の `--check` が読む)

辞書はここでは取り込まない (dotfiles-private を作ってから、Task 8 で取り込む)。Windows 側は読むだけで書かない。

- [ ] **Step 1: Windows 側から取り込む**

```bash
ime='/mnt/c/Users/polle/AppData/LocalLow/Google/Google Japanese Input'
nix run ./nix#pjp-google-ime -- import --windows-dir "${ime}" --config-dir win/google-japanese-input
```

Expected: `書いた: win/google-japanese-input/config.txtpb` と `書いた: win/google-japanese-input/keymap.tsv` の 2 行。`romaji.tsv` は書かれない (ローマ字テーブルはカスタムしていない)。

- [ ] **Step 2: 組み立て直すと Windows 側と同じ中身になることを確かめる**

```bash
tmp=$(mktemp -d)
nix run ./nix#pjp-google-ime -- build --config-dir win/google-japanese-input --out "${tmp}"
a=$(nix run ./nix#pjp-google-ime -- digest --kind config "${ime}/config1.db")
b=$(nix run ./nix#pjp-google-ime -- digest --kind config "${tmp}/config1.db")
[[ ${a} == "${b}" ]] && echo SAME || echo DIFFERENT
nix run ./nix#pjp-google-ime -- check --config-dir win/google-japanese-input
```

Expected: `SAME` と `OK: win/google-japanese-input`。

- [ ] **Step 3: 中身を目で見る**

Run: `head -12 win/google-japanese-input/config.txtpb; grep -n 'F13' win/google-japanese-input/keymap.tsv`
Expected: 先頭に `#` で始まる 3 行の説明、`session_keymap: CUSTOM` を含む項目。keymap に `DirectInput	F13	IMEOn` と、`Precomposition`・`Composition`・`Conversion` の `F13	IMEOff` の行。

- [ ] **Step 4: Commit**

```bash
git add win/google-japanese-input
git commit -F - <<'EOF'
feat(win): この PC の Google 日本語入力の設定とキー設定を win/google-japanese-input/ のテキストにする (TKT-139)

pjp-google-ime import で config1.db から書き出した。組み立て直すと Windows 側と同じ digest になる。
キー設定は MS-IME 風に F13 → IMEOn / IMEOff の 4 行を足したもの。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 3: 組み立てて配る `bootstrap-windows-google-ime.sh` を足す

**Files:**
- Create: `nix/tests/bootstrap-windows-google-ime.test.sh`
- Create: `nix/scripts/bootstrap-windows-google-ime.sh` (実行ビットを付ける)
- Modify: `nix/flake.nix` (checks に `bootstrap-windows-google-ime-test`)

**Interfaces:**
- Consumes: Task 1 の `pjp-google-ime` (PATH から `build` / `digest` / `decode` / `import` / `check` を呼ぶ)、Task 2 のテキスト、`~/.local/state/dotfiles/windows-files.json` (`{"enable":…,"windowsHome":…}`)
- Produces: `nix/scripts/bootstrap-windows-google-ime.sh [--dry-run|--force|--import|--check]`。CI (Task 6) が `--check` を、setup が引数なしを呼ぶ

- [ ] **Step 1: テストを書く `nix/tests/bootstrap-windows-google-ime.test.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-google-ime.sh の振る舞いを、使い捨ての HOME と
# 偽の tasklist.exe / taskkill.exe で確かめる。
#
#   bash nix/tests/bootstrap-windows-google-ime.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-google-ime-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils・findutils・diffutils・grep・sed と、PATH の pjp-google-ime だけ。
#
# ## 確かめること
#
#   - 配らないマシン・Google 日本語入力が入っていないマシンは飛ばす (exit 0)
#   - interop (tasklist.exe) が使えなければ置かずに exit 0。設定画面が開いていれば exit 1
#   - 壊れたテキストは何も置かずに exit 1 (行番号を出す)
#   - 4 通りの判定 (置く・同じ・repo 側が進んだ・衝突)、画面で保存しただけ (時刻だけ違う) は「同じ」
#   - 置いたときだけ taskkill.exe /F で変換サーバーを落とす。動いていない (128) のは成功扱い
#   - 退避は新しい方から 10 回分。--force / --dry-run / --import / --check
#   - 辞書のテキストが無ければ辞書は飛ばす (Windows 側の辞書を消さない)
#
# ## 本物の Windows のコマンドを見せない
#
# WSL では PATH に本物の tasklist.exe と taskkill.exe がある。見えると本物の変換サーバーを
# 落としうるので、要るコマンドだけを symlink で並べた PATH で流す (bootstrap-windows-herdr.test.sh
# と同じ作り)。偽のコマンドの shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。
#
# script は、偽の repo (<HOME>/repo/nix/scripts/) に写してから流す。script は自分の場所から
# repo の win/google-japanese-input/ を探すため。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-google-ime.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-google-ime-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

txtpb='session_keymap: CUSTOM
punctuation_method: TOUTEN_KUTEN
'
keymap=$'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\nPrecomposition\tF13\tIMEOff\n'
keymap2=$'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\nPrecomposition\tF13\tIMEOff\nComposition\tF13\tIMEOff\n'
dict=$'てすと\tテスト\t名詞\t\n'

# 要るコマンドだけを並べた PATH (tasklist.exe と taskkill.exe は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head tail mkdir mktemp mv rm cp dirname basename chmod date sort find diff timeout pjp-google-ime; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 1 ケースぶんの HOME を作る。
#   $1: 名前、$2: windows-files.json の中身 (空なら作らない。@WIN@ は配り先に置き換える)
#   $3: 1 なら Google 日本語入力が入っている (ディレクトリがある) 状態にする
# 配り先 (Windows のホームに見立てる) は <HOME>/win。repo は <HOME>/repo、dotfiles-private は <HOME>/private。
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win" "${h}/repo/nix/scripts" \
    "${h}/repo/win/google-japanese-input" "${h}/private/.git" "${h}/private/google-japanese-input/dictionaries"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/AppData/LocalLow/Google/Google Japanese Input"
  fi
  cp "${script}" "${h}/repo/nix/scripts/bootstrap-windows-google-ime.sh"
  printf '%s' "${txtpb}" >"${h}/repo/win/google-japanese-input/config.txtpb"
  printf '%s' "${keymap}" >"${h}/repo/win/google-japanese-input/keymap.tsv"
  printf '%s' "${dict}" >"${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv"
  # 偽の tasklist.exe。FAKE_TOOL_RUNNING があれば設定画面が開いている行を、無ければ (日本語の) 見つからない行を出す
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/tasklist-calls"
if [[ -n ${FAKE_TOOL_RUNNING-} ]]; then
  printf '"GoogleIMEJaTool.exe","4242","Console","3","25,000 K"\r\n'
else
  printf '情報: 指定された条件に一致するタスクは実行されていません。\r\n'
fi
exit "${FAKE_TASKLIST_RC:-0}"
EOF
  } >"${h}/bin/tasklist.exe"
  # 偽の taskkill.exe。引数を記録し、FAKE_TASKKILL_RC で終わる
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/taskkill-calls"
exit "${FAKE_TASKKILL_RC:-0}"
EOF
  } >"${h}/bin/taskkill.exe"
  chmod +x "${h}/bin/tasklist.exe" "${h}/bin/taskkill.exe"
  echo "${h}"
}

# $1: HOME、$2: 1 なら tasklist.exe / taskkill.exe を PATH に置かない、残り: script の引数
run() {
  local h=$1 nointerop=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${nointerop} == 1 ]]; then
    path="${sys_bin}"
  fi
  env HOME="${h}" PATH="${path}" DOTFILES_PRIVATE_DIR="${h}/private" \
    "${BASH}" "${h}/repo/nix/scripts/bootstrap-windows-google-ime.sh" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
ime() { echo "$1/win/AppData/LocalLow/Google/Google Japanese Input"; }
killed() { [[ -s $1/taskkill-calls ]]; }
nkills() { grep -c '' "$1/taskkill-calls" 2>/dev/null || echo 0; }
digest() { pjp-google-ime digest --kind "$1" "$2"; }

# 偽の repo のテキストから組み立てたものを、Windows 側に「画面で作った」ものとして置く。$1: HOME、$2: keymap
put_windows() {
  local d="${work}/gui-$$-${RANDOM}"
  mkdir -p "${d}/conf"
  printf '%s' "${txtpb}" >"${d}/conf/config.txtpb"
  printf '%s' "$2" >"${d}/conf/keymap.tsv"
  pjp-google-ime build --config-dir "${d}/conf" --out "${d}/out" >/dev/null
  cp "${d}/out/config1.db" "$(ime "$1")/config1.db"
}

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-google-ime.sh: ${script}"

# 1. 状態ファイルが無い: 飛ばす
h=$(new_home t1 "" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && ! killed "${h}" && outerr "${h}" | grep -q '飛ばします' && [[ ! -e $(ime "${h}")/config1.db ]]; then
  ok "windows-files.json が無ければ飛ばす"
else
  ng "状態ファイルが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. enable = false: 飛ばす
h=$(new_home t2 "${state_off}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '配りません' && [[ ! -e $(ime "${h}")/config1.db ]]; then
  ok "enable = false なら飛ばす"
else
  ng "enable = false" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. Google 日本語入力が入っていない: 飛ばす
h=$(new_home t3 "${state_on}" 0)
run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '入っていません' && [[ ! -e ${h}/tasklist-calls ]]; then
  ok "Google 日本語入力が入っていなければ飛ばす"
else
  ng "入っていない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. interop が無い (tasklist.exe が見つからない): 置かずに exit 0
h=$(new_home t4 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '置きません' && [[ ! -e $(ime "${h}")/config1.db ]]; then
  ok "interop が無ければ置かずに exit 0"
else
  ng "interop が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. tasklist.exe が失敗する: 置かずに exit 0
h=$(new_home t5 "${state_on}" 1)
FAKE_TASKLIST_RC=126 run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '置きません' && [[ ! -e $(ime "${h}")/config1.db ]]; then
  ok "tasklist.exe が失敗したら置かずに exit 0"
else
  ng "tasklist.exe が失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. 設定画面が開いている: exit 1、何も置かない
h=$(new_home t6 "${state_on}" 1)
FAKE_TOOL_RUNNING=1 run "${h}" 0
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'GoogleIMEJaTool.exe' && [[ ! -e $(ime "${h}")/config1.db ]] && ! killed "${h}"; then
  ok "設定画面が開いていれば exit 1 で何も置かない"
else
  ng "設定画面が開いている" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. 壊れたテキスト: exit 1、行番号を出し、何も置かない
h=$(new_home t7 "${state_on}" 1)
printf '%s' "${keymap}"$'Composition\tF13\n' >"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 0
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'keymap.tsv:4:' && [[ ! -e $(ime "${h}")/config1.db ]] && ! killed "${h}"; then
  ok "壊れたテキストは行番号を出して exit 1 (何も置かない)"
else
  ng "壊れたテキスト" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 8. 初めて置く: 2 つとも置き、記録し、taskkill.exe /F で 1 回だけ落とす
h=$(new_home t8 "${state_on}" 1)
run "${h}" 0
rec="${h}/.local/state/dotfiles/google-japanese-input/deployed.json"
if [[ $(rc "${h}") == 0 && -f "$(ime "${h}")/config1.db" && -f "$(ime "${h}")/user_dictionary.db" && $(nkills "${h}") == 1 ]] \
  && grep -qF '/F /IM GoogleIMEJaConverter.exe' "${h}/taskkill-calls" \
  && [[ $(jq -r '."config1.db"' "${rec}") == "$(digest config "$(ime "${h}")/config1.db")" ]]; then
  ok "初めては 2 つとも置いて記録し、変換サーバーを 1 回落とす"
else
  ng "初めて置く" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 9. 2 回目: 同じなので何もしない (落とさない)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(nkills "${h}") == 1 ]] && outerr "${h}" | grep -q '同じです'; then
  ok "2 回目は同じなので何もせず、落とさない"
else
  ng "2 回目" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 10. 画面で OK を押しただけ (general_config だけが入った): 同じ扱い
printf '\x0a\x02\x18\x01' >>"$(ime "${h}")/config1.db"
before=$(cat "$(ime "${h}")/config1.db" | od -An -tx1 | tr -d ' \n')
run "${h}" 0
after=$(cat "$(ime "${h}")/config1.db" | od -An -tx1 | tr -d ' \n')
if [[ $(rc "${h}") == 0 && $(nkills "${h}") == 1 && ${before} == "${after}" ]] && outerr "${h}" | grep -q '同じです: .*config1.db'; then
  ok "時刻だけが違う (画面で保存しただけ) なら同じ扱いで、Windows 側のファイルに触らない"
else
  ng "時刻だけ違う" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 11. repo 側が進んだ: 退避してから上書きし、落とす
printf '%s' "${keymap2}" >"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 0
backups=$(find "${h}/.local/state/dotfiles/google-japanese-input/backup" -name config1.db | grep -c '')
if [[ $(rc "${h}") == 0 && $(nkills "${h}") == 2 && ${backups} == 1 ]] && outerr "${h}" | grep -q 'repo 側が進んだ' \
  && pjp-google-ime decode --kind config "$(ime "${h}")/config1.db" --out "${h}/dec" && grep -q '^Composition' "${h}/dec/keymap.tsv"; then
  ok "repo 側が進んだら退避して上書きし、変換サーバーを落とす"
else
  ng "repo 側が進んだ" "rc=$(rc "${h}") kills=$(nkills "${h}") backups=${backups} $(outerr "${h}")"
fi

# 12. 画面で変えた (記録とも組み立てたものとも違う): 衝突。diff を出して exit 1、触らない
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
before=$(digest config "$(ime "${h}")/config1.db")
run "${h}" 0
if [[ $(rc "${h}") == 1 && $(digest config "$(ime "${h}")/config1.db") == "${before}" && $(nkills "${h}") == 2 ]] \
  && outerr "${h}" | grep -q '衝突' && outerr "${h}" | grep -q '^--- Windows 側/keymap.tsv' \
  && outerr "${h}" | grep -q '^+Precomposition' && outerr "${h}" | grep -qF -- '--import' && outerr "${h}" | grep -qF -- '--force'; then
  ok "画面で変えていたら衝突として diff (- が Windows 側) と解き方を出し、触らずに exit 1"
else
  ng "衝突" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 13. --dry-run: 判定だけ (書かない・落とさない・tasklist.exe も呼ばない)
rm -f "${h}/tasklist-calls"
run "${h}" 0 --dry-run
if [[ $(rc "${h}") == 1 && $(digest config "$(ime "${h}")/config1.db") == "${before}" && $(nkills "${h}") == 2 && ! -e ${h}/tasklist-calls ]]; then
  ok "--dry-run は判定だけで、書かず、落とさず、衝突なら exit 1"
else
  ng "--dry-run" "rc=$(rc "${h}") kills=$(nkills "${h}") $(outerr "${h}")"
fi

# 14. --import: Windows 側をテキストへ取り込み、記録を合わせる。次は同じ
run "${h}" 0 --import
imported_rc=$(rc "${h}")
run "${h}" 0
if [[ ${imported_rc} == 0 && $(rc "${h}") == 0 && $(nkills "${h}") == 2 ]] \
  && ! grep -q '^Precomposition' "${h}/repo/win/google-japanese-input/keymap.tsv" && outerr "${h}" | grep -q '同じです: .*config1.db'; then
  ok "--import は Windows 側をテキストへ取り込み、次の実行は同じになる"
else
  ng "--import" "import_rc=${imported_rc} rc=$(rc "${h}") $(outerr "${h}")"
fi

# 15. --force: 衝突でも置き直す
h=$(new_home t15 "${state_on}" 1)
put_windows "${h}" $'status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n'
run "${h}" 0 --force
if [[ $(rc "${h}") == 0 && $(nkills "${h}") == 1 ]] && outerr "${h}" | grep -q '上書き (--force)' \
  && pjp-google-ime decode --kind config "$(ime "${h}")/config1.db" --out "${h}/dec" && grep -q '^Precomposition' "${h}/dec/keymap.tsv"; then
  ok "--force は衝突でも repo の中身で置き直す"
else
  ng "--force" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 16. 読めない (壊れた) Windows 側のファイル: 衝突として扱い、traceback を出さない
h=$(new_home t16 "${state_on}" 1)
printf '\xff\xff\xff' >"$(ime "${h}")/config1.db"
run "${h}" 0
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q '衝突' && ! outerr "${h}" | grep -q 'Traceback'; then
  ok "読めない Windows 側のファイルは衝突として扱う (traceback を出さない)"
else
  ng "読めないファイル" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 17. 辞書のテキストが無い: 設定だけ置き、Windows 側の辞書は残す
h=$(new_home t17 "${state_on}" 1)
rm -rf "${h}/private/google-japanese-input"
printf 'windows-dictionary' >"$(ime "${h}")/user_dictionary.db"
run "${h}" 0
if [[ $(rc "${h}") == 0 && -f "$(ime "${h}")/config1.db" && $(cat "$(ime "${h}")/user_dictionary.db") == windows-dictionary ]] \
  && outerr "${h}" | grep -q '辞書は飛ばします'; then
  ok "辞書のテキストが無ければ辞書は飛ばし、Windows 側の辞書を残す"
else
  ng "辞書のテキストが無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 18. 退避は新しい方から 10 回分だけ残す
h=$(new_home t18 "${state_on}" 1)
run "${h}" 0
for i in $(seq 1 11); do
  mkdir -p "${h}/.local/state/dotfiles/google-japanese-input/backup/20000101T0000$(printf '%02d' "${i}")Z-1"
done
printf '%s' "${keymap2}" >"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 0
n=$(find "${h}/.local/state/dotfiles/google-japanese-input/backup" -mindepth 1 -maxdepth 1 -type d | grep -c '')
oldest=$(find "${h}/.local/state/dotfiles/google-japanese-input/backup" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
if [[ $(rc "${h}") == 0 && ${n} == 10 && ${oldest} == *20000101T000003Z-1 ]]; then
  ok "退避は新しい方から 10 回分だけ残す"
else
  ng "退避の間引き" "rc=$(rc "${h}") n=${n} oldest=${oldest} $(outerr "${h}")"
fi

# 19. 変換サーバーが動いていない (taskkill.exe が 128): 成功扱い
h=$(new_home t19 "${state_on}" 1)
FAKE_TASKKILL_RC=128 run "${h}" 0
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '動いていませんでした'; then
  ok "変換サーバーが動いていなければ (128) 成功扱い"
else
  ng "128" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 20. taskkill.exe がほかの理由で失敗: exit 1 で、手で終了する方法を出す
h=$(new_home t20 "${state_on}" 1)
FAKE_TASKKILL_RC=1 run "${h}" 0
if [[ $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'タスクマネージャー'; then
  ok "変換サーバーを落とせなければ exit 1 で、手で終了する方法を出す"
else
  ng "taskkill 失敗" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 21. --check: state も Windows も無くても、テキストだけ確かめる
h=$(new_home t21 "" 0)
run "${h}" 1 --check
check_ok=$(rc "${h}")
printf '%s' $'status\tkey\tcommand\nDirect input\tF13\tIMEOn\n' >"${h}/repo/win/google-japanese-input/keymap.tsv"
run "${h}" 1 --check
if [[ ${check_ok} == 0 && $(rc "${h}") == 1 ]] && outerr "${h}" | grep -q 'keymap.tsv:2:'; then
  ok "--check は state も Windows も無しでテキストを確かめる"
else
  ng "--check" "ok_rc=${check_ok} rc=$(rc "${h}") $(outerr "${h}")"
fi

# 22. 知らない引数: exit 2
h=$(new_home t22 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 ]] && ! killed "${h}"; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
```

- [ ] **Step 2: `nix/flake.nix` の checks (Task 1 で足した `pjp-google-ime-unittest` の次) に足す**

```nix
          bootstrap-windows-google-ime-test =
            pkgs.runCommand "bootstrap-windows-google-ime-test"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  googleIme
                ];
              }
              ''
                bash ${./tests/bootstrap-windows-google-ime.test.sh} ${./scripts/bootstrap-windows-google-ime.sh}
                touch $out
              '';
```

- [ ] **Step 3: テストが落ちることを確かめる (script がまだ無い)**

Run: `git add -N nix/tests && nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-google-ime-test' 2>&1 | tail -3`
Expected: FAIL (`./scripts/bootstrap-windows-google-ime.sh` が無いので評価で止まる)。

- [ ] **Step 4: script を書く `nix/scripts/bootstrap-windows-google-ime.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の Google 日本語入力の設定とユーザー辞書を、repo のテキストから組み立てて配る。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 98
#
# ^ setup.sh が読む実行順。衝突や「設定画面が開いている」で exit 1 しても、ほかの bootstrap を
#   止めないよう最後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Google 日本語入力の設定 (config1.db) と辞書 (user_dictionary.db) は protobuf のバイナリで、
# 保存のたびに時刻が入る。repo にはテキストだけを置き、setup のたびに組み立てて配る
# (docs/adr/015_win_google_ime_powertoys_*)。
#
# ## 何を読むか
#
# - ~/.local/state/dotfiles/windows-files.json (home-manager が置く。ADR 010)。配り先と on / off
# - この script がいる checkout の win/google-japanese-input/ (config.txtpb・keymap.tsv・romaji.tsv)
# - pollenjp/dotfiles-private の clone の google-japanese-input/dictionaries/ (無ければ辞書は飛ばす)。
#   clone の場所は bootstrap-dotfiles-private.sh と同じ決め方 ($DOTFILES_PRIVATE_DIR →
#   $(ghq root)/github.com/pollenjp/dotfiles-private → ~/ghq/github.com/pollenjp/dotfiles-private)
#
# ## 何をするか
#
# 1. 前提を確かめる。配らないマシン・Google 日本語入力が入っていないマシンは exit 0 で飛ばす。
#    interop (tasklist.exe) が使えなければ置かずに exit 0 (変換サーバーを再起動できず、置いたものが
#    古い設定で上書きされうるため)。設定画面・辞書ツール (GoogleIMEJaTool.exe) が開いていれば exit 1
# 2. pjp-google-ime build で組み立てる。テキストが壊れていれば何も書かずに exit 1
# 3. ファイルごとに、時刻などを外した中身 (pjp-google-ime digest) を比べる:
#
#      Windows 側に無い                              置く
#      組み立てたものと同じ                          何もしない (記録だけ合わせる)
#      前回置いたときの記録と同じ (repo 側が進んだ)  退避してから置く
#      それ以外 (画面で変えた・記録が無い)           衝突。テキストの diff を出して触らない
#
# 4. 置いたものがあれば、taskkill.exe /F で変換サーバー (GoogleIMEJaConverter.exe) を落とす。
#    次のキー入力で Google 日本語入力が起動し直し、置いた設定を読む
#
# 衝突が 1 件でもあれば、全部を処理し終えてから exit 1 する。--import で Windows 側を
# テキストへ取り込むか、--force で repo の中身で置き直す。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の Google 日本語入力の設定とユーザー辞書を、repo のテキストから組み立てて配る。

使い方:
  bootstrap-windows-google-ime.sh            配る
  bootstrap-windows-google-ime.sh --dry-run  判定だけ出して何も書かない
  bootstrap-windows-google-ime.sh --force    衝突 (画面で変えていた) でも repo の中身で置き直す
  bootstrap-windows-google-ime.sh --import   Windows 側の今の中身を repo のテキストへ取り込む
  bootstrap-windows-google-ime.sh --check    テキストの検証だけ (CI 用。state も Windows も要らない)
EOS
}

force=0
dry_run=0
do_import=0
check_only=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    --import) do_import=1 ;;
    --check) check_only=1 ;;
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

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")
config_dir="${repo_dir}/win/google-japanese-input"
state_file="${HOME}/.local/state/dotfiles/windows-files.json"
state_dir="${HOME}/.local/state/dotfiles/google-japanese-input"
record_file="${state_dir}/deployed.json"
tool=pjp-google-ime
keep_backups=10

# dotfiles-private の clone の場所 (bootstrap-dotfiles-private.sh と同じ決め方)
private_dir() {
  local root
  if [[ -n ${DOTFILES_PRIVATE_DIR:-} ]]; then
    printf '%s' "${DOTFILES_PRIVATE_DIR%/}"
  elif root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/github.com/pollenjp/dotfiles-private' "${root}"
  else
    printf '%s/ghq/github.com/pollenjp/dotfiles-private' "${HOME}"
  fi
}

need_tool() {
  if ! command -v "${tool}" &>/dev/null; then
    echo "${tool} が見つかりません。先に home-manager switch を実行してください。" >&2
    exit 1
  fi
}

if [[ ! -f ${config_dir}/config.txtpb ]]; then
  echo "${config_dir}/config.txtpb がありません (この checkout は Google 日本語入力の設定を持っていない)。この手順は飛ばします。"
  exit 0
fi

dict_dir="$(private_dir)/google-japanese-input/dictionaries"

if ((check_only)); then
  need_tool
  args=(check --config-dir "${config_dir}")
  if [[ -d ${dict_dir} ]]; then
    args+=(--dictionary-dir "${dict_dir}")
  fi
  "${tool}" "${args[@]}"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi
if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  echo "Windows 側のホームが見えません: ${windows_home:-(windowsHome が空)}" >&2
  exit 1
fi
ime_dir="${windows_home}/AppData/LocalLow/Google/Google Japanese Input"
if [[ ! -d ${ime_dir} ]]; then
  echo "Google 日本語入力が入っていません (${ime_dir} が無い)。この手順は飛ばします。"
  exit 0
fi
need_tool

if [[ ! -d ${dict_dir} ]]; then
  if [[ -d $(private_dir)/.git ]] && ((do_import)); then
    mkdir -p "${dict_dir}"
  else
    echo "!! 辞書のテキスト (${dict_dir}) が無いので、辞書は飛ばします (dotfiles-private を取れていないかも)。" >&2
    dict_dir=""
  fi
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-google-ime.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

if [[ -e ${record_file} ]]; then
  if ! records=$(jq -c 'if type == "object" then . else error("not an object") end' "${record_file}" 2>/dev/null); then
    echo "!! ${record_file} が壊れています (JSON の object ではない)。消してから流し直すと衝突として扱われます。" >&2
    exit 1
  fi
else
  records='{}'
fi

remember() {
  records=$(jq -c --arg k "$1" --arg v "$2" '.[$k] = $v' <<<"${records}")
}

write_records() {
  mkdir -p "${state_dir}"
  local t
  t=$(mktemp "${record_file}.XXXXXX")
  jq -S . <<<"${records}" >"${t}"
  mv -f -- "${t}" "${record_file}"
}

# 1 ファイルの kind (pjp-google-ime の --kind) を返す
kind_of() {
  case $1 in
    config1.db) echo config ;;
    user_dictionary.db) echo dictionary ;;
  esac
}

files=(config1.db)
if [[ -n ${dict_dir} ]]; then
  files+=(user_dictionary.db)
fi

if ((do_import)); then
  args=(import --windows-dir "${ime_dir}" --config-dir "${config_dir}")
  if [[ -n ${dict_dir} ]]; then
    args+=(--dictionary-dir "${dict_dir}")
  fi
  "${tool}" "${args[@]}"
  for f in "${files[@]}"; do
    if [[ -f ${ime_dir}/${f} ]]; then
      remember "${f}" "$("${tool}" digest --kind "$(kind_of "${f}")" "${ime_dir}/${f}")"
    fi
  done
  write_records
  echo "取り込みました。git diff を見て、dotfiles と dotfiles-private の両方で commit してください。"
  exit 0
fi

# 設定画面・辞書ツールが開いていたら止まる。interop が使えなければ置かない (exit 0)
if ((! dry_run)); then
  if ! listing=$(timeout 30 tasklist.exe /FI "IMAGENAME eq GoogleIMEJaTool.exe" /FO CSV /NH </dev/null 2>&1); then
    echo "!! tasklist.exe を呼べませんでした (WSL の interop が落ちているかもしれません)。Google 日本語入力の設定は置きません。" >&2
    echo "   変換サーバーを再起動できないと、置いた設定が古い設定で上書きされうるためです。" >&2
    echo "   interop が戻ったら ${script_dir}/bootstrap-windows-google-ime.sh を流してください。" >&2
    exit 0
  fi
  if grep -qi '"GoogleIMEJaTool.exe"' <<<"${listing}"; then
    echo "!! Google 日本語入力の設定画面か辞書ツール (GoogleIMEJaTool.exe) が開いています。閉じてから流し直してください。" >&2
    echo "   開いたまま置くと、閉じるときに古い中身で書き戻されることがあります。" >&2
    exit 1
  fi
fi

build_args=(build --config-dir "${config_dir}" --out "${tmp}/built")
if [[ -n ${dict_dir} ]]; then
  build_args+=(--dictionary-dir "${dict_dir}")
fi
if ! "${tool}" "${build_args[@]}"; then
  echo "!! テキストを組み立てられませんでした (上のエラーの行を直してください)。何も置いていません。" >&2
  exit 1
fi

# 衝突の diff。両方をテキストに戻してから比べる (- が Windows 側、+ が repo 側)
show_diff() {
  local kind=$1 have=$2 want=$3 a="${tmp}/diff/windows" b="${tmp}/diff/repo"
  rm -rf "${tmp}/diff"
  mkdir -p "${a}" "${b}"
  if ! "${tool}" decode --kind "${kind}" "${have}" --out "${a}" >/dev/null 2>&1; then
    echo "   (Windows 側のファイルを読めないので diff は出せません)"
    return 0
  fi
  "${tool}" decode --kind "${kind}" "${want}" --out "${b}" >/dev/null
  (cd "${tmp}/diff" && diff -ru windows repo) | sed -e 's#^--- windows/#--- Windows 側/#' -e 's#^+++ repo/#+++ repo/#' || true
}

backup_dir=""
backup() {
  if [[ -z ${backup_dir} ]]; then
    backup_dir="${state_dir}/backup/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "${backup_dir}"
  fi
  cp -p -- "$1" "${backup_dir}/"
}

# 退避は新しい方から ${keep_backups} 回分だけ残す (ディレクトリ名が時刻で始まるので名前の順)
prune_backups() {
  local dirs=()
  if [[ -d ${state_dir}/backup ]]; then
    mapfile -t dirs < <(find "${state_dir}/backup" -mindepth 1 -maxdepth 1 -type d | sort)
  fi
  local n=${#dirs[@]}
  local i
  for ((i = 0; i < n - keep_backups; i++)); do
    rm -rf -- "${dirs[i]}"
  done
}

place() {
  local t
  t=$(mktemp "$2.dotfiles-tmp.XXXXXX")
  cp -- "$1" "${t}"
  chmod 644 "${t}"
  mv -f -- "${t}" "$2"
}

placed=0
conflicts=0
for f in "${files[@]}"; do
  kind=$(kind_of "${f}")
  dst="${ime_dir}/${f}"
  want=$("${tool}" digest --kind "${kind}" "${tmp}/built/${f}")
  recorded=$(jq -r --arg k "${f}" '.[$k] // ""' <<<"${records}")
  if [[ ! -e ${dst} ]]; then
    action=copy
  elif ! have=$("${tool}" digest --kind "${kind}" "${dst}" 2>/dev/null); then
    # 読めない (壊れている) ものは、記録と比べられないので衝突として扱う
    if ((force)); then
      action=force
    else
      action=conflict
    fi
  elif [[ ${have} == "${want}" ]]; then
    action=same
  elif [[ -n ${recorded} && ${have} == "${recorded}" ]]; then
    action=update
  elif ((force)); then
    action=force
  else
    action=conflict
  fi

  case ${action} in
    same)
      echo "同じです: ${dst}"
      if [[ ${recorded} != "${want}" ]] && ((! dry_run)); then
        remember "${f}" "${want}"
      fi
      ;;
    conflict)
      conflicts=$((conflicts + 1))
      {
        echo "!! 衝突: ${dst} は Windows 側で変わっています (画面で変えたか、前回置いた記録が無い)。"
        show_diff "${kind}" "${dst}" "${tmp}/built/${f}"
        echo "   Windows 側の変更を残すなら: ${script_dir}/bootstrap-windows-google-ime.sh --import"
        echo "   repo 側で上書きするなら:   ${script_dir}/bootstrap-windows-google-ime.sh --force"
      } >&2
      ;;
    copy | update | force)
      case ${action} in
        copy) label="置く" ;;
        update) label="上書き (repo 側が進んだ)" ;;
        force) label="上書き (--force)" ;;
      esac
      if ((dry_run)); then
        echo "[dry-run] ${label}: ${dst}"
      else
        if [[ -e ${dst} ]]; then
          backup "${dst}"
        fi
        place "${tmp}/built/${f}" "${dst}"
        remember "${f}" "${want}"
        placed=$((placed + 1))
        echo "${label}: ${dst}"
      fi
      ;;
  esac
done

if ((! dry_run)); then
  write_records
  prune_backups
fi
if [[ -n ${backup_dir} ]]; then
  echo "置き換える前のファイルは ${backup_dir} に退避しました。"
fi

if ((placed > 0)); then
  # 置いてから落とす。次のキー入力で Google 日本語入力が変換サーバーを起動し直し、置いた設定を読む。
  # 128 は「動いていない」(誰も古い設定を持っていないので、そのままでよい)
  rc=0
  out=$(timeout 30 taskkill.exe /F /IM GoogleIMEJaConverter.exe </dev/null 2>&1) || rc=$?
  if ((rc == 0)); then
    echo "変換サーバー (GoogleIMEJaConverter.exe) を落としました。次のキー入力で起動し直し、置いた設定を読みます。"
    echo "直接入力モードのキー (F13 → IMEOn など) を変えたときは、アプリを起動し直すと効きます。"
  elif ((rc == 128)); then
    echo "変換サーバーは動いていませんでした。次に起動したときに置いた設定を読みます。"
  else
    {
      echo "!! 変換サーバーを落とせませんでした (taskkill.exe の終了コード ${rc}):"
      printf '%s\n' "${out}" | tr -d '\r' | sed 's/^/   /'
      echo "   設定画面を開く前に、タスクマネージャーで GoogleIMEJaConverter.exe を終了するか、サインアウトしてください。"
    } >&2
    exit 1
  fi
fi

if ((conflicts > 0)); then
  exit 1
fi
```

Run: `chmod +x nix/scripts/bootstrap-windows-google-ime.sh`

- [ ] **Step 5: テストが通ることを確かめる**

Run: `git add -N nix/scripts && nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-google-ime-test' 2>&1 | grep -E 'passed|FAIL' | tail -5`
Expected: `== 22 passed, 0 failed`。

- [ ] **Step 6: shfmt / shellcheck / nixfmt を通す**

Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh && shellcheck nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh && nixfmt --check nix/flake.nix && echo LINT-OK'`
Expected: `LINT-OK`。

- [ ] **Step 7: Windows に触らずに判定だけ見る**

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh --dry-run`
Expected: `同じです: …/config1.db` (Task 2 で今の設定を取り込んだので、組み立てたものと Windows 側が同じ)。辞書は「辞書は飛ばします」(dotfiles-private がまだ無い)。終了コード 0。`--dry-run` は tasklist.exe も taskkill.exe も呼ばない。

- [ ] **Step 8: Commit**

```bash
git add nix/scripts/bootstrap-windows-google-ime.sh nix/tests/bootstrap-windows-google-ime.test.sh nix/flake.nix
git commit -F - <<'EOF'
feat(nix): Google 日本語入力の設定をテキストから組み立てて配る bootstrap-windows-google-ime.sh を足す (TKT-139)

時刻などを外した中身で比べ、置くときは退避してから一時ファイル経由で置き、置いたら
taskkill.exe /F で変換サーバーを落として読み直させる。設定画面が開いていれば止まり、
interop が無ければ置かない。--dry-run / --force / --import / --check。ADR 015 の C と D。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 4: private な辞書の置き場所を取る `bootstrap-dotfiles-private.sh` を足す

**Files:**
- Create: `nix/tests/bootstrap-dotfiles-private.test.sh`
- Create: `nix/scripts/bootstrap-dotfiles-private.sh` (実行ビットを付ける)
- Modify: `nix/flake.nix` (checks に `bootstrap-dotfiles-private-test`)

**Interfaces:**
- Consumes: なし (`git` と、あれば `ghq`)
- Produces: `nix/scripts/bootstrap-dotfiles-private.sh` (引数なし)。clone の場所の決め方は Task 3 の `private_dir()` と同じ

- [ ] **Step 1: テストを書く `nix/tests/bootstrap-dotfiles-private.test.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-dotfiles-private.sh の振る舞いを、使い捨ての HOME と手元の bare repo で確かめる。
#
#   bash nix/tests/bootstrap-dotfiles-private.test.sh [<script のパス>]
#
# flake の checks (bootstrap-dotfiles-private-test) が Nix のサンドボックスで流す。
# 使うのは bash・git・coreutils・grep だけ。GitHub には出ない (DOTFILES_PRIVATE_URL を file:// に向ける)。
#
# ## 確かめること
#
#   - 無ければ clone し、あれば pull --ff-only する
#   - 未コミットの変更があれば pull を飛ばす。git の repo でないものがあれば触らない
#   - clone できなくても exit 0 (警告だけ)。知らない引数は exit 2

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-dotfiles-private.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-dotfiles-private-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# 手元の「GitHub」: bare repo と、そこへ commit を足すための作業用の clone
bare="${work}/remote.git"
git init --quiet --bare "${bare}"
git -C "${bare}" symbolic-ref HEAD refs/heads/main
git clone --quiet "${bare}" "${work}/author" 2>/dev/null
mkdir -p "${work}/author/google-japanese-input/dictionaries"
printf 'てすと\tテスト\t名詞\t\n' >"${work}/author/google-japanese-input/dictionaries/テスト辞書.tsv"
git -C "${work}/author" add -A
git -C "${work}/author" commit --quiet -m first
git -C "${work}/author" push --quiet origin HEAD:main

# $1: HOME、残り: script の引数。clone 先は <HOME>/private、取りに行く先は bare repo
run() {
  local h=$1
  shift
  mkdir -p "${h}"
  env HOME="${h}" DOTFILES_PRIVATE_DIR="${h}/private" DOTFILES_PRIVATE_URL="${DOTFILES_PRIVATE_URL_OVERRIDE:-file://${bare}}" \
    "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }

echo "== bootstrap-dotfiles-private.sh: ${script}"

# 1. 無ければ clone する
h="${work}/t1"
run "${h}"
if [[ $(rc "${h}") == 0 && -f ${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv ]] && outerr "${h}" | grep -q 'clone しました'; then
  ok "無ければ clone する"
else
  ng "clone" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. あれば pull --ff-only する
printf 'あ\t亜\t名詞\t\n' >>"${work}/author/google-japanese-input/dictionaries/テスト辞書.tsv"
git -C "${work}/author" commit --quiet -am second
git -C "${work}/author" push --quiet origin HEAD:main
run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -q '^あ' "${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv" && outerr "${h}" | grep -q '更新しました'; then
  ok "あれば pull --ff-only で追いつく"
else
  ng "pull" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. 未コミットの変更があれば pull を飛ばす (変更は残す)
printf 'い\t伊\t名詞\t\n' >>"${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '未コミットの変更' && grep -q '^い' "${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv"; then
  ok "未コミットの変更があれば pull を飛ばし、変更を残す"
else
  ng "未コミット" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. git の repo でないものがあれば触らない
h="${work}/t4"
mkdir -p "${h}/private"
printf 'keep\n' >"${h}/private/file"
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${h}/private/file") == keep ]] && outerr "${h}" | grep -q 'git の repo ではありません'; then
  ok "git の repo でないものがあれば触らずに exit 0"
else
  ng "repo でない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. clone できない: 警告して exit 0 (何も作らない)
h="${work}/t5"
DOTFILES_PRIVATE_URL_OVERRIDE="file://${work}/no-such.git" run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/private ]] && outerr "${h}" | grep -q 'clone に失敗しました'; then
  ok "clone できなくても exit 0 (警告だけ)"
else
  ng "clone できない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 6. 知らない引数: exit 2
h="${work}/t6"
run "${h}" --bogus
if [[ $(rc "${h}") == 2 && ! -e ${h}/private ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
```

- [ ] **Step 2: `nix/flake.nix` の checks (`bootstrap-windows-google-ime-test` の次) に足す**

```nix
          bootstrap-dotfiles-private-test = scriptTest "bootstrap-dotfiles-private" ./scripts/bootstrap-dotfiles-private.sh;
```

- [ ] **Step 3: テストが落ちることを確かめる**

Run: `git add -N nix/tests && nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-dotfiles-private-test' 2>&1 | tail -3`
Expected: FAIL (script がまだ無い)。

- [ ] **Step 4: script を書く `nix/scripts/bootstrap-dotfiles-private.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# private な dotfiles-private (pollenjp/dotfiles-private) を取得する (冪等。更新時も毎回走る。取れなくても止めない)。
#
# order: 50
#
# ^ setup.sh が読む実行順 (既定と同じ)。中身を読む bootstrap-windows-google-ime.sh (order: 98) より
#   先に走ればよい。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# 公開したくない設定 (今は Google 日本語入力のユーザー辞書) を、public なこの repo と分けて
# private repo に置く (docs/adr/015_win_google_ime_powertoys_*)。flake input や submodule に
# しないのは、public な repo に private repo の rev を残さず、辞書を変えるたびにこの repo で
# 指す先を進める commit を要らなくするため。
#
# ## 何をするか
#
# clone の場所は上から順に決める (bootstrap-windows-google-ime.sh も同じ決め方で読む):
#
#   1. $DOTFILES_PRIVATE_DIR
#   2. $(ghq root)/github.com/pollenjp/dotfiles-private
#   3. ~/ghq/github.com/pollenjp/dotfiles-private
#
# 無ければ clone し、あれば pull --ff-only する (未コミットの変更があるとき・upstream が無いときは
# pull を飛ばす)。取れない (SSH 鍵が無い・オフライン) ときは警告して exit 0 にする
# (bootstrap-claude-skills.sh と同じ扱い。setup は手順が 1 つ失敗すると残りを走らせないため)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
private な dotfiles-private (pollenjp/dotfiles-private) を取得する。

使い方:
  bootstrap-dotfiles-private.sh   無ければ clone し、あれば pull --ff-only する

clone の場所: $DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
              ~/ghq/github.com/pollenjp/dotfiles-private
取れなくてもエラーにはせず、警告を出して exit 0 する。
EOS
}

for arg in "$@"; do
  case ${arg} in
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

# 鍵が無い / known_hosts に github.com が無いマシンで、git や ssh が対話プロンプトで固まらないように
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

repo_url=${DOTFILES_PRIVATE_URL:-git@github.com:pollenjp/dotfiles-private.git}

resolve_dir() {
  local root
  if [[ -n ${DOTFILES_PRIVATE_DIR:-} ]]; then
    printf '%s' "${DOTFILES_PRIVATE_DIR%/}"
  elif root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/github.com/pollenjp/dotfiles-private' "${root}"
  else
    printf '%s/ghq/github.com/pollenjp/dotfiles-private' "${HOME}"
  fi
}
dir=$(resolve_dir)

warn() {
  printf '!! %s\n' "$*" >&2
}

if ! command -v git &>/dev/null; then
  warn "git が見つかりません。dotfiles-private の取得を飛ばします。"
  exit 0
fi

if [[ -d ${dir}/.git ]]; then
  if [[ -n $(git -C "${dir}" status --porcelain) ]]; then
    warn "未コミットの変更があるので pull を飛ばします: ${dir}"
    exit 0
  fi
  if ! git -C "${dir}" rev-parse --abbrev-ref '@{upstream}' &>/dev/null; then
    warn "upstream が無いブランチなので pull を飛ばします: ${dir}"
    exit 0
  fi
  if ! git -C "${dir}" pull --ff-only --quiet; then
    warn "pull に失敗しました。手元の clone のまま続けます: ${dir}"
    exit 0
  fi
  echo "dotfiles-private を更新しました: ${dir}"
  exit 0
fi

if [[ -e ${dir} ]]; then
  warn "${dir} は git の repo ではありません。取得を飛ばします (退けてから流し直してください)。"
  exit 0
fi

mkdir -p "$(dirname -- "${dir}")"
if ! git clone --quiet "${repo_url}" "${dir}"; then
  warn "clone に失敗しました: ${repo_url}"
  printf '   private な repo なので SSH 鍵が要ります。ssh -T git@github.com で疎通を確かめてください。\n' >&2
  printf '   取れないあいだ、Google 日本語入力の辞書は配られません。\n' >&2
  exit 0
fi
echo "dotfiles-private を clone しました: ${dir}"
```

Run: `chmod +x nix/scripts/bootstrap-dotfiles-private.sh`

- [ ] **Step 5: テストが通ることを確かめる**

Run: `git add -N nix/scripts && nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-dotfiles-private-test' 2>&1 | grep -E 'passed|FAIL' | tail -3`
Expected: `== 6 passed, 0 failed`。

- [ ] **Step 6: shfmt / shellcheck / nixfmt を通す**

Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-dotfiles-private.sh nix/tests/bootstrap-dotfiles-private.test.sh && shellcheck nix/scripts/bootstrap-dotfiles-private.sh nix/tests/bootstrap-dotfiles-private.test.sh && nixfmt --check nix/flake.nix && echo LINT-OK'`
Expected: `LINT-OK`。

- [ ] **Step 7: Commit**

```bash
git add nix/scripts/bootstrap-dotfiles-private.sh nix/tests/bootstrap-dotfiles-private.test.sh nix/flake.nix
git commit -F - <<'EOF'
feat(nix): private な pollenjp/dotfiles-private を ghq の下へ取る bootstrap-dotfiles-private.sh を足す (TKT-139)

Google 日本語入力のユーザー辞書を public なこの repo と分けて置くため。無ければ clone、
あれば pull --ff-only し、取れなくても警告だけで exit 0 にする (claude-skills と同じ)。ADR 015 の E。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 5: PowerToys の割り当てを配り、`bootstrap-windows-powertoys.sh` で読み直させる

**Files:**
- Create: `win/powertoys/keyboard-manager/default.json`、`win/powertoys/keyboard-manager/editorSettings.json` (Windows 側からバイト列のまま写す)
- Create: `.gitattributes`
- Modify: `.editorconfig`、`win/manifest.toml`
- Create: `nix/tests/bootstrap-windows-powertoys.test.sh`
- Create: `nix/scripts/bootstrap-windows-powertoys.sh` (実行ビットを付ける)
- Modify: `nix/flake.nix` (checks に `bootstrap-windows-powertoys-test`)

**Interfaces:**
- Consumes: `bootstrap-windows-files.sh` (order 90) が manifest のとおりに置いた `default.json`、`~/.local/state/dotfiles/windows-files.json`
- Produces: `nix/scripts/bootstrap-windows-powertoys.sh [--force]`

- [ ] **Step 1: Windows 側の 2 ファイルをバイト列のまま写す**

```bash
d='/mnt/c/Users/polle/AppData/Local/Microsoft/PowerToys/Keyboard Manager'
mkdir -p win/powertoys/keyboard-manager
cp "${d}/default.json" "${d}/editorSettings.json" win/powertoys/keyboard-manager/
cmp "${d}/default.json" win/powertoys/keyboard-manager/default.json && cmp "${d}/editorSettings.json" win/powertoys/keyboard-manager/editorSettings.json && echo SAME
tail -c 4 win/powertoys/keyboard-manager/default.json | od -An -tx1
```

Expected: `SAME`。`default.json` の末尾は `5b 5d 7d 7d` (`[]}}`、改行なし)。`editorSettings.json` は CRLF で末尾に改行が無い。

- [ ] **Step 2: 改行を変えないよう `.gitattributes` を作り、`.editorconfig` に足す**

`.gitattributes` (新規):

```gitattributes
# PowerToys が書いたバイト列のまま置く (改行を変えない。win/README.md「PowerToys」)
win/powertoys/** -text
```

`.editorconfig` の末尾に足す:

```ini

[win/powertoys/**.json] # PowerToys が書いたバイト列のまま置く (末尾に改行を足さない。win/README.md)
insert_final_newline = false

[win/powertoys/keyboard-manager/editorSettings.json] # 改行は CRLF (PowerToys の新しいエディタが書く形)
end_of_line = crlf
```

Run: `git add .gitattributes win/powertoys && git diff --cached --stat -- win/powertoys && git ls-files --eol win/powertoys`
Expected: `editorSettings.json` の行に `i/crlf` と `attr/-text`、`default.json` に `i/-text` か `i/none` と `attr/-text`。

- [ ] **Step 3: `win/manifest.toml` の末尾に 2 件足す**

```toml

[[files]]
src = "powertoys/keyboard-manager/default.json"
dst = "%LOCALAPPDATA%/Microsoft/PowerToys/Keyboard Manager/default.json"
hint = "続く bootstrap-windows-powertoys.sh が Keyboard Manager に読み直させる (PowerToys が動いていなければ、起動したときに読む)"

[[files]]
src = "powertoys/keyboard-manager/editorSettings.json"
dst = "%LOCALAPPDATA%/Microsoft/PowerToys/Keyboard Manager/editorSettings.json"
hint = "Keyboard Manager のエディタを開いていたら、閉じて開き直す"
```

Run: `nix/scripts/bootstrap-windows-files.sh --check`
Expected: `win/manifest.toml: OK (7 件)`。

- [ ] **Step 4: テストを書く `nix/tests/bootstrap-windows-powertoys.test.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-windows-powertoys.sh の振る舞いを、使い捨ての HOME と偽の powershell.exe で確かめる。
#
#   bash nix/tests/bootstrap-windows-powertoys.test.sh [<script のパス>]
#
# flake の checks (bootstrap-windows-powertoys-test) が Nix のサンドボックスで流す。
# 使うのは bash・jq・coreutils・grep・sed だけ。
#
# ## 確かめること
#
#   - 配らないマシン・default.json が無いときは powershell.exe を呼ばずに飛ばす
#   - 送れたら記録し、同じ default.json では呼ばない。変われば呼ぶ。--force なら変わらなくても呼ぶ
#   - PowerToys が動いていない (absent) ときも記録する。interop が使えない・出力がおかしいときは
#     手で読み直す方法を出し、記録しない。どれも exit 0
#
# 本物の powershell.exe を見せないよう、要るコマンドだけを symlink で並べた PATH で流す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-windows-powertoys.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-powertoys-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in env jq grep sed tr cat head cut mkdir dirname sha256sum timeout; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# $1: 名前、$2: windows-files.json の中身 (空なら作らない)、$3: 1 なら default.json を置く
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.local/state/dotfiles" "${h}/bin" "${h}/win"
  if [[ -n $2 ]]; then
    printf '%s\n' "${2//@WIN@/${h}/win}" >"${h}/.local/state/dotfiles/windows-files.json"
  fi
  if [[ $3 == 1 ]]; then
    mkdir -p "${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager"
    printf '{"remapKeys":{"inProcess":[{"originalKeys":"20","newRemapKeys":"124"}]}}' \
      >"${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
  fi
  # 偽の powershell.exe。引数を記録し、FAKE_PS_OUT (既定 set) を CRLF で出して FAKE_PS_RC で終わる
  {
    printf '#!%s\n' "${BASH}"
    cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/ps-calls"
printf '%s\r\n' "${FAKE_PS_OUT-set}"
exit "${FAKE_PS_RC:-0}"
EOF
  } >"${h}/bin/powershell.exe"
  chmod +x "${h}/bin/powershell.exe"
  echo "${h}"
}

# $1: HOME、$2: 1 なら powershell.exe を PATH に置かない、残り: script の引数
run() {
  local h=$1 nops=$2
  shift 2
  local path="${h}/bin:${sys_bin}"
  if [[ ${nops} == 1 ]]; then
    path="${sys_bin}"
  fi
  env HOME="${h}" PATH="${path}" "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
ncalls() { grep -c '' "$1/ps-calls" 2>/dev/null || echo 0; }
record() { echo "$1/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"; }

state_on='{"enable":true,"version":1,"windowsHome":"@WIN@"}'
state_off='{"enable":false,"version":1,"windowsHome":null}'

echo "== bootstrap-windows-powertoys.sh: ${script}"

# 1. 状態ファイルが無い / enable = false / default.json が無い: 呼ばずに飛ばす
for t in "nostate::1" "off:${state_off}:1" "nojson:${state_on}:0"; do
  name=${t%%:*}
  rest=${t#*:}
  state=${rest%:*}
  json=${rest##*:}
  h=$(new_home "t1-${name}" "${state}" "${json}")
  run "${h}" 0
  if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 0 && ! -e $(record "${h}") ]]; then
    ok "飛ばす (${name}): powershell.exe を呼ばない"
  else
    ng "飛ばす (${name})" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
  fi
done

# 2. 送れた: 記録する。名前付きイベントの名前を渡す
h=$(new_home t2 "${state_on}" 1)
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '読み直させました' \
  && grep -qF 'PowerToys_KeyboardManager_Event_Settings' "${h}/ps-calls" && grep -qF -- '-NoProfile' "${h}/ps-calls"; then
  ok "送れたら記録し、イベントの名前を渡す (CRLF の出力も読める)"
else
  ng "送れた" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 3. 同じ default.json: 呼ばない
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 1 ]] && outerr "${h}" | grep -q '読み直し済み'; then
  ok "同じ default.json なら呼ばない"
else
  ng "同じ default.json" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 4. --force: 同じでも呼ぶ
run "${h}" 0 --force
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 2 ]]; then
  ok "--force なら同じでも呼ぶ"
else
  ng "--force" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 5. default.json が変わった: 呼んで記録を更新する
printf '{"remapKeys":{"inProcess":[]}}' >"${h}/win/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
before=$(cat "$(record "${h}")")
run "${h}" 0
if [[ $(rc "${h}") == 0 && $(ncalls "${h}") == 3 && $(cat "$(record "${h}")") != "${before}" ]]; then
  ok "default.json が変わったら呼んで記録を更新する"
else
  ng "変わった" "rc=$(rc "${h}") calls=$(ncalls "${h}") $(outerr "${h}")"
fi

# 6. PowerToys が動いていない (absent): 記録する
h=$(new_home t6 "${state_on}" 1)
FAKE_PS_OUT=absent run "${h}" 0
if [[ $(rc "${h}") == 0 && -s $(record "${h}") ]] && outerr "${h}" | grep -q '動いていません'; then
  ok "PowerToys が動いていなければ記録する (起動したときに読む)"
else
  ng "absent" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. powershell.exe が無い: 手で読み直す方法を出し、記録しない
h=$(new_home t7 "${state_on}" 1)
run "${h}" 1
if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && outerr "${h}" | grep -q 'オフにしてオンに戻す'; then
  ok "powershell.exe が無ければ手で読み直す方法を出し、記録しない"
else
  ng "powershell.exe が無い" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 8. powershell.exe が失敗する / 知らない出力: 手で読み直す方法を出し、記録しない
for t in "126:" "0:Exec format error"; do
  h=$(new_home "t8-${t%%:*}" "${state_on}" 1)
  FAKE_PS_RC=${t%%:*} FAKE_PS_OUT=${t#*:} run "${h}" 0
  if [[ $(rc "${h}") == 0 && ! -e $(record "${h}") ]] && outerr "${h}" | grep -q 'オフにしてオンに戻す'; then
    ok "powershell.exe が失敗・知らない出力 (rc=${t%%:*}) なら記録しない"
  else
    ng "失敗 (rc=${t%%:*})" "rc=$(rc "${h}") $(outerr "${h}")"
  fi
done

# 9. 知らない引数: exit 2
h=$(new_home t9 "${state_on}" 1)
run "${h}" 0 --bogus
if [[ $(rc "${h}") == 2 && $(ncalls "${h}") == 0 ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
```

- [ ] **Step 5: `nix/flake.nix` の checks (`bootstrap-dotfiles-private-test` の次) に足す**

```nix
          bootstrap-windows-powertoys-test = scriptTest "bootstrap-windows-powertoys" ./scripts/bootstrap-windows-powertoys.sh;
```

- [ ] **Step 6: テストが落ちることを確かめる**

Run: `git add -N nix/tests && nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-powertoys-test' 2>&1 | tail -3`
Expected: FAIL (script がまだ無い)。

- [ ] **Step 7: script を書く `nix/scripts/bootstrap-windows-powertoys.sh`**

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を、Keyboard Manager に読み直させる。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 91
#
# ^ setup.sh が読む実行順。bootstrap-windows-files.sh (order: 90) が default.json を置いた後に
#   走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Keyboard Manager のエンジンは、起動したときと、名前付きイベント
# PowerToys_KeyboardManager_Event_Settings を受けたときにしか default.json を読まない
# (docs/adr/015_win_google_ime_powertoys_*)。win/ の割り当てを配っても、そのままでは効かない。
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンなら飛ばす。
#    <windowsHome>/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json が無いときも飛ばす
# 2. default.json の sha256 が、前回読み直させたときの記録
#    (~/.local/state/dotfiles/powertoys-keyboard-manager.reloaded) と同じなら何もしない (--force なら比べない)
# 3. powershell.exe でイベントを送る。送れたら記録する。イベントが無い (PowerToys が動いていない) ときも
#    記録する (起動したときに読むため)。interop が使えなければ手で読み直す方法を出し、記録しない
#
# どの場合も exit 0 (後ろの手順を止めない)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を、Keyboard Manager に読み直させる。

使い方:
  bootstrap-windows-powertoys.sh          前回から変わっていれば読み直させる
  bootstrap-windows-powertoys.sh --force  変わっていなくても読み直させる
EOS
}

force=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
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

state_file="${HOME}/.local/state/dotfiles/windows-files.json"
record_file="${HOME}/.local/state/dotfiles/powertoys-keyboard-manager.reloaded"
event=PowerToys_KeyboardManager_Event_Settings

manual() {
  echo "   PowerToys の設定 → Keyboard Manager を一度オフにしてオンに戻すと、読み直します。" >&2
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi
if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
default_json="${windows_home}/AppData/Local/Microsoft/PowerToys/Keyboard Manager/default.json"
if [[ -z ${windows_home} || ! -f ${default_json} ]]; then
  echo "Keyboard Manager の default.json がまだありません (${default_json})。この手順は飛ばします。"
  exit 0
fi

sum=$(sha256sum <"${default_json}" | cut -d' ' -f1)
if ((! force)) && [[ -r ${record_file} && $(head -n 1 "${record_file}") == "${sum}" ]]; then
  echo "Keyboard Manager は、今の default.json を読み直し済みです。"
  exit 0
fi

# PowerShell に渡すコマンド。イベントがあれば Set() して set、無ければ absent を出す
ps="\$h = \$null; if ([System.Threading.EventWaitHandle]::TryOpenExisting('${event}', [ref]\$h)) { [void]\$h.Set(); \$h.Dispose(); 'set' } else { 'absent' }"

rc=0
out=$(timeout 60 powershell.exe -NoProfile -NonInteractive -Command "${ps}" </dev/null 2>&1) || rc=$?
out=$(printf '%s\n' "${out}" | tr -d '\r')

remember() {
  mkdir -p "$(dirname -- "${record_file}")"
  printf '%s\n' "${sum}" >"${record_file}"
}

if ((rc == 0)) && [[ ${out} == set ]]; then
  remember
  echo "Keyboard Manager に default.json を読み直させました。"
  exit 0
fi
if ((rc == 0)) && [[ ${out} == absent ]]; then
  remember
  echo "PowerToys (Keyboard Manager) が動いていません。起動したときに今の default.json を読みます。"
  exit 0
fi
echo "!! powershell.exe で Keyboard Manager に読み直させられませんでした (終了コード ${rc}。WSL の interop が落ちているかもしれません):" >&2
if [[ -n ${out} ]]; then
  printf '%s\n' "${out}" | sed 's/^/   /' >&2
fi
manual
exit 0
```

Run: `chmod +x nix/scripts/bootstrap-windows-powertoys.sh`

- [ ] **Step 8: テストが通ることを確かめる**

Run: `git add -N nix/scripts && nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-powertoys-test' 2>&1 | grep -E 'passed|FAIL' | tail -3`
Expected: `== 12 passed, 0 failed`。

- [ ] **Step 9: shfmt / shellcheck / nixfmt を通す**

Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-windows-powertoys.sh nix/tests/bootstrap-windows-powertoys.test.sh && shellcheck nix/scripts/bootstrap-windows-powertoys.sh nix/tests/bootstrap-windows-powertoys.test.sh && nixfmt --check nix/flake.nix && echo LINT-OK'`
Expected: `LINT-OK`。

- [ ] **Step 10: Commit**

```bash
git add .gitattributes .editorconfig win/manifest.toml win/powertoys nix/scripts/bootstrap-windows-powertoys.sh nix/tests/bootstrap-windows-powertoys.test.sh nix/flake.nix
git commit -F - <<'EOF'
feat(win): PowerToys の Keyboard Manager の割り当てを配り、名前付きイベントで読み直させる (TKT-139)

default.json と editorSettings.json を PowerToys が書いたバイト列のまま win/ に置いて manifest で
配り、bootstrap-windows-powertoys.sh (order 91) が PowerToys_KeyboardManager_Event_Settings を
送って Keyboard Manager に読み直させる。ADR 015 の F。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 6: home-manager と CI に組み込む

**Files:**
- Modify: `nix/home/modules/windows-files.nix`
- Modify: `.github/workflows/nix.yml` (lint ジョブ)

**Interfaces:**
- Consumes: Task 1 の `pkgs.callPackage ../../pkgs/pjp-google-ime { }`、Task 3 の `--check`
- Produces: `dotfiles.wsl.windowsFiles.enable = true` のホストの `home.packages` に `pjp-google-ime`

- [ ] **Step 1: `nix/home/modules/windows-files.nix` の引数と let を差し替え、`home.packages` を足す**

```nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  wsl = config.dotfiles.wsl;
  enable = wsl.windowsFiles.enable;
  # Google 日本語入力の設定とテキストを行き来させる道具 (ADR 015)。bootstrap-windows-google-ime.sh が
  # PATH から呼ぶ。win/ を配るマシンでだけ要る
  googleIme = pkgs.callPackage ../../pkgs/pjp-google-ime { };
in
```

(差し替える前は `{ config, ... }:` と、`wsl`・`enable` の 2 行だけの `let`。) `home.file.".local/state/dotfiles/windows-files.json".text =` の行の前に足す:

```nix
  home.packages = lib.optional enable googleIme;

```

- [ ] **Step 2: 入るホストと入らないホストを確かめる**

Run:
```bash
nix eval --raw './nix#homeConfigurations."pollenjp@wsl".config.home.packages' --apply 'ps: builtins.concatStringsSep "\n" (map (p: p.name or "?") ps)' | grep -c '^pjp-google-ime$'
nix eval --raw './nix#homeConfigurations."pollenjp@wsl-no-1password".config.home.packages' --apply 'ps: builtins.concatStringsSep "\n" (map (p: p.name or "?") ps)' | grep -c '^pjp-google-ime$'
nix flake check --all-systems --no-build ./nix 2>&1 | tail -2
```
Expected: 1 行目 `1`、2 行目 `0` (windowsFiles.enable が false のホストには入らない)、`nix flake check` は error 無し (最後の `warning: … unchecked: lib.` は前からある)。

- [ ] **Step 3: CI の lint ジョブに検証を足す**

`.github/workflows/nix.yml` の `- name: win/manifest.toml` のステップの次に足す:

```yaml

      # win/google-japanese-input/ のテキストの検証 (ADR 015)。flake からは win/ が見えないので
      # checkout の上で流す。組み立てる道具 (pjp-google-ime) は nix shell で借りる。
      - name: win/google-japanese-input/
        run: nix shell ./nix#pjp-google-ime --command ./nix/scripts/bootstrap-windows-google-ime.sh --check
```

Run: `nix shell ./nix#pjp-google-ime --command ./nix/scripts/bootstrap-windows-google-ime.sh --check`
Expected: `OK: …/win/google-japanese-input` (手元に dotfiles-private があれば `と辞書 N 個` も付く)。

- [ ] **Step 4: nixfmt を通す**

Run: `nix develop ./nix --command nixfmt --check nix/home/modules/windows-files.nix && echo OK`
Expected: `OK`。

- [ ] **Step 5: Commit**

```bash
git add nix/home/modules/windows-files.nix .github/workflows/nix.yml
git commit -F - <<'EOF'
feat(nix): win/ を配るマシンに pjp-google-ime を入れ、CI でテキストを検証する (TKT-139)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 7: README と ADR を今の形に合わせる

**Files:**
- Modify: `win/README.md`
- Modify: `nix/README.md`
- Modify: `docs/adr/015_win_google_ime_powertoys_20261011T234247JST/plantuml/06_powertoys_reload.puml` と、その `out/06_powertoys_reload.svg`
- Modify: `docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md` (3 節の表)

**Interfaces:**
- Consumes: Task 1〜6 で決まった名前・引数・置き場所
- Produces: なし

- [ ] **Step 1: `win/README.md` の表に 3 行足す (`herdr/Install-Herdr.ps1` の行の次)**

```markdown
| `powertoys/keyboard-manager/default.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\default.json` | PowerToys の Keyboard Manager の割り当て (CapsLock → F13 など)。エンジンが読む ([後述](#powertoys)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
| `powertoys/keyboard-manager/editorSettings.json` | `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\editorSettings.json` | Keyboard Manager の新しいエディタが持つ割り当ての一覧 ([後述](#powertoys)) |
| `google-japanese-input/` | `%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input\` | Google 日本語入力の設定とキー設定のテキスト。manifest では配らず、組み立てて配る ([後述](#google-日本語入力)、[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b)) |
```

- [ ] **Step 2: `win/README.md` の末尾に 2 節足す**

````markdown
## PowerToys

`powertoys/keyboard-manager/` は PowerToys の Keyboard Manager の割り当てで、manifest で配る。
IME のキー設定の F13 ([Google 日本語入力](#google-日本語入力)) は、ここの CapsLock → F13 が前提になっている
([TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b))。

| ファイル | 中身 |
| --- | --- |
| `default.json` | エンジンが読む割り当て。CapsLock (VK 20) → F13 (VK 124)、左 Shift + 英数 (VK 160 + 240) → CapsLock |
| `editorSettings.json` | 新しいエディタ (WinUI 3) が持つ割り当ての一覧。エンジンは読まない |

- **PowerToys が書いたバイト列のまま置く。** `default.json` は改行の無い 1 行、`editorSettings.json` は
  CRLF で、どちらも末尾に改行が無い。エディタで同じ内容を保存し直してもバイト列が変わらず、衝突に
  ならない。`.gitattributes` (改行を変えない) と `.editorconfig` (末尾に改行を足さない・CRLF) で守っている
- 配ったあと、続く `nix/scripts/bootstrap-windows-powertoys.sh` (order 91) が、名前付きイベント
  `PowerToys_KeyboardManager_Event_Settings` を `powershell.exe` から送って読み直させる (エンジンは
  ファイルを見張っていない)。`default.json` の sha256 が前回読み直させたときと同じなら何もしない。
  PowerToys が動いていなければ、起動したときに読む
- interop が落ちていて送れないときは、PowerToys の設定 → Keyboard Manager を一度オフにしてオンに戻す
- エディタで割り当てを変えると、次の `setup --update` が衝突として止まる ([衝突したら](#衝突したら))。
  `cp` で取り込むときは 2 つとも取り込む

  ```sh
  d='/mnt/c/Users/<名前>/AppData/Local/Microsoft/PowerToys/Keyboard Manager'
  cp "${d}/default.json" "${d}/editorSettings.json" win/powertoys/keyboard-manager/
  ```

## Google 日本語入力

`google-japanese-input/` は Google 日本語入力の設定とキー設定のテキストで、manifest では配らない。
Windows 側の `config1.db` は protobuf のバイナリで、保存のたびに時刻が入るので、
`nix/scripts/bootstrap-windows-google-ime.sh` (order 98) がテキストから組み立てて配る
([ADR 015](../docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md)、
[TKT-139](https://app.notion.com/p/Windows-Google-dotfiles-win-3f679149a66f81b1a592d85d7300a62b))。

| ファイル | 中身 |
| --- | --- |
| `config.txtpb` | キー設定とローマ字テーブル以外の全項目 (句読点・サジェストなど)。protobuf のテキスト形式 |
| `keymap.tsv` | キー設定。キー設定の画面のエクスポートと同じ形 (MS-IME 風に F13 → IMEOn / IMEOff の行を足してある) |
| `romaji.tsv` | ローマ字テーブル。カスタムしたときだけ置く (今は無い) |

ユーザー辞書は公開しないので、private な `pollenjp/dotfiles-private` の
`google-japanese-input/dictionaries/<名前>.tsv` (辞書ツールのエクスポートと同じ形) に置く。
`nix/scripts/bootstrap-dotfiles-private.sh` (order 50) が `$(ghq root)/github.com/pollenjp/dotfiles-private`
へ clone / pull する。取れないマシンでは辞書だけ飛ばす。

| 打つもの | すること |
| --- | --- |
| `nix/scripts/bootstrap-windows-google-ime.sh` | 組み立てて配る (`setup --update` でも毎回走る) |
| `nix/scripts/bootstrap-windows-google-ime.sh --dry-run` | 判定だけ見る |
| `nix/scripts/bootstrap-windows-google-ime.sh --import` | 画面で変えた分を、テキストへ取り込む |
| `nix/scripts/bootstrap-windows-google-ime.sh --force` | 衝突でも repo の中身で置き直す |
| `nix/scripts/bootstrap-windows-google-ime.sh --check` | テキストの検証だけ (CI の lint でも走る) |

- 比べるのは、時刻・版・OS (`general_config`) と辞書の id・並びを外した中身 (`pjp-google-ime digest`)。
  画面で OK を押しただけなら衝突にならない
- 置いたら `taskkill.exe /F` で変換サーバー (`GoogleIMEJaConverter.exe`) を落とす。次のキー入力で
  起動し直し、置いた設定を読む。変換サーバーは設定を起動時にしか読まず、落とさないまま設定画面で
  OK を押すと、置いた設定が古い設定で上書きされるため
- 直接入力モードのキー (F13 → IMEOn など) を変えたときは、アプリを起動し直すと効く
- 設定画面か辞書ツール (`GoogleIMEJaTool.exe`) が開いていると、閉じるよう出して止まる (exit 1)。
  interop が落ちていると置かない (exit 0)
- 置き換える前のファイルは `~/.local/state/dotfiles/google-japanese-input/backup/<時刻>/` に退避する
  (新しい方から 10 回分)
- 画面で変えたら、次の `setup --update` が衝突として diff を出して止まる。`--import` で取り込み、
  `git diff` を見て、dotfiles と dotfiles-private の両方で commit する
- テキストは画面のエクスポートと同じ形なので、仕組みが動かないときも、GUI の「インポート」で手で戻せる

### pjp-google-ime

テキストとバイナリを行き来させる CLI (`nix/pkgs/pjp-google-ime/`)。`windowsFiles.enable` のマシンでは
home-manager が PATH に入れる。Windows には触らない。

```sh
pjp-google-ime check --config-dir win/google-japanese-input     # 検証だけ
pjp-google-ime decode --kind config <config1.db> --out <dir>    # バイナリをテキストに戻す
pjp-google-ime digest --kind config <config1.db>                # 比べるための sha256
```

- Mozc の `.proto` の写しは `nix/pkgs/pjp-google-ime/proto/` にある (写した commit と、新しくする手順は
  そこの README)。新しい版の Google 日本語入力が項目を足すと、`--import` が止まって知らせる
- テストは `nix build ./nix#checks.x86_64-linux.pjp-google-ime-unittest`
````

- [ ] **Step 3: `nix/README.md` の「bootstrap の実行順」の表に 3 行足す**

`| その他 | 50（既定） | 依存なし |` の行の次:

```markdown
| `bootstrap-dotfiles-private.sh` | 50 | private な dotfiles-private を取る。中身を読む `bootstrap-windows-google-ime.sh` (98) より先ならよい (既定と同じ値を書いてある) |
```

`| bootstrap-windows-files.sh | 90 | …` の行の次:

```markdown
| `bootstrap-windows-powertoys.sh` | 91 | `bootstrap-windows-files.sh` が置いた PowerToys の `default.json` を Keyboard Manager に読み直させる (exit 1 にしない) |
```

`| bootstrap-windows-herdr.sh | 97 | …` の行の次:

```markdown
| `bootstrap-windows-google-ime.sh` | 98 | Google 日本語入力の設定を組み立てて配る。衝突や設定画面が開いているときの exit 1 で、ほかの bootstrap を止めない |
```

- [ ] **Step 4: `nix/README.md` の「新規マシンの手順」の表に 3 行足す**

`| 6.5 | …bootstrap-claude-skills.sh…` の行の次:

```markdown
| 6.5.1 | `./nix/scripts/bootstrap-dotfiles-private.sh` | `bootstrap-dotfiles-private` | private な dotfiles-private の取得 (取れなくても止めない。[`win/README.md`](../win/README.md#google-日本語入力)) |
```

`| 6.8 | …bootstrap-windows-files.sh…` の行の次:

```markdown
| 6.8.1 | `./nix/scripts/bootstrap-windows-powertoys.sh` | `bootstrap-windows-powertoys` | 配った PowerToys の割り当てを Keyboard Manager に読み直させる（[`win/README.md`](../win/README.md#powertoys)） |
```

`| 6.11 | …bootstrap-windows-herdr.sh…` の行の次:

```markdown
| 6.11.1 | `./nix/scripts/bootstrap-windows-google-ime.sh` | `bootstrap-windows-google-ime` | Google 日本語入力の設定とユーザー辞書を、テキストから組み立てて配る（[`win/README.md`](../win/README.md#google-日本語入力)） |
```

- [ ] **Step 5: `nix/README.md` の「Windows 側のファイルを配る」の反映のコマンドに 2 行と、箇条書きに 1 項目足す**

`./nix/scripts/check-herdr-keys.sh …` の行の次:

```sh
./nix/scripts/bootstrap-windows-powertoys.sh         # 配った PowerToys の割り当てを Keyboard Manager に読み直させる部分だけ
./nix/scripts/bootstrap-windows-google-ime.sh        # Google 日本語入力の設定を組み立てて配る部分だけ（--dry-run / --import / --force / --check）
```

箇条書きの最後 (`- PowerShell の共有設定 …` の項目) の次:

```markdown
- Google 日本語入力の設定 (`win/google-japanese-input/`) は manifest では配らない。protobuf のバイナリで
  保存のたびに時刻が入るので、`bootstrap-windows-google-ime.sh` (order 98) が `pjp-google-ime` で
  組み立て、時刻を除いた中身で比べて配り、変換サーバーを落として読み直させる。辞書は private な
  dotfiles-private (`bootstrap-dotfiles-private.sh`) から取る（[`win/README.md`](../win/README.md#google-日本語入力)、
  [ADR 015](../docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md)）
```

- [ ] **Step 6: `nix/README.md` の「テスト」の表に 4 行足す (`video-offer-nudge.test.sh` の行の次)**

```markdown
| `bootstrap-windows-google-ime.test.sh` | 組み立てて配る判定 (飛ばす・interop が無い・設定画面が開いている・壊れたテキスト・置く・同じ・時刻だけ違う・repo 側が進んだ・衝突・`--dry-run` / `--import` / `--force` / `--check`・読めないファイル・辞書が無い・退避の間引き・taskkill の 128)。偽の `tasklist.exe` と `taskkill.exe` で流す（22 件） | `bootstrap-windows-google-ime-test`（Linux） |
| `bootstrap-windows-powertoys.test.sh` | Keyboard Manager に読み直させる判定 (飛ばす・送れた・同じなら送らない・`--force`・動いていない・interop が無い)。偽の `powershell.exe` で流す（12 件） | `bootstrap-windows-powertoys-test`（Linux） |
| `bootstrap-dotfiles-private.test.sh` | dotfiles-private の clone / pull (未コミットの変更・repo でないもの・clone できない)。手元の bare repo で流す（6 件） | `bootstrap-dotfiles-private-test`（Linux） |
| `nix/pkgs/pjp-google-ime/test_google_ime.py` | テキストとバイナリの行き来・決定論・digest・検証・import (Mozc の `.proto` の写しから作った記述子で流す。41 件) | `pjp-google-ime-unittest`（Linux） |
```

- [ ] **Step 7: `nix/README.md` の「ディレクトリ」の木を直す**

`│       ├── windows-files.nix  ~/.local/state/dotfiles/windows-files.json (win/ の配り先と on / off)` の行を次に替える:

```text
│       ├── windows-files.nix  ~/.local/state/dotfiles/windows-files.json (win/ の配り先と on / off)。win/ を配るマシンの PATH に pjp-google-ime を置く
```

`│   └── pjp-who-is-asking/   1Password …` の行を次の 2 行に替える:

```text
│   ├── pjp-who-is-asking/   1Password の承認ダイアログの要求元を、Windows と Linux をまたいだ 1 本の木で出す
│   └── pjp-google-ime/      Google 日本語入力の設定・辞書と repo のテキストを行き来させる (Mozc の .proto の写しを持つ。ADR 015)
```

`    ├── bootstrap-claude-skills.sh  private な skill 置き場を取得して繋ぐ (冪等)` の行の次に足す:

```text
    ├── bootstrap-dotfiles-private.sh  private な dotfiles-private を取得する (冪等。更新時も毎回走る。取れなくても止めない)
```

`    ├── bootstrap-windows-files.sh  repo 直下の win/ を /mnt/c へコピーして配る (冪等。更新時も毎回走る)` の行の次に足す:

```text
    ├── bootstrap-windows-powertoys.sh  win/ から配った PowerToys の割り当てを Keyboard Manager に読み直させる (冪等。更新時も毎回走る)
```

`    ├── bootstrap-windows-herdr.sh  Windows の herdr が …` の行の次に足す:

```text
    ├── bootstrap-windows-google-ime.sh  Google 日本語入力の設定とユーザー辞書を、テキストから組み立てて配る (冪等。更新時も毎回走る)
```

`├── pkgs/                  自作のパッケージ (modules/exe-exec-trace.nix が使う。flake の packages と checks にも載せる)` の行を次に替える:

```text
├── pkgs/                  自作のパッケージ (modules/exe-exec-trace.nix と modules/windows-files.nix が使う。flake の packages と checks にも載せる)
```

- [ ] **Step 8: ADR 015 の図 06 を `-Command` に直して書き出し直す**

実装は `-EncodedCommand` ではなく `-Command` で渡す (iconv を要らなくするため。§1 の 8 の確かめは `-EncodedCommand` で行ったので、本文はそのまま)。`docs/adr/015_win_google_ime_powertoys_20261011T234247JST/plantuml/06_powertoys_reload.puml` の

```text
:powershell.exe -EncodedCommand で\nPowerToys_KeyboardManager_Event_Settings を\nTryOpenExisting → Set();
```

を次に替える:

```text
:powershell.exe -Command で\nPowerToys_KeyboardManager_Event_Settings を\nTryOpenExisting → Set();
```

Run: `(cd docs/adr/015_win_google_ime_powertoys_20261011T234247JST/plantuml && ~/.claude/skills/pjp-plantuml/scripts/plantuml-export.sh 06_powertoys_reload.puml) && git diff --stat -- docs/adr`
Expected: `06_powertoys_reload.puml` と `out/06_powertoys_reload.svg` の 2 つが変わる。

- [ ] **Step 9: ADR 015 の「3. 変更点の詳細」の表に 2 行足す (`win/manifest.toml` の行の次)**

```markdown
| `.gitattributes` | 新規。`win/powertoys/**` の改行を変えない (`-text`) |
| `.editorconfig` | `win/powertoys/**.json` は末尾に改行を足さない、`editorSettings.json` は CRLF |
```

- [ ] **Step 10: リンクの先が在ることを確かめる**

Run: `grep -o '](#[^)]*)' win/README.md | sort -u` と `grep -n '^## PowerToys\|^## Google 日本語入力\|^### pjp-google-ime' win/README.md`
Expected: `#powertoys` と `#google-日本語入力` へのリンクがあり、見出し `## PowerToys` と `## Google 日本語入力` がある。

- [ ] **Step 11: Commit**

```bash
git add win/README.md nix/README.md docs/adr/015_win_google_ime_powertoys_20261011T234247JST
git commit -F - <<'EOF'
docs: Google 日本語入力と PowerToys の配り方を win/README.md と nix/README.md に書き、ADR 015 を実装に合わせる (TKT-139)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

---

### Task 8: dotfiles-private を作り、ユーザー辞書を取り込む (ユーザーと一緒に進める)

subagent には任せない。GitHub に repo を作るのは外へ出る操作なので、作る前にユーザーの確認を取る。辞書の中身はログや transcript に出さない (`git diff` を流すときは `--stat` だけ)。

**Files:**
- Create (別の repo `pollenjp/dotfiles-private`): `README.md`、`google-japanese-input/dictionaries/<名前>.tsv`

- [ ] **Step 1: ユーザーに確かめてから private repo を作る**

```bash
gh repo create pollenjp/dotfiles-private --private --description "pollenjp/dotfiles の公開しない設定 (Google 日本語入力のユーザー辞書など)"
```

- [ ] **Step 2: 新しい bootstrap で clone する**

Run: `nix/scripts/bootstrap-dotfiles-private.sh`
Expected: `dotfiles-private を clone しました: /home/pollenjp/ghq/github.com/pollenjp/dotfiles-private` (空の repo なので中身は無い)。

- [ ] **Step 3: README を置く**

`<clone>/README.md`:

```markdown
# dotfiles-private

[pollenjp/dotfiles](https://github.com/pollenjp/dotfiles) の、公開しない設定を置く private repo。
dotfiles の `nix/scripts/bootstrap-dotfiles-private.sh` が ghq の下へ clone / pull する。

| 場所 | 中身 | 使う手順 |
| --- | --- | --- |
| `google-japanese-input/dictionaries/<名前>.tsv` | Google 日本語入力のユーザー辞書 1 つ (「読み<TAB>単語<TAB>品詞<TAB>コメント」、辞書ツールのエクスポートと同じ) | dotfiles の `nix/scripts/bootstrap-windows-google-ime.sh` (配る・`--import` で取り込む) |

画面で辞書を変えたら、dotfiles 側で `nix/scripts/bootstrap-windows-google-ime.sh --import` を流し、
ここで commit して push する。経緯は dotfiles の ADR 015。
```

- [ ] **Step 4: 辞書を取り込む (Windows 側は読むだけ)**

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh --import`
Expected: `書いた: …/dotfiles-private/google-japanese-input/dictionaries/<名前>.tsv` (設定のテキストは Task 2 と同じなので `書いた` は辞書の 1 行だけ)、`取り込みました。…`。終了コード 0。

Run: `git -C ~/ghq/github.com/pollenjp/dotfiles-private status --short && git -C ~/ghq/github.com/pollenjp/dotfiles-private diff --stat` (中身は出さない)

- [ ] **Step 5: 判定が「同じ」になることを確かめる**

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh --dry-run`
Expected: `同じです: …/config1.db` と `同じです: …/user_dictionary.db`。

- [ ] **Step 6: private repo に commit して push する**

```bash
cd ~/ghq/github.com/pollenjp/dotfiles-private
git add README.md google-japanese-input
git commit -m "Google 日本語入力のユーザー辞書を取り込む (pollenjp/dotfiles の TKT-139)"
git push -u origin HEAD:main
```

---

### Task 9: 実機で確かめ、ADR 015 の検証の表を埋める (ユーザーと一緒に進める)

subagent には任せない。Windows 側を書き換え、変換サーバーを落とし、ユーザーに日本語を打ってもらうため。始める前に、何をするかをユーザーに伝えて許可を取る。

**Files:**
- Modify: `docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md` (6 節の「実装で確かめること」の結果の列)

- [ ] **Step 1: 初回が「同じ」で終わる**

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh`
Expected: 2 つとも `同じです`。変換サーバーは落とさない (置いたものが無い)。終了コード 0。記録 `~/.local/state/dotfiles/google-japanese-input/deployed.json` ができる。

- [ ] **Step 2: 設定を 1 つ変えて配ると、変換サーバーが起き直して効く**

`win/google-japanese-input/config.txtpb` の `punctuation_method: TOUTEN_KUTEN` を `punctuation_method: COMMA_PERIOD` に替え (commit しない)、流す:

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh`
Expected: `上書き (repo 側が進んだ): …/config1.db`、退避の行、`変換サーバー (GoogleIMEJaConverter.exe) を落としました。…`。

ユーザーに、日本語入力で「、。」を打つと「，．」になることを確かめてもらう。PID が替わったことも見る:

Run: `powershell.exe -NoProfile -Command 'Get-Process GoogleIMEJaConverter | ForEach-Object { "{0} {1:HH:mm:ss}" -f $_.Id, $_.StartTime }'`

- [ ] **Step 3: 戻す**

`punctuation_method` を `TOUTEN_KUTEN` に戻して流し (`git diff` が空になることを先に確かめる)、ユーザーに「、。」に戻ったことを確かめてもらう。

- [ ] **Step 4: 画面での変更が衝突として見え、`--import` で取り込める**

ユーザーに Google 日本語入力のプロパティで何か 1 つ変えて OK を押してもらう (例: サジェストの数)。流す:

Run: `nix shell ./nix#pjp-google-ime --command nix/scripts/bootstrap-windows-google-ime.sh`
Expected: `!! 衝突: …/config1.db …`、`--- Windows 側/config.txtpb` の diff に変えた項目、終了コード 1。Windows 側のファイルは変わらない。

続けて `--import` を流し、`git diff win/google-japanese-input` に変えた項目だけが出ることを見る。そのあとユーザーに画面で元に戻してもらい、もう一度 `--import` を流して `git diff` が空になることを確かめる。

- [ ] **Step 5: PowerToys に読み直させる**

Run: `nix/scripts/bootstrap-windows-files.sh --dry-run`
Expected: PowerToys の 2 件は `同じです`。ほかのファイルで `[dry-run] 上書き` が出たら、この PR と関係の無い変更 (main の新しい win/) なので、ユーザーに確かめてから流す。

Run: `nix/scripts/bootstrap-windows-powertoys.sh`
Expected: `Keyboard Manager に default.json を読み直させました。`。もう一度流すと `読み直し済みです`。Keyboard Manager のログ (`%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\Engine\Logs\<版>\log_<日付>.log`) の末尾に `event was signaled` と `SettingsHelper::LoadSettings()` が出る。

割り当てが変わって効くことまで確かめるかは、ユーザーに聞く (確かめるなら、`win/powertoys/keyboard-manager/default.json` の CapsLock → F13 を一時的に外して `bootstrap-windows-files.sh` と `bootstrap-windows-powertoys.sh` を流し、CapsLock が CapsLock に戻ることを見てから元に戻す)。

- [ ] **Step 6: 閉包スキャンで新しい findings が出ないかを見る**

Run: `nix/scripts/closure-scan.sh report ./nix 2>&1 | tail -20`
Expected: whitelist に無い findings が無い。protobuf / python の findings が出たら、pin を動かすか whitelist に足すかの判断をユーザーに持っていく (`pjp-dotfiles-update` skill の 2 択)。

- [ ] **Step 7: ADR 015 の 6 節の「実装で確かめること」の結果の列を埋める**

`—` を、実際に出た数と結果に替える (例: unittest `41 件すべて通過`、bootstrap のテスト `22 / 12 / 6 件すべて通過`、静的 `指摘なし`、実機の 3 行は Step 1〜5 の結果)。

- [ ] **Step 8: Commit**

```bash
git add docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md win/google-japanese-input
git commit -F - <<'EOF'
docs(adr): ADR 015 の検証に、実装の結果と実機で確かめたことを書く (TKT-139)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01YSF6gCGyvBHzRBtjbB61Fm
EOF
```

(`win/google-japanese-input` に差が無ければ `git add` から外す。)

---

### Task 10: PR を出す (ユーザーと一緒に進める)

- [ ] **Step 1: 全体の check を流す**

Run: `nix flake check --all-systems --no-build ./nix && nix build --no-link -L './nix#checks.x86_64-linux.pjp-google-ime-unittest' './nix#checks.x86_64-linux.bootstrap-windows-google-ime-test' './nix#checks.x86_64-linux.bootstrap-windows-powertoys-test' './nix#checks.x86_64-linux.bootstrap-dotfiles-private-test' 2>&1 | grep -E 'passed|Ran|FAIL' `
Expected: エラー無し。`== 22 passed`・`== 12 passed`・`== 6 passed`・`Ran 41 tests`。

- [ ] **Step 2: push して PR を作る**

PR のタイトルは `TKT-139 Google 日本語入力と PowerToys の設定を repo のテキストから組み立て直して配る`、本文の 1 行目は `~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh show TKT-139 --url` の URL。本文には差分の要点と確かめた手順だけを書く (背景と決定はチケットと ADR 015)。辞書の中身は書かない。PR の本文の最後に attribution を付ける。

- [ ] **Step 3: チケットに結ぶ**

Run: `~/.claude/skills/pjp-dev-tracker/scripts/ticket.sh pr TKT-139` と `ticket.sh link TKT-139 <PR の URL> "PR"`

- [ ] **Step 4: merge のあとにユーザーが打つものを伝える**

`~/dotfiles/setup --update` (switch で `pjp-google-ime` が入り、`bootstrap-dotfiles-private.sh` と 2 つの新しい手順が走る)。
