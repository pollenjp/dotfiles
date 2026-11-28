//! 再試行などの待ち (spec §6.6 の「待ち」)。`PJP_SLEEP_SCALE` を掛ける (突き合わせ用。0 で待たない)。

use std::ffi::OsStr;
use std::time::Duration;

/// 待ちを縮める env (0 以上の小数。読めなければ 1)。
pub const SCALE_ENV: &str = "PJP_SLEEP_SCALE";

/// `value` (`PJP_SLEEP_SCALE` の値) を倍率にする。無い・読めない・負・有限でないなら 1。
pub fn scale_from(value: Option<&OsStr>) -> f64 {
    value
        .and_then(|v| v.to_str())
        .and_then(|s| s.trim().parse::<f64>().ok())
        .filter(|s| s.is_finite() && *s >= 0.0)
        .unwrap_or(1.0)
}

/// `d` に `scale` を掛ける (大きすぎれば `Duration::MAX`)。
pub fn scaled(d: Duration, scale: f64) -> Duration {
    Duration::try_from_secs_f64(d.as_secs_f64() * scale).unwrap_or(Duration::MAX)
}

/// `d` に `PJP_SLEEP_SCALE` を掛けた長さだけ待つ。0 なら待たない。
pub fn sleep(d: Duration) {
    let d = scaled(d, scale_from(std::env::var_os(SCALE_ENV).as_deref()));
    if !d.is_zero() {
        std::thread::sleep(d);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sleep_scale_parsing() {
        assert_eq!(scale_from(None), 1.0);
        assert_eq!(scale_from(Some(OsStr::new("0"))), 0.0);
        assert_eq!(scale_from(Some(OsStr::new("0.5"))), 0.5);
        assert_eq!(scale_from(Some(OsStr::new(" 2 "))), 2.0);
        for bad in ["", "abc", "-1", "NaN", "inf"] {
            assert_eq!(scale_from(Some(OsStr::new(bad))), 1.0, "{bad:?}");
        }
    }

    #[test]
    fn scaled_durations() {
        assert_eq!(
            scaled(Duration::from_secs(1), 0.5),
            Duration::from_millis(500)
        );
        assert_eq!(scaled(Duration::from_secs(3), 0.0), Duration::ZERO);
        assert_eq!(scaled(Duration::from_secs(3), 1e300), Duration::MAX);
    }
}
