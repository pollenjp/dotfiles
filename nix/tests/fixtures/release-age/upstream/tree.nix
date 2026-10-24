# release-age-state の偽の upstream の package (評価するだけで build しない)。nixpkgs の tree より新しい版だが、
# どの system の配布物も無い (meta.platforms が空)
{ stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "tree";
  version = "99.0";
  dontUnpack = true;
  installPhase = "touch $out";
  meta.platforms = [ ];
}
