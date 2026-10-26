# nixpkgs (と flake の github input) の猶予と、期間付きの例外 (ADR 032)。書き方は nix/README.md「猶予の例外」。
#
# 読むもの:
#   nix/scripts/flake-lock-age.sh   update・check (CI の lock-age も) の日数と、日付の例外の pin
#   nix/lib/release-age.nix         home の pkgs に当てる overlay と、消し時の警告 (setup の警告のまとめ・CI の annotation)
#
# 欄の型は nix/lib/release-age.nix と flake-lock-age.sh が確かめる (知らない欄・暦に無い日付・時差の無い時刻・空の reason は止まる)。
# ほかの repo も、その flake の隣に同じ形の release-age.nix を置ける (書けるのは minimumReleaseAgeDays と exceptions.all)。
{
  # 普段の猶予 (日)。pin は、nixpkgs はチャンネルの公開から、ほかの github input は commit から、この日数たった
  # revision にする。その場だけ変えるなら flake-lock-age.sh の --min-age-days か FLAKE_MIN_RELEASE_AGE_DAYS
  # (setup では DOTFILES_MIN_RELEASE_AGE_DAYS)。
  minimumReleaseAgeDays = 7;

  # 例外。セキュリティパッチが猶予より新しい側にしか無いときに足す。reason に、なぜ要るか (CVE・待っている
  # nixpkgs の PR) を書く。date は「その時までの公開を使う」と読み、2 つの書き方がある (時差の無い時刻は止まる)。
  #
  #   "2026-10-23"                 その日 (Asia/Tokyo) の終わり (23:59:59 +09:00) まで
  #   "2026-10-23T18:20:00+09:00"  時差を書いた時刻 (RFC 3339。"2026-10-23T09:20:00Z" も同じ時刻) まで
  #
  # flake-lock-age.sh の resolve・update は公開を「2026-10-23 18:20:00 JST (09:20:00 UTC)」の形で出すので、JST の日付か、
  # 時刻に +09:00 を付けたものを写す。
  #
  # 要らなくなった項目は何もしなくなり、setup の警告のまとめと CI の annotation に「nixpkgs の例外 …」で出る。
  # 出たら PR で消す。
  exceptions = {
    # 1. 全体: nixpkgs 全体の pin を、date までの公開にする (猶予より新しいときだけ)。
    #    普段の pin が date を越えたら (おおよそ date + 猶予の日数のあと) 何もしなくなる。
    #
    #   { date = "2026-10-23"; reason = "CVE-…: openssl 3.x.y の修正が 2026-10-22 の公開に入った"; }
    all = [ ];

    # 2. 一部 (nixpkgs から): packages だけを、date までの公開の nixpkgs (flake の input
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
    fromUpstream = [
      {
        package = "mise";
        version = "2026.10.17";
        reason =
          "eMudhra の中間 CA の侵害 (CVE-2026-111943) の修正版。nixpkgs の mise は 2026.10.3 までで、"
          + "NixOS/nixpkgs#577218 (mise: 2026.10.3 -> 2026.10.17) を待つ間の一時しのぎ (2026-10-24 に足した)";
      }
    ];
  };

  # 一部の例外 (2・3) は overlay で当てるので、使えるのは「ほかの package から使われないアプリ」で、top-level の名前
  # (pkgs.<名前>) だけ。ライブラリ (openssl・nss・cacert・python3Packages.certifi など) は 1 の全体で扱う
  # (依存側が組み直されて binary cache が外れ、新旧の pin の版が混ざるため)。flake の check (release-age-state) が、
  # 差し替えた package をほかの package が使っていたら落ちる。
}
