# アカウントを足す管理のコマンド claude-account と、そのアカウントで Claude Code を起こす launcher claude-<名前> と、素の claude を token で
# 起こす wrapper claude を兼ねる 1 本の script (claude-account.sh)。呼ばれた名前 ($0) で振り分ける。設計は dotfiles-private の
# docs/adr/082_claude_token_accounts_* と docs/adr/123_claude_token_watch_*。
#
#   bin/claude-account       script そのもの
#   bin/claude-<既定の名前>   claude-account への link (claude.nix の accounts。今は personal・work)
#
# 素の claude の wrapper (~/<bareBinRel>/claude) は package に入れず、home/modules/claude.nix が home.file で claude-account への link に
# する (宣言 dotfiles.claude.tokens.default のホストだけ)。profile の bin に claude を置くと、ほかの package の claude とぶつかり、対話の
# シェルでは mise の claude より後ろになるため。bareToken はその宣言の有る無しで、check・set-token・audit の default の扱いを決める。
#
# claude-account add が足すアカウントの launcher は、~/.local/bin/claude-<名前> から profileBin の claude-account への link
# (package は後から足せないので、PATH にある書き込める dir に置く。link の先を /nix/store にすると GC で切れるので profile の bin)。
#
# script の @defaults@・@profileBin@・@pjpOpEnv@・@coreutils@・@jq@・@bootstrap@・@bareToken@・@bareBinRel@ を埋める。runtimeInputs は持たない (claude に渡す
# PATH を変えない)。中で使う外のコマンドは store のパスで呼ぶ (hc exec のように login shell を通らない起こし方でも動く)。
# errexit を付けずに書いてある (落ちうるコマンドは自分で受ける) ので、bashOptions から外す。
{
  lib,
  runCommand,
  writeShellApplication,
  callPackage,
  coreutils,
  jq,
  # 既定のアカウントの名前 (dotfiles が作る。subscription)
  defaults,
  # add が張る link の先の dir (home-manager の profile の bin)
  profileBin,
  # 素の claude を token で起こすホストか (dotfiles.claude.tokens.default の宣言がある)
  bareToken ? false,
  # 素の claude の wrapper を置く dir (家からの相対。home/modules/claude.nix と同じ値)
  bareBinRel ? ".local/share/claude-account/bin",
}:

let
  pjpOpEnv = callPackage ../pjp-op-env { };
  script = writeShellApplication {
    name = "claude-account";
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text =
      builtins.replaceStrings
        [
          "@defaults@"
          "@profileBin@"
          "@pjpOpEnv@"
          "@coreutils@"
          "@jq@"
          "@bootstrap@"
          "@bareToken@"
          "@bareBinRel@"
        ]
        [
          (lib.concatStringsSep " " defaults)
          profileBin
          "${pjpOpEnv}"
          "${coreutils}"
          "${jq}"
          "${../../scripts/bootstrap-claude-accounts.sh}"
          (if bareToken then "1" else "0")
          bareBinRel
        ]
        (builtins.readFile ./claude-account.sh);
  };
in
runCommand "claude-account"
  {
    meta.mainProgram = "claude-account";
  }
  (
    ''
      mkdir -p $out/bin
      ln -s ${lib.getExe script} $out/bin/claude-account
    ''
    + lib.concatMapStrings (n: ''
      ln -s claude-account $out/bin/claude-${n}
    '') defaults
  )
