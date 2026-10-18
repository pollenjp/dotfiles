# GitHub との通信を gh の資格情報 (HTTPS) で通す git の設定 (dotfiles.claude.gitViaGh.enable)。
#
# 1 組が git の `-c <k>=<v>`、または GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> の 1 対になる (並びもこのまま)。
#
#   url.https://github.com/.insteadOf      GitHub の ssh の URL を https に読み替える (fetch と push の両方)。
#                                          origin の URL は書き換えず、使うときだけ読み替わる
#   credential.https://github.com.helper   資格情報を gh の token から取る
#
# 読むのは 2 か所で、どちらも同じ組で GitHub へ通す:
#
#   home/modules/claude.nix  Claude のセッションの env (~/.claude/settings.json) へ写す
#   pkgs/git-gh              自分のターミナルの git gh が -c で付ける (fetch 系の abbr / alias が使う)
#
# nixpkgs を引かずに読めるよう、ただの値にしている。
[
  {
    k = "url.https://github.com/.insteadOf";
    v = "git@github.com:";
  }
  {
    k = "url.https://github.com/.insteadOf";
    v = "ssh://git@github.com/";
  }
  {
    k = "credential.https://github.com.helper";
    v = "!gh auth git-credential";
  }
]
