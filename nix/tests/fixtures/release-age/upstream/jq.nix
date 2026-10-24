# release-age-state の偽の upstream の package (評価するだけで build しない)。nixpkgs の jq より古い版
{ stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "jq";
  version = "1.0";
  dontUnpack = true;
  installPhase = "touch $out";
}
