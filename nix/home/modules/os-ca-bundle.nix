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
#   - すでに値がある (空でない) 変数は触らない。OS や管理者が別の束 (社内の CA を足したものなど) を指して
#     いるときに、壊さないため
#
# home.sessionVariables には条件を書けないので、hm-session-vars.sh の末尾 (home.sessionVariablesExtra) に shell の
# if として書く。bash は ~/.profile (login の shell) がこれを読み、fish は config.fish (すべての fish) が、babelfish で
# fish に直したもの (hm-session-vars.fish) を読む。
#
# hm-session-vars は 1 つの session で 1 回しか読まない (__HM_SESS_VARS_SOURCED を子へ継ぐ)。switch の前から
# 続いている process (herdr の server など) の下で開いた shell には入らない。反映のしかたは nix/README.md の
# 「証明書の束を OS の信頼ストアに寄せる」。
{ lib, pkgs, ... }:

let
  bundle = "/etc/ssl/certs/ca-certificates.crt";
in
{
  home.sessionVariablesExtra = lib.mkIf pkgs.stdenv.hostPlatform.isLinux ''
    if [ -f ${bundle} ]; then
      export NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-${bundle}}"
      export SSL_CERT_FILE="''${SSL_CERT_FILE:-${bundle}}"
      export REQUESTS_CA_BUNDLE="''${REQUESTS_CA_BUNDLE:-${bundle}}"
      export CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE="''${CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE:-${bundle}}"
    fi
  '';
}
