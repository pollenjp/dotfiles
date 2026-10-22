# 自前の証明書の束を持つツールにも OS の信頼ストア (/etc/ssl/certs/ca-certificates.crt) を読ませる
# 環境変数 4 つを、Linux のホストの session で export する (ADR 028)。
#
# ## なぜ要るのか
#
# OpenSSL と Go はもともと OS の束を読むので、OS の束から危ない CA を外せば (NixOS は nixos-config の
# security.pki.caCertificateBlacklist、Ubuntu は ca-certificates の更新) 揃って拒否するようになる。
# 次のツールは自前の束を持つので、OS の束を直しても信頼したまま残る。2026-10 の eMudhra の中間 CA の侵害
# (CVE-2026-111943) では、OS の束を直した lavie でもテスト用ホストに繋がった。
#
#   NIX_SSL_CERT_FILE                   nixpkgs の python の certifi (nixpkgs の certifi は、この変数があればその束を返す)
#   SSL_CERT_FILE                       uv (既定は中に持つ webpki-roots)
#   REQUESTS_CA_BUNDLE                  venv に入れた PyPI の requests (PyPI の certifi の束)
#   CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE  gcloud (SDK の中の certifi の束。gcloud の設定の core/custom_ca_certs_file)
#
# 4 つとも OS の束に向けておけば、次に同じことが起きても OS の束を直すだけでこれらも揃って直る。
#
# ## 入れ方
#
#   - Linux だけ。macOS にはこのパスが無い
#   - OS の束があるときだけ入れる。無いホスト (ca-certificates を入れていないコンテナ・Fedora 系) で入れると、
#     nix 自身を含めて TLS が通らなくなる。Nix の installer が置く profile の script も、NIX_SSL_CERT_FILE を
#     束があるときだけ立てる
#   - すでに束を指している変数があれば、残りをそれに揃える (SSL_CERT_FILE、無ければ NIX_SSL_CERT_FILE の値。
#     どちらも無ければ OS の束)。値がある (空でない) 変数は書き換えない。OS や管理者が別の束 (社内の CA を
#     足したものなど) を指しているときに壊さず、ツールごとに違う束を読むこともないようにするため。
#     nixpkgs の OpenSSL は NIX_SSL_CERT_FILE を SSL_CERT_FILE より先に読むので、SSL_CERT_FILE を残して
#     NIX_SSL_CERT_FILE だけ OS の束にすると、残したつもりの SSL_CERT_FILE が nixpkgs の OpenSSL に届かない
#
# home.sessionVariables には条件を書けないので、hm-session-vars.sh の末尾 (home.sessionVariablesExtra) に shell の
# if として書く。bash は ~/.profile (login の shell) がこれを読み、fish は config.fish (すべての fish) が、babelfish で
# fish に直したもの (hm-session-vars.fish) を読む。ホストの module の home.sessionVariables は同じファイルの
# この前で export されるので、そこに書いた SSL_CERT_FILE には残りが揃う。
#
# ## 入れる変数を選ぶ (home/options.nix の dotfiles.osCaBundle)
#
#   enable = true・requestsCaBundle.enable = true (既定)   4 つとも入れる
#   enable = true・requestsCaBundle.enable = false          REQUESTS_CA_BUNDLE 以外の 3 つを入れる
#   enable = false                                          入れない
#
# REQUESTS_CA_BUNDLE だけを外せるのは、requests がこれをアプリが Session に置いた verify より先に使い、
# それに頼る script を動かすホストがありうるため。
#
# hm-session-vars は 1 つの session で 1 回しか読まない (__HM_SESS_VARS_SOURCED を子へ継ぐ)。switch の前から
# 続いている process (herdr の server など) の下で開いた shell には入らない。反映のしかた・効かないところ
# (cacert を含む devShell の中など)・副作用は nix/README.md の「証明書の束を OS の信頼ストアに寄せる」。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.osCaBundle;
  bundle = "/etc/ssl/certs/ca-certificates.crt";

  # if の中で export する行。SSL_CERT_FILE を先に決め、残りをそれに揃える
  exports = [
    ''export SSL_CERT_FILE="''${SSL_CERT_FILE:-''${NIX_SSL_CERT_FILE:-${bundle}}}"''
    ''export NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"''
  ]
  ++ lib.optional cfg.requestsCaBundle.enable ''export REQUESTS_CA_BUNDLE="''${REQUESTS_CA_BUNDLE:-$SSL_CERT_FILE}"''
  ++ [
    ''export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="''${CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE:-$SSL_CERT_FILE}"''
  ];
in
{
  home.sessionVariablesExtra = lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && cfg.enable) ''
    if [ -f ${bundle} ]; then
    ${lib.concatMapStrings (l: "  ${l}\n") exports}fi
  '';
}
