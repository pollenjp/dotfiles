# release-age-state の偽の upstream の package (評価するだけで build しない)。nixpkgs の cowsay より新しい版で、unfree
{ lib, stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "cowsay";
  version = "99.0";
  dontUnpack = true;
  installPhase = "touch $out";
  meta.license = lib.licenses.unfree;
}
