# WSL の op (1Password CLI の wrapper。理由 (--reason) を必須にし、呼び出しごとの powershell で承認を閉じる) と、その記録を
# 見る pjp-op-log。動きは op.sh・launcher.ps1・pjp-op-log.sh の先頭のコメント。
#
# launcher (launcher.ps1) は op が powershell.exe -EncodedCommand で渡すので、build のときに UTF-16LE の base64 にして store に
# 置き (launcherB64)、op の PJP_OP_LAUNCHER に入れる。launcher は BOM 付きの UTF-8 で置いてあり (.editorconfig の [*.ps1])、
# BOM を外して ASCII だけかを確かめる (日本語の文は op が payload に入れる。ほかの文字があれば build が落ちる)。
#
# どちらの script も errexit を付けずに書いてある (落ちうるコマンドは自分で受ける) ので、bashOptions から外す。
# op.exe・powershell.exe・wslpath・herdr は nixpkgs に無く WSL・Windows・dotfiles のほかの package が持つものなので、
# runtimeInputs に入れない (呼ぶ側の PATH から引く)。home/modules/op-reason.nix が WSL + 1Password のマシンの PATH に入れる。
{
  writeShellApplication,
  symlinkJoin,
  runCommand,
  python3,
  coreutils,
  gnugrep,
  gnused,
  jq,
  util-linux,
  git,
}:

let
  launcherB64 = runCommand "pjp-op-launcher.b64" { nativeBuildInputs = [ python3 ]; } ''
    python3 - ${./launcher.ps1} "$out" <<'PY'
    import base64, sys
    data = open(sys.argv[1], "rb").read()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    text = data.decode("ascii")
    with open(sys.argv[2], "w", encoding="ascii") as out:
        out.write(base64.b64encode(text.encode("utf-16-le")).decode("ascii"))
    PY
  '';

  op = writeShellApplication {
    name = "op";
    runtimeInputs = [
      coreutils
      gnugrep
      gnused
      jq
      util-linux
      git
    ];
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    runtimeEnv.PJP_OP_LAUNCHER = "${launcherB64}";
    text = builtins.readFile ./op.sh;
  };

  log = writeShellApplication {
    name = "pjp-op-log";
    runtimeInputs = [
      coreutils
      jq
      util-linux
    ];
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = builtins.readFile ./pjp-op-log.sh;
  };
in
symlinkJoin {
  name = "pjp-op";
  paths = [
    op
    log
  ];
  passthru = { inherit launcherB64; };
  meta.mainProgram = "op";
}
