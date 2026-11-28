//! ファイルの属性のうち OS で違うもの。
//!
//! Unix の権限 ([`set_mode`]・[`mode_of`]) と、Windows の DACL ([`set_owner_only`]・[`access_of`])。どの関数も両方の OS にあり、
//! 当たらない OS では何もしない (false・None)。秘密を置くファイルは、[`set_mode`] と [`set_owner_only`] の両方を呼べば OS に
//! よらず本人だけのものになる。

use std::path::Path;

/// Unix の権限 (`0o755` など) を変える。変えたら true。Windows には Unix の権限が無いので、何もせず false。
pub fn set_mode(path: &Path, mode: u32) -> std::io::Result<bool> {
    crate::sys::set_mode(path, mode)
}

/// Unix の権限 (`0o7777` の範囲。`std::fs::symlink_metadata` などで読んだもの)。Windows には無いので None。
pub fn mode_of(meta: &std::fs::Metadata) -> Option<u32> {
    crate::sys::mode_of(meta)
}

/// Windows のファイル・ディレクトリを本人だけのものにする。保護した DACL (親から継ぐ ACE を外す) に、この process の user の
/// フルコントロールを 1 つだけ置く (Unix の 600・700 に当たる)。`inherit` なら、その ACE を中に作るファイルとディレクトリへ
/// 継がせる (ディレクトリ向け)。所有者は変えない。変えたら true。Unix は何もせず false (権限は [`set_mode`])。
pub fn set_owner_only(path: &Path, inherit: bool) -> std::io::Result<bool> {
    crate::sys::set_owner_only(path, inherit)
}

/// Windows のファイルの DACL で、読む権利を許された相手 (symlink は指す先を見る)。Unix は None (権限は [`mode_of`])。
pub fn access_of(path: &Path) -> Option<std::io::Result<Access>> {
    crate::sys::access_of(path)
}

/// SYSTEM (LocalSystem) の SID。
pub const SID_SYSTEM: &str = "S-1-5-18";
/// BUILTIN\Administrators の SID。
pub const SID_ADMINISTRATORS: &str = "S-1-5-32-544";
/// CREATOR OWNER の SID (作った人に継がせる印。数えない)。
pub const SID_CREATOR_OWNER: &str = "S-1-3-0";
/// OWNER RIGHTS の SID (持ち主のこと。持ち主の SID として見る)。
pub const SID_OWNER_RIGHTS: &str = "S-1-3-4";

/// 許可の相手の種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Who {
    /// この process の user (本人)。
    Me,
    /// SYSTEM ([`SID_SYSTEM`])。
    System,
    /// BUILTIN\Administrators ([`SID_ADMINISTRATORS`])。
    Administrators,
    /// ほか (Everyone・BUILTIN\Users・ほかの user など)。
    Other,
}

/// 許可の相手。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trustee {
    /// SID の文字列 (`S-1-5-32-545`)。
    pub sid: String,
    /// 名前 (`BUILTIN\Users`・`Everyone`)。引けなければ None。
    pub name: Option<String>,
    pub who: Who,
}

impl Trustee {
    /// 表示の名前 (引けなければ SID)。
    pub fn shown(&self) -> &str {
        self.name.as_deref().unwrap_or(&self.sid)
    }
}

/// DACL の ACE 1 つ ([`Access::from_aces`] に渡す形)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ace {
    /// ACE の種類 (winnt.h の `ACCESS_ALLOWED_ACE_TYPE` など)。
    pub ace_type: u8,
    /// ACE の flag (`INHERIT_ONLY_ACE` など)。
    pub flags: u8,
    /// 権利のビット (`FILE_READ_DATA` など)。
    pub mask: u32,
    /// 相手の SID の文字列。
    pub sid: String,
    /// 相手の名前 (引けなければ None)。
    pub name: Option<String>,
}

/// Windows のファイルの DACL のうち、読む権利を許す ACE の相手。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Access {
    /// 許可の相手 (DACL の順、同じ SID は最初の 1 つ)。None は DACL が無い (誰でも何でもできる)。
    pub allowed: Option<Vec<Trustee>>,
}

// winnt.h の値。windows-sys は Windows でしか入らないので、判定を OS によらずテストできるよう写す
/// 許可の ACE。
pub(crate) const ACCESS_ALLOWED_ACE_TYPE: u8 = 0x0;
/// 条件つきの許可の ACE (並びは ACCESS_ALLOWED_ACE と同じ)。
pub(crate) const ACCESS_ALLOWED_CALLBACK_ACE_TYPE: u8 = 0x9;
/// 継ぐだけで、その物には効かない ACE の flag。
const INHERIT_ONLY_ACE: u8 = 0x8;
/// 読む権利: 中身を読む (FILE_READ_DATA)・generic の読む・全部 (GENERIC_READ・GENERIC_ALL)。フルコントロール・読み取りは
/// FILE_READ_DATA を含む。書くだけ・属性を読む・READ_CONTROL・SYNCHRONIZE だけの ACE は数えない (dotfiles の Windows の runner の
/// 知らせと同じ見方)。
const READ_RIGHTS: u32 = 0x0000_0001 | 0x8000_0000 | 0x1000_0000;

impl Access {
    /// DACL の ACE から作る (`aces` が None は DACL が無い)。許可の ACE (継ぐだけのものを除く) のうち、読む権利を許すものの相手を、
    /// DACL の順に重なりを除いて並べる。CREATOR OWNER は数えず、OWNER RIGHTS は持ち主 (`owner` の SID と名前。分からなければ
    /// OWNER RIGHTS のまま、ほかの相手) として見る。拒否の ACE は差し引かない (広く見積もる)。`me` はこの process の user の SID。
    pub fn from_aces(
        me: &str,
        owner: Option<(&str, Option<&str>)>,
        aces: Option<Vec<Ace>>,
    ) -> Access {
        let Some(aces) = aces else {
            return Access { allowed: None };
        };
        let mut allowed: Vec<Trustee> = Vec::new();
        for a in aces {
            let allow = matches!(
                a.ace_type,
                ACCESS_ALLOWED_ACE_TYPE | ACCESS_ALLOWED_CALLBACK_ACE_TYPE
            );
            if !allow
                || a.flags & INHERIT_ONLY_ACE != 0
                || a.mask & READ_RIGHTS == 0
                || a.sid.eq_ignore_ascii_case(SID_CREATOR_OWNER)
            {
                continue;
            }
            let (sid, name) = match owner {
                Some((o, n)) if a.sid.eq_ignore_ascii_case(SID_OWNER_RIGHTS) => {
                    (o.to_owned(), n.map(str::to_owned))
                }
                _ => (a.sid, a.name),
            };
            if allowed.iter().any(|t| t.sid.eq_ignore_ascii_case(&sid)) {
                continue;
            }
            let who = if sid.eq_ignore_ascii_case(me) {
                Who::Me
            } else if sid.eq_ignore_ascii_case(SID_SYSTEM) {
                Who::System
            } else if sid.eq_ignore_ascii_case(SID_ADMINISTRATORS) {
                Who::Administrators
            } else {
                Who::Other
            };
            allowed.push(Trustee { sid, name, who });
        }
        Access {
            allowed: Some(allowed),
        }
    }

    /// 本人だけ (読む権利を許す相手がこの process の user ひとり)。
    pub fn owner_only(&self) -> bool {
        matches!(&self.allowed, Some(v) if v.len() == 1 && v[0].who == Who::Me)
    }

    /// 本人・SYSTEM・Administrators のほかの、読む権利を許す相手 (Unix の group・other の権限に当たる)。DACL が無いときは空
    /// ([`Access::wide`] で見る)。
    pub fn others(&self) -> Vec<&Trustee> {
        self.allowed
            .iter()
            .flatten()
            .filter(|t| t.who == Who::Other)
            .collect()
    }

    /// 本人・SYSTEM・Administrators のほかにも読める (DACL が無いときも)。SYSTEM と Administrators は Unix の root に当たり、600 でも
    /// 除けないので数えない。
    pub fn wide(&self) -> bool {
        self.allowed.is_none() || !self.others().is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    const ME: &str = "S-1-5-21-1111111111-2222222222-3333333333-1001";
    const USERS: &str = "S-1-5-32-545";
    const EVERYONE: &str = "S-1-1-0";
    /// FILE_ALL_ACCESS。
    const FA: u32 = 0x001F_01FF;

    fn ace(ace_type: u8, flags: u8, mask: u32, sid: &str) -> Ace {
        Ace {
            ace_type,
            flags,
            mask,
            sid: sid.to_owned(),
            name: None,
        }
    }

    fn sids(a: &Access) -> Vec<(&str, Who)> {
        a.allowed
            .iter()
            .flatten()
            .map(|t| (t.sid.as_str(), t.who))
            .collect()
    }

    #[test]
    fn set_mode_applies_on_unix_only() {
        let t = TempDir::new("set-mode");
        let p = t.write("f", "x");
        let changed = set_mode(&p, 0o600).unwrap();
        assert_eq!(changed, cfg!(unix));
    }

    #[test]
    fn mode_of_reads_what_set_mode_wrote_on_unix_only() {
        let t = TempDir::new("mode-of");
        let p = t.write("f", "x");
        set_mode(&p, 0o640).unwrap();
        let got = mode_of(&std::fs::metadata(&p).unwrap());
        assert_eq!(got, cfg!(unix).then_some(0o640));
    }

    #[test]
    fn owner_only_and_access_are_windows_only() {
        let t = TempDir::new("owner-only");
        let p = t.write("f", "x");
        assert_eq!(set_owner_only(&p, false).unwrap(), cfg!(windows));
        let got = access_of(&p);
        assert_eq!(got.is_some(), cfg!(windows));
        if let Some(a) = got {
            let a = a.unwrap();
            assert!(a.owner_only(), "{a:?}");
            assert!(!a.wide(), "{a:?}");
        }
    }

    #[test]
    fn me_alone_is_owner_only() {
        let a = Access::from_aces(ME, None, Some(vec![ace(0, 0, FA, ME)]));
        assert!(a.owner_only());
        assert!(!a.wide());
        assert!(a.others().is_empty());
    }

    #[test]
    fn system_and_administrators_are_not_wide() {
        // %USERPROFILE% の下に継がれる ACL の形 (継いだ ACE は flag 0x10)
        let a = Access::from_aces(
            ME,
            None,
            Some(vec![
                ace(0, 0x10, FA, SID_SYSTEM),
                ace(0, 0x10, FA, SID_ADMINISTRATORS),
                ace(0, 0x10, FA, ME),
            ]),
        );
        assert_eq!(
            sids(&a),
            vec![
                (SID_SYSTEM, Who::System),
                (SID_ADMINISTRATORS, Who::Administrators),
                (ME, Who::Me)
            ]
        );
        assert!(!a.owner_only());
        assert!(!a.wide());
    }

    #[test]
    fn other_principals_and_a_missing_dacl_are_wide() {
        let a = Access::from_aces(
            ME,
            None,
            Some(vec![
                ace(0, 0, FA, ME),
                Ace {
                    name: Some("BUILTIN\\Users".into()),
                    ..ace(0, 0, 0x0012_0089, USERS) // FILE_GENERIC_READ
                },
                ace(9, 0, 0x8000_0000, EVERYONE), // 条件つきの許可の GENERIC_READ も数える
            ]),
        );
        assert!(a.wide());
        let others: Vec<&str> = a.others().iter().map(|t| t.shown()).collect();
        assert_eq!(others, vec!["BUILTIN\\Users", EVERYONE]);

        let none = Access::from_aces(ME, None, None);
        assert!(none.wide());
        assert!(!none.owner_only());
        assert!(none.others().is_empty());
    }

    #[test]
    fn deny_inherit_only_creator_owner_and_rights_without_reading_are_not_counted() {
        let lower = ME.to_lowercase();
        let a = Access::from_aces(
            ME,
            None,
            Some(vec![
                ace(1, 0, FA, EVERYONE),          // 拒否の ACE は差し引かず、相手にも数えない
                ace(0, 0x0b, FA, USERS),          // 継ぐだけ (OI|CI|IO)
                ace(0, 0, FA, SID_CREATOR_OWNER), // CREATOR OWNER
                ace(0, 0, 0x0012_0080, EVERYONE), // 属性を読む・READ_CONTROL・SYNCHRONIZE だけ
                ace(0, 0, 0x0016_0116, EVERYONE), // 書く・WRITE_DAC だけ (FILE_GENERIC_WRITE | WRITE_DAC)
                ace(0, 0, 0x8000_0000, "S-1-5-32-546"), // GENERIC_READ は数える
                ace(0, 0, 0x1000_0000, "S-1-5-11"), // GENERIC_ALL も数える
                ace(0, 0, FA, &lower),            // SID の大文字小文字は見ない
                ace(0, 0, FA, ME),                // 同じ SID は 1 つ
            ]),
        );
        assert_eq!(
            sids(&a),
            vec![
                ("S-1-5-32-546", Who::Other),
                ("S-1-5-11", Who::Other),
                (lower.as_str(), Who::Me)
            ]
        );
        assert!(a.wide());
    }

    #[test]
    fn owner_rights_is_seen_as_the_owner() {
        let aces = || {
            Some(vec![
                ace(0, 0, FA, ME),
                ace(0, 0, 0x0012_0089, SID_OWNER_RIGHTS),
            ])
        };
        // 持ち主が本人なら、本人と同じ (本人だけ)
        let a = Access::from_aces(ME, Some((ME, Some("PC\\me"))), aces());
        assert!(a.owner_only(), "{a:?}");
        // 持ち主が Administrators なら Administrators
        let a = Access::from_aces(ME, Some((SID_ADMINISTRATORS, None)), aces());
        assert_eq!(
            sids(&a),
            vec![(ME, Who::Me), (SID_ADMINISTRATORS, Who::Administrators)]
        );
        assert!(!a.wide());
        // 持ち主がほかの user なら、ほかの相手 (名前は持ち主の名前)
        let other = "S-1-5-21-1111111111-2222222222-3333333333-1002";
        let a = Access::from_aces(ME, Some((other, Some("PC\\guest"))), aces());
        assert!(a.wide());
        assert_eq!(a.others()[0].shown(), "PC\\guest");
        // 持ち主が分からなければ OWNER RIGHTS のまま、ほかの相手
        let a = Access::from_aces(ME, None, aces());
        assert_eq!(a.others()[0].sid, SID_OWNER_RIGHTS);
    }
}
