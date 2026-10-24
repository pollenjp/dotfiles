# release-age-state の偽の upstream の package (評価するだけで build しない)。nixpkgs の hello より新しい版
{ stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "hello";
  version = "99.0";
  dontUnpack = true;
  installPhase = "touch $out";
}
