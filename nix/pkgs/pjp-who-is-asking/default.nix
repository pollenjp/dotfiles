# 1Password の承認ダイアログが出ている間に、要求元を Windows と Linux をまたいだ
# 1 本の木で出す (ADR 012)。root は要らない。
#
# Windows 側は powershell.exe (WSL の interop) で取る。writeShellApplication は
# runtimeInputs を元の PATH の前に足すだけなので、Windows 側の PATH も残る。
{
  writeShellApplication,
  python3,
}:

writeShellApplication {
  name = "pjp-who-is-asking";
  runtimeInputs = [ python3 ];
  text = ''
    exec python3 -I ${./who_is_asking.py} "$@"
  '';
}
