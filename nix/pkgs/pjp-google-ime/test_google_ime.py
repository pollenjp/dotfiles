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
