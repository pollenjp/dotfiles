# 暦にある日付 (YYYY-MM-DD) の option の型。dotfiles.mise.releaseAgeOverrides の from (home/options.nix) と、
# nixpkgs の猶予の例外の date (lib/release-age.nix) が使う。形だけでなく、2026-02-30 のような無い日も止める
# (nix/scripts/bootstrap-mise.sh の jq は、無い日を黙って翌月へ繰り越すため)
{ lib }:

lib.mkOptionType {
  name = "calendarDate";
  description = "暦にある日付 (YYYY-MM-DD)";
  descriptionClass = "noun";
  check =
    v:
    let
      m = builtins.match "([0-9]{4})-([0-9]{2})-([0-9]{2})" v;
      num = i: lib.toIntBase10 (builtins.elemAt m i);
      year = num 0;
      month = num 1;
      day = num 2;
      leap = lib.mod year 4 == 0 && (lib.mod year 100 != 0 || lib.mod year 400 == 0);
      lengths = [
        31
        (if leap then 29 else 28)
        31
        30
        31
        30
        31
        31
        30
        31
        30
        31
      ];
    in
    builtins.isString v
    && m != null
    && month >= 1
    && month <= 12
    && day >= 1
    && day <= builtins.elemAt lengths (month - 1);
  merge = lib.mergeEqualOption;
}
