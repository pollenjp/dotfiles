# WSL から起動された Windows の .exe を、起動元の祖先付きで記録するトレーサ (ADR 012)。
#
# bcc (BPF をその場でコンパイルして読み込む) を nixpkgs から取る。kmod は、WSL の
# カーネル (CONFIG_IKHEADERS=m) のヘッダを bcc が読むときの `modprobe kheaders` に要る。
#
# 記録するには root が要る。常時動かすのは systemd の system の unit
# (home/modules/exe-exec-trace.nix が生成し、setup の手順 exe-exec-trace が入れる)。
# 記録を読む `--pretty` は root も bcc も要らない。
{
  writeShellApplication,
  python3,
  kmod,
}:

writeShellApplication {
  name = "exe-exec-trace";
  runtimeInputs = [
    (python3.withPackages (ps: [ ps.bcc ]))
    kmod
  ];
  text = ''
    exec python3 ${./exe_exec_trace.py} "$@"
  '';
}
