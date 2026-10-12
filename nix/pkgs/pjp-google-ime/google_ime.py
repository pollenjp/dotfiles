"""Google 日本語入力の設定 (config1.db) とユーザー辞書 (user_dictionary.db) を、repo のテキストと
行き来させる (docs/adr/015_win_google_ime_powertoys_20261011T234247JST/README.md)。

Windows には触らない。読み書きするのは渡されたパスのファイルだけで、Windows 側へ置くのと
変換サーバーを落とすのは nix/scripts/bootstrap-windows-google-ime.sh がやる。

テキストの形:

  <config-dir>/config.txtpb    config1.db のうち、general_config・custom_keymap_table・
                               custom_roman_table を除いた全項目 (protobuf のテキスト形式)
  <config-dir>/keymap.tsv      custom_keymap_table の文字列そのもの (キー設定の画面のエクスポートと同じ。
                               表が空なら置かない)
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
        table = getattr(rest, name)
        rest.ClearField(name)
        # 空の表は「無い」と同じに扱う。設定画面は、キー設定を一度もカスタムしていなくても
        # custom_keymap_table を空文字で入れる (Mozc の gui/config_dialog/config_dialog.cc)
        if not table:
            tables.append(None)
            continue
        try:
            tables.append(table.decode())
        except UnicodeDecodeError:
            raise TextError(f"{CONFIG_DB} の {name} が UTF-8 ではないので {file} に書けない") from None
    rest.ClearField("general_config")
    return TXTPB_HEADER + text_format.MessageToString(rest, as_utf8=True), tables[0], tables[1]


def config_digest(cfg):
    """比べるための sha256。general_config (時刻・版・OS) は外し、空の表は「無い」にそろえる"""
    c = type(cfg)()
    c.CopyFrom(cfg)
    c.ClearField("general_config")
    for name in ("custom_keymap_table", "custom_roman_table"):
        if not getattr(c, name):
            c.ClearField(name)  # 設定画面はカスタムしていない表も空文字で入れる (config_to_text と同じ)
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
        # エラーにはセルの中身 (読み・単語・品詞・コメント) を出さない。setup の出力は Claude などの
        # ログにも残るため。列がずれると品詞の列に語が入るので、品詞の値も出さない
        for n, line in enumerate(lines, start=1):
            fields = line.split("\t")
            if len(fields) not in (3, 4):
                raise TextError(
                    f"{name}.tsv:{n}: 列が {len(fields)} 個ある (「読み<TAB>単語<TAB>品詞<TAB>コメント」の 4 列。"
                    "コメントが無ければ 3 列でもよい)"
                )
            if len(fields) == 3:
                fields.append("")
            empty = [label for label, cell in (("1 列目の読み", fields[0]), ("2 列目の単語", fields[1])) if not cell]
            if empty:
                raise TextError(f"{name}.tsv:{n}: {'と'.join(empty)}が空")
            if fields[2] not in POS_INDEX:
                raise TextError(
                    f"{name}.tsv:{n}: 3 列目の品詞が Mozc に無い (品詞の名前は Mozc の user_pos.def と同じ書き方。"
                    "辞書ツールのエクスポートと同じ)"
                )
            e = d.entries.add()
            e.key = fields[0]
            e.value = fields[1]
            # コメントが空の語は、Windows 側では、辞書ツールの表で編集した語なら comment が「ある」で、
            # 単語登録ダイアログ・インポートで入れた語なら「無い」で入っている。ここでは必ず入れ、
            # 比べる digest (dictionary_digest) は両方を同じに扱う
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
        # エラーには語を出さない (何番目の語かだけ。dictionaries_from_tsv と同じ理由)
        for i, e in enumerate(d.entries, start=1):
            if e.locale:
                raise TextError(f"辞書 {d.name!r} の {i} 番目の語に locale が付いていて、TSV に書けない")
            if any(c in v for v in (e.key, e.value, e.comment) for c in "\t\n\r"):
                raise TextError(f"辞書 {d.name!r} の {i} 番目の語にタブか改行が入っていて、TSV に書けない")
            rows.append(f"{e.key}\t{e.value}\t{POS_NAMES[e.pos]}\t{e.comment}\n")
        files[d.name] = "".join(rows)
    return files


def dictionary_digest(storage):
    """比べるための sha256。辞書の id と辞書の並びは外し (画面で作った辞書の id は乱数のため)、
    空のコメントは「無い」にそろえる"""
    s = type(storage)()
    s.CopyFrom(storage)
    s.ClearField("dictionaries")
    for d in sorted(storage.dictionaries, key=lambda d: d.name):
        c = s.dictionaries.add()
        c.CopyFrom(d)
        c.ClearField("id")
        for e in c.entries:
            if not e.comment:
                e.ClearField("comment")  # 単語登録ダイアログとインポートは空のコメントを入れない
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
    p = win / DICTIONARY_DB
    if a.dictionary_dir and p.is_file():
        storage = read_dictionary_db(p)
        files = dictionaries_to_tsv(storage)
        if dictionary_digest(dictionaries_from_tsv(files)) != dictionary_digest(storage):
            raise TextError(f"{DICTIONARY_DB} をテキストに戻すと中身が変わる (TSV で表せない項目がある)")
    elif a.dictionary_dir:
        # ファイルが無いのは、まだ辞書を作っていないか置き場所が違うかで、辞書を全部消したのとは
        # 違う。TSV は消さずに残す (消えた辞書の TSV を消すのは、ファイルがあって辞書が無いとき)
        print(f"pjp-google-ime: {p} が無いので、辞書は取り込みません (TSV はそのまま)", file=sys.stderr)
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
