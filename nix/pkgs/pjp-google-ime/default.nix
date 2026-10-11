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
