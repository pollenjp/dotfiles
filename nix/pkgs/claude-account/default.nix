# アカウントを足す管理のコマンド claude-account と、そのアカウントで Claude Code を起こす launcher claude-<名前> を兼ねる 1 本の script
# (claude-account.sh)。呼ばれた名前 ($0) で振り分ける。設計は dotfiles-private の docs/adr/082_claude_token_accounts_*。
#
#   bin/claude-account       script そのもの
#   bin/claude-<既定の名前>   claude-account への link (claude.nix の accounts。今は personal・work)
#
# claude-account add が足すアカウントの launcher は、~/.local/bin/claude-<名前> から profileBin の claude-account への link
# (package は後から足せないので、PATH にある書き込める dir に置く。link の先を /nix/store にすると GC で切れるので profile の bin)。
#
# script の @defaults@・@profileBin@・@pjpOpEnv@・@coreutils@・@jq@・@bootstrap@ を埋める。runtimeInputs は持たない (claude に渡す
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
        ]
        [
          (lib.concatStringsSep " " defaults)
          profileBin
          "${pjpOpEnv}"
          "${coreutils}"
          "${jq}"
          "${../../scripts/bootstrap-claude-accounts.sh}"
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
