# WSL の op (1Password CLI の wrapper。理由 (--reason) を必須にし、呼び出しごとの powershell で承認を閉じる) と、その記録を
# 見る pjp-op-log。動きは op.sh・launcher.ps1・pjp-op-log.sh の先頭のコメント。
#
# launcher は build のときに 2 つのファイルにして store に置き (launcher)、op の PJP_OP_LAUNCHER に dir を入れる:
#
#   script.b64   launcher.ps1 の UTF-8 の base64。op が env の PJP_OP_SCRIPT で渡す
#   command.b64  script.b64 を env から読んで実行する短い起動の式の、UTF-16LE の base64 (powershell.exe の -EncodedCommand)
#
# launcher.ps1 をそのまま -EncodedCommand にすると 3 万 5 千字ほどになり、Windows の command line の上限 (32767 字) を超えて
# powershell.exe が起きない。env の値の上限も 32767 字なので、script.b64 が 30000 字を超えたら build を落とす。
# launcher は BOM 付きの UTF-8 で置いてあり (.editorconfig の [*.ps1])、BOM を外して ASCII だけかを確かめる (日本語の文は
# op が payload に入れる。ほかの文字があれば build が落ちる)。起動の式は、最初に進捗を止め (止めないと stderr に CLIXML の
# 進捗が出る)、env を消してから launcher を同じ scope で実行する (launcher の exit がそのまま powershell.exe の終了コードになる)。
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
  launcher = runCommand "pjp-op-launcher" { nativeBuildInputs = [ python3 ]; } ''
    mkdir -p "$out"
    python3 - ${./launcher.ps1} "$out" <<'PY'
    import base64, sys
    data = open(sys.argv[1], "rb").read()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    data.decode("ascii")
    script = base64.b64encode(data).decode("ascii")
    if len(script) > 30000:
        sys.exit("launcher.ps1 is too large for an environment variable: %d characters of base64" % len(script))
    boot = (
        "$ProgressPreference = 'SilentlyContinue'\n"
        "try {\n"
        "  $s = $env:PJP_OP_SCRIPT\n"
        "  Remove-Item Env:PJP_OP_SCRIPT -ErrorAction SilentlyContinue\n"
        "  $b = [ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)))\n"
        "} catch {\n"
        "  [Console]::Error.WriteLine('pjp-op: launcher: cannot load the script: ' + $_.Exception.Message)\n"
        "  exit 1\n"
        "}\n"
        ". $b\n"
    )
    command = base64.b64encode(boot.encode("utf-16-le")).decode("ascii")
    with open(sys.argv[2] + "/script.b64", "w", encoding="ascii") as out:
        out.write(script)
    with open(sys.argv[2] + "/command.b64", "w", encoding="ascii") as out:
        out.write(command)
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
    runtimeEnv.PJP_OP_LAUNCHER = "${launcher}";
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
  passthru = { inherit launcher; };
  meta.mainProgram = "op";
}
