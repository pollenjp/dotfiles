//! 日時 (spec §6.6 の「時刻」)。
//!
//! 日本時間は固定の +09:00 (夏時間が無いので tz database を引かない。ticket.py の `LOCAL_TZ` と同じ)。
//! 今の時刻は `PJP_NOW` があればその時刻 (突き合わせ用)。形は ticket.py の `parse_time` と同じく RFC 3339 の日時で、
//! オフセットが無ければ UTC とみる。

use std::ffi::OsStr;
use std::time::SystemTime;

use crate::{Error, Result};

/// 今の時刻を差し替える env (突き合わせのテスト用)。
pub const NOW_ENV: &str = "PJP_NOW";
/// 日本時間のオフセット (秒)。
pub const JST_OFFSET_SECS: i64 = 9 * 3600;

/// UNIX 時刻 (UTC の 1970-01-01 からの秒と、その中のナノ秒)。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Timestamp {
    pub secs: i64,
    pub nanos: u32,
}

/// 日本時間の暦の日時 (秒まで)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JstDateTime {
    pub year: i64,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
}

/// `YYYY-MM-DD[(T| )HH:MM[:SS[.小数]]][Z|±HH:MM|±HHMM|±HH]` を読む。オフセットが無ければ UTC。
pub fn parse_time(text: &str) -> Result<Timestamp> {
    parse(text).ok_or_else(|| {
        Error::config(format!(
            "日時として読めません: {text:?} (2026-11-15T23:10:00+09:00 の形)"
        ))
    })
}

/// 今の時刻 (`PJP_NOW` があればその時刻)。
pub fn now() -> Result<Timestamp> {
    now_from(std::env::var_os(NOW_ENV).as_deref())
}

/// `value` (`PJP_NOW` の値) があればその時刻、無い・空なら時計の今。
pub fn now_from(value: Option<&OsStr>) -> Result<Timestamp> {
    match value.filter(|v| !v.is_empty()) {
        None => Ok(Timestamp::from_system_time(SystemTime::now())),
        Some(v) => parse_time(&v.to_string_lossy())
            .map_err(|e| Error::config(format!("{NOW_ENV} を読めません: {e}"))),
    }
}

impl Timestamp {
    pub fn from_system_time(t: SystemTime) -> Timestamp {
        let whole = |secs: u64| i64::try_from(secs).unwrap_or(i64::MAX);
        match t.duration_since(SystemTime::UNIX_EPOCH) {
            Ok(d) => Timestamp {
                secs: whole(d.as_secs()),
                nanos: d.subsec_nanos(),
            },
            // 1970 年より前 (時計が狂ったマシン)
            Err(e) => {
                let d = e.duration();
                let (secs, nanos) = match d.subsec_nanos() {
                    0 => (-whole(d.as_secs()), 0),
                    n => (-whole(d.as_secs()) - 1, 1_000_000_000 - n),
                };
                Timestamp { secs, nanos }
            }
        }
    }

    /// 日本時間の暦の日時。
    pub fn to_jst(self) -> JstDateTime {
        let local = self.secs.saturating_add(JST_OFFSET_SECS);
        let (year, month, day) = civil_from_days(local.div_euclid(86_400));
        let of_day = local.rem_euclid(86_400);
        // of_day は 0..86400 なので u32 に収まる
        let of_day = u32::try_from(of_day).unwrap_or(0);
        JstDateTime {
            year,
            month,
            day,
            hour: of_day / 3600,
            minute: of_day % 3600 / 60,
            second: of_day % 60,
        }
    }
}

impl JstDateTime {
    /// `2026-11-15T23:10+09:00` (分まで。spec §7.5 の `pjp.finished` の形)。
    pub fn iso_minutes(&self) -> String {
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}+09:00",
            self.year, self.month, self.day, self.hour, self.minute
        )
    }

    /// `2026-11-15T23:10:00+09:00` (秒まで。Python の `isoformat()` と同じ形)。
    pub fn iso_seconds(&self) -> String {
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}+09:00",
            self.year, self.month, self.day, self.hour, self.minute, self.second
        )
    }
}

fn parse(text: &str) -> Option<Timestamp> {
    let b = text.as_bytes();
    let mut i = 0;
    let year = i64::from(digits(b, &mut i, 4)?);
    expect(b, &mut i, b'-')?;
    let month = digits(b, &mut i, 2)?;
    expect(b, &mut i, b'-')?;
    let day = digits(b, &mut i, 2)?;
    if !(1..=12).contains(&month) || day == 0 || day > days_in_month(year, month) {
        return None;
    }
    let (mut hour, mut minute, mut second, mut nanos) = (0, 0, 0, 0);
    let mut offset = 0;
    if i < b.len() {
        if b[i] != b'T' && b[i] != b' ' {
            return None;
        }
        i += 1;
        hour = digits(b, &mut i, 2)?;
        expect(b, &mut i, b':')?;
        minute = digits(b, &mut i, 2)?;
        if b.get(i) == Some(&b':') {
            i += 1;
            second = digits(b, &mut i, 2)?;
            if b.get(i) == Some(&b'.') {
                i += 1;
                let start = i;
                while b.get(i).is_some_and(u8::is_ascii_digit) {
                    i += 1;
                }
                if i == start {
                    return None;
                }
                // 9 桁までをナノ秒にする (それより下は切り捨てる)。小数の桁は ASCII なのでバイトで切れる
                let frac = &text[start..i.min(start + 9)];
                let width = u32::try_from(frac.len()).ok()?;
                nanos = frac.parse::<u32>().ok()? * 10u32.pow(9 - width);
            }
        }
        if hour > 23 || minute > 59 || second > 59 {
            return None;
        }
        match b.get(i) {
            None => {}
            Some(b'Z') => i += 1,
            Some(&sign @ (b'+' | b'-')) => {
                i += 1;
                let oh = digits(b, &mut i, 2)?;
                let om = match b.get(i) {
                    None => 0,
                    Some(b':') => {
                        i += 1;
                        digits(b, &mut i, 2)?
                    }
                    Some(_) => digits(b, &mut i, 2)?,
                };
                if oh > 23 || om > 59 {
                    return None;
                }
                let o = i64::from(oh * 3600 + om * 60);
                offset = if sign == b'+' { o } else { -o };
            }
            Some(_) => return None,
        }
    }
    if i != b.len() {
        return None;
    }
    let local =
        days_from_civil(year, month, day) * 86_400 + i64::from(hour * 3600 + minute * 60 + second);
    Some(Timestamp {
        secs: local - offset,
        nanos,
    })
}

/// `b[i..i+n]` の n 桁の数字を読んで、`i` を進める。
fn digits(b: &[u8], i: &mut usize, n: usize) -> Option<u32> {
    let s = b.get(*i..*i + n)?;
    if !s.iter().all(u8::is_ascii_digit) {
        return None;
    }
    *i += n;
    Some(s.iter().fold(0, |acc, d| acc * 10 + u32::from(d - b'0')))
}

fn expect(b: &[u8], i: &mut usize, c: u8) -> Option<()> {
    (b.get(*i) == Some(&c)).then(|| *i += 1)
}

/// うるう年か (グレゴリオ暦)。
pub fn is_leap(year: i64) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// その月の日数。
pub fn days_in_month(year: i64, month: u32) -> u32 {
    match month {
        2 if is_leap(year) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// 暦の日付から 1970-01-01 からの日数 (Howard Hinnant の days_from_civil)。
pub fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (i64::from(month) + 9) % 12;
    let doy = (153 * mp + 2) / 5 + i64::from(day) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// 1970-01-01 からの日数から暦の日付 (Howard Hinnant の civil_from_days)。[`days_from_civil`] の逆。
pub fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    // doy・mp は小さな正の数なので u32 に収まる
    let day = u32::try_from(doy - (153 * mp + 2) / 5 + 1).unwrap_or(1);
    let month = u32::try_from(if mp < 10 { mp + 3 } else { mp - 9 }).unwrap_or(1);
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::exit::CONFIG;

    fn jst(text: &str) -> JstDateTime {
        parse_time(text).unwrap().to_jst()
    }

    #[test]
    fn parse_time_known_epochs() {
        assert_eq!(
            parse_time("1970-01-01T00:00:00Z").unwrap(),
            Timestamp { secs: 0, nanos: 0 }
        );
        assert_eq!(
            parse_time("2000-01-01T00:00:00Z").unwrap().secs,
            946_684_800
        );
        assert_eq!(
            parse_time("2000-01-01T09:00:00+09:00").unwrap().secs,
            946_684_800
        );
    }

    #[test]
    fn parse_time_forms() {
        assert_eq!(
            jst("2026-10-17T22:19:01Z").iso_seconds(),
            "2026-10-18T07:19:01+09:00"
        );
        assert_eq!(
            jst("2026-10-17T22:19:01.000+09:00").iso_seconds(),
            "2026-10-17T22:19:01+09:00"
        );
        assert_eq!(
            jst("2026-11-15T23:10+0900").iso_minutes(),
            "2026-11-15T23:10+09:00"
        );
        assert_eq!(jst("2026-11-15").iso_minutes(), "2026-11-15T09:00+09:00");
        assert_eq!(
            jst("2026-11-15 01:02:03").iso_seconds(),
            "2026-11-15T10:02:03+09:00"
        );
        assert_eq!(
            jst("2026-11-15T01:02:03-05:30").iso_seconds(),
            "2026-11-15T15:32:03+09:00"
        );
        assert_eq!(
            jst("2026-11-15T01:02:03+09").iso_seconds(),
            "2026-11-15T01:02:03+09:00"
        );
        let t = parse_time("2026-11-15T01:02:03.123456789Z").unwrap();
        assert_eq!(t.nanos, 123_456_789);
        assert_eq!(
            parse_time("2026-11-15T01:02:03.5Z").unwrap().nanos,
            500_000_000
        );
    }

    #[test]
    fn parse_time_rejects_garbage() {
        for text in [
            "",
            "2026",
            "2026/11/15",
            "2026-13-01",
            "2026-00-10",
            "2026-02-30",
            "2026-11-15T24:00",
            "2026-11-15T23:60",
            "2026-11-15T23:10:61",
            "2026-11-15T23",
            "2026-11-15Tfoo",
            "2026-11-15T23:10:00Zjunk",
            "2026-11-15T23:10:00+9:00",
            "2026-11-15T23:10:00+24:00",
            "2026-11-15T23:10:00.",
        ] {
            let e = parse_time(text).unwrap_err();
            assert_eq!(e.code(), CONFIG, "{text:?}");
        }
    }

    #[test]
    fn jst_conversion_crosses_midnight_and_year() {
        assert_eq!(
            jst("2026-12-31T15:00:00Z").iso_minutes(),
            "2027-01-01T00:00+09:00"
        );
        assert_eq!(
            jst("2026-12-31T14:59:59Z").iso_seconds(),
            "2026-12-31T23:59:59+09:00"
        );
    }

    #[test]
    fn leap_days() {
        assert_eq!(
            jst("2028-02-29T12:00:00+09:00").iso_minutes(),
            "2028-02-29T12:00+09:00"
        );
        assert_eq!(
            jst("2000-02-29T00:00:00+09:00").iso_minutes(),
            "2000-02-29T00:00+09:00"
        );
        assert!(parse_time("2026-02-29").is_err());
        assert!(parse_time("1900-02-29").is_err());
    }

    #[test]
    fn now_honours_pjp_now() {
        let t = now_from(Some(OsStr::new("2026-11-15T23:10:00+09:00"))).unwrap();
        assert_eq!(t.to_jst().iso_minutes(), "2026-11-15T23:10+09:00");

        let e = now_from(Some(OsStr::new("yesterday"))).unwrap_err();
        assert_eq!(e.code(), CONFIG);
        assert!(e.message().contains("PJP_NOW"), "{e}");

        // 無い・空なら時計の今 (2026 年より後)
        assert!(now_from(None).unwrap().secs > 1_767_225_600);
        assert!(now_from(Some(OsStr::new(""))).unwrap().secs > 1_767_225_600);
    }

    #[test]
    fn from_system_time_keeps_nanos() {
        // Windows の SystemTime は 100 ns 刻み (FILETIME) なので、どの OS でも表せる 100 ns の倍数で見る
        let t = SystemTime::UNIX_EPOCH + std::time::Duration::new(946_684_800, 4_200);
        assert_eq!(
            Timestamp::from_system_time(t),
            Timestamp {
                secs: 946_684_800,
                nanos: 4_200
            }
        );
    }
}
