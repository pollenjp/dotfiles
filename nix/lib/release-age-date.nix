# nixpkgs の猶予の例外の date (lib/release-age.nix) の型と、その境目の時刻。書き方は 2 つ:
#
#   "YYYY-MM-DD"                 その日 (Asia/Tokyo) の終わり (23:59:59 +09:00) まで
#   "YYYY-MM-DDTHH:MM:SS+09:00"  時差を書いた RFC 3339 の timestamp。その時刻まで (時差は Z・+HH:MM・-HH:MM)
#
# 時差の無い timestamp は、どちらの時間か決まらないので型で止める。秒は要り、小数秒と小文字の t・z は受けない。
# nix/scripts/flake-lock-age.sh の bound_of と、同じ書き方・同じ時刻に保つ。
{ lib }:

let
  calendarDate = import ./calendar-date.nix { inherit lib; };
  num = lib.toIntBase10;

  # 1970-01-01 からの日数 (days from civil。3 月始まりの年で数える。flake-lock-age.sh と同じ式)
  daysFromCivil =
    y: m: d:
    let
      y' = if m <= 2 then y - 1 else y;
      era = y' / 400;
      yoe = y' - era * 400;
      mp = lib.mod (m + 9) 12;
      doy = (153 * mp + 2) / 5 + d - 1;
      doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    in
    era * 146097 + doe - 719468;

  # timestamp の欄 (date・時・分・秒と時差の符号・時・分。Z なら符号は null)。形が違えば null
  parse =
    v:
    let
      m = builtins.match "(([0-9]{4})-([0-9]{2})-([0-9]{2}))T([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|([+-])([0-9]{2}):([0-9]{2}))" v;
      at = i: builtins.elemAt m i;
      zoned = at 8 != null;
    in
    if !builtins.isString v || m == null then
      null
    else
      {
        date = at 0;
        year = num (at 1);
        month = num (at 2);
        day = num (at 3);
        hour = num (at 4);
        minute = num (at 5);
        second = num (at 6);
        # 時差 (秒)。+09:00 なら 32400
        offset =
          if zoned then (if at 8 == "-" then -1 else 1) * (num (at 9) * 3600 + num (at 10) * 60) else 0;
        offsetHour = if zoned then num (at 9) else 0;
        offsetMinute = if zoned then num (at 10) else 0;
      };

  # 時差つきの timestamp として正しいか (暦にある日付・時刻・時差)
  isTimestamp =
    v:
    let
      t = parse v;
    in
    t != null
    && calendarDate.check t.date
    && t.hour <= 23
    && t.minute <= 59
    && t.second <= 59
    && t.offsetHour <= 23
    && t.offsetMinute <= 59;

  dateParts =
    v:
    let
      m = builtins.match "([0-9]{4})-([0-9]{2})-([0-9]{2})" v;
    in
    map (i: num (builtins.elemAt m i)) [
      0
      1
      2
    ];
in
{
  type = lib.mkOptionType {
    name = "releaseAgeDate";
    description = "暦にある日付 (YYYY-MM-DD) か、時差つきの時刻 (YYYY-MM-DDTHH:MM:SS+09:00・…Z)";
    descriptionClass = "noun";
    check = v: calendarDate.check v || isTimestamp v;
    merge = lib.mergeEqualOption;
  };

  inherit isTimestamp;

  # date の境目の UNIX 秒。日付ならその日 (Asia/Tokyo) の終わり、timestamp ならその時刻。型を通った値だけを渡す
  epochOf =
    v:
    if isTimestamp v then
      let
        t = parse v;
      in
      daysFromCivil t.year t.month t.day * 86400 + t.hour * 3600 + t.minute * 60 + t.second - t.offset
    else
      let
        p = dateParts v;
      in
      daysFromCivil (builtins.elemAt p 0) (builtins.elemAt p 1) (builtins.elemAt p 2) * 86400 + 86400
      - 1
      - 9 * 3600;

  # flake の input の lastModifiedDate (commit の日時。UTC の YYYYMMDDHHMMSS) の UNIX 秒
  epochOfLastModified =
    s:
    let
      m = builtins.match "([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})" s;
      at = i: num (builtins.elemAt m i);
    in
    daysFromCivil (at 0) (at 1) (at 2) * 86400 + at 3 * 3600 + at 4 * 60 + at 5;
}
