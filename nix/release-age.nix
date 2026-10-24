# nixpkgs (と flake の github input) の猶予と、期間付きの例外 (ADR 032)。書き方は nix/README.md「猶予の例外」。
#
# 読むもの:
#   nix/scripts/flake-lock-age.sh   update・check (CI の lock-age も) の日数と、日付の例外の pin
#   nix/lib/release-age.nix         home の pkgs に当てる overlay と、消し時の警告 (setup の警告のまとめ・CI の annotation)
#
# 欄の型は nix/lib/release-age.nix が確かめる (知らない欄・暦に無い日付・空の reason は評価で止まる)。
{
  # 普段の猶予 (日)。pin は、nixpkgs はチャンネルの公開から、ほかの github input は commit から、この日数たった
  # revision にする。その場だけ変えるなら flake-lock-age.sh の --min-age-days か FLAKE_MIN_RELEASE_AGE_DAYS
  # (setup では DOTFILES_MIN_RELEASE_AGE_DAYS)。
  minimumReleaseAgeDays = 7;

  # 例外。セキュリティパッチが猶予より新しい側にしか無いときに足す。reason に、なぜ要るか (CVE・待っている
  # nixpkgs の PR) を書く。date は「この日 (Asia/Tokyo) の終わりまでの公開を使う」と読む。
  #
  # 要らなくなった項目は何もしなくなり、setup の警告のまとめと CI の annotation に「nixpkgs の例外 …」で出る。
  # 出たら PR で消す。
  exceptions = {
    # 1. 全体: nixpkgs 全体の pin を、date の日の終わりまでの公開にする (猶予より新しいときだけ)。
    #    普段の pin が date を越えたら (おおよそ date + 猶予の日数のあと) 何もしなくなる。
    #
    #   { date = "2026-10-23"; reason = "CVE-…: openssl 3.x.y の修正が 2026-10-22 の公開に入った"; }
    all = [ ];

    # 2. 一部 (nixpkgs から): packages だけを、date の日の終わりまでの公開の nixpkgs (flake の input
    #    nixpkgs-exceptions) から取る。ほかは普段の pin のまま。普段の pin が date を越えたら何もしなくなる。
    #    書いたら flake-lock-age.sh update で nixpkgs-exceptions を選び直す。
    #
    #   { packages = [ "foo" ]; date = "2026-10-23"; reason = "CVE-…: foo 1.2.3 の修正"; }
    fromNixpkgs = [ ];

    # 3. 一部 (upstream から): package を upstream の配布物から取る (nixpkgs のどの公開にも修正版がまだ無いとき)。
    #    中身は nix/pkgs/upstream/<package>.nix (version はその版と同じにする)。普段の pin の nixpkgs の版が
    #    version 以上になったら何もしなくなる。
    #
    #   { package = "mise"; version = "2026.10.17"; reason = "CVE-…: nixpkgs#… を待つ間"; }
    fromUpstream = [ ];
  };

  # 一部の例外 (2・3) は overlay で当てるので、使えるのは「ほかの package から使われないアプリ」で、top-level の名前
  # (pkgs.<名前>) だけ。ライブラリ (openssl・nss・cacert・python3Packages.certifi など) は 1 の全体で扱う
  # (依存側が組み直されて binary cache が外れ、新旧の pin の版が混ざるため)。flake の check (release-age-state) が、
  # 差し替えた package をほかの package が使っていたら落ちる。
}
