//! ディスプレイへのあて方の段 (`applied-layouts.json`。WSL の `assign_layouts` を写したもの)。モニター × 仮想デスクトップの組へ、解像度の決まり
//! (`layout-rules.json`。今の表示の解像度がちょうど一致した rules の layout、どれにも当たらなければ default) のレイアウトをあて、組の無い仮想
//! デスクトップには組を作る (dotfiles-private の docs/adr/053_*・054_*)。
//!
//! - ディスプレイの DeviceID と今の表示の解像度、Windows の仮想デスクトップの一覧は、WSL と同じ PowerShell の本文 (`PS_BODY`) を Windows
//!   PowerShell の `-EncodedCommand` で流して聞く (FancyZones の MonitorUtils.cpp・VirtualDesktop.cpp と同じ手順)。組があれば毎回聞く
//! - 組の monitor が同じで、monitor-instance が同じか、違えば monitor-number が同じディスプレイに合わせる。シリアルは見ない
//! - 組ごとに (目標 = そのディスプレイの解像度から決まりで決めたレイアウト):
//!
//!   | 組 | すること |
//!   | --- | --- |
//!   | 合うディスプレイが無い・縦向き | 触らない (`--force` でも) |
//!   | 目標と同じカスタムレイアウト | 何もしない (記録が無ければ記録だけする) |
//!   | テンプレートのまま (blank を除く) | 目標にする |
//!   | 前にこの段があてたまま (記録と同じ) | 目標にする (決まりや解像度を変えたとき) |
//!   | 横向きの既定 (決まりの default) で記録と違う | 目標にする |
//!   | 手であてたカスタムレイアウト・blank・知らない type | 残して知らせる (`--force` なら目標にする) |
//!   | 目標のレイアウトが PC に無い (か canvas でない) | 飛ばして知らせる |
//!
//! - 組を作る: つながっている横向きのディスプレイごとに、同じ画面の組をシリアルごとに分け、今の番号の組が無い仮想デスクトップへ組を作る (device は
//!   同じ画面の組から写し、monitor-number と virtual-desktop だけを替える)
//! - あてた中身は記録 (`windows-fancyzones.assigned.json`。キーにシリアルを入れない) に組ごとに持つ

use super::layouts::{layouts_problems, lookup, pc_tables, rules_problems, usable_layout};
use super::{Fz, LAYOUTS_REL, RULES_REL, pt_form, read_retry, row, warn};
use crate::context::Ctx;
use crate::jv::{self, Jv, Num};
use crate::report::Kind;
use crate::steps::{Mode, ps1};
use std::cmp::Ordering;
use std::time::Duration;

/// ディスプレイと仮想デスクトップを聞く PowerShell の本文 (WSL の `ps_body` と同じ字。ASCII だけ)
pub const PS_BODY: &str = r#"$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DotfilesFancyZonesDisplays {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion;
    public short dmDriverVersion;
    public short dmSize;
    public short dmDriverExtra;
    public int dmFields;
    public int dmPositionX;
    public int dmPositionY;
    public int dmDisplayOrientation;
    public int dmDisplayFixedOutput;
    public short dmColor;
    public short dmDuplex;
    public short dmYResolution;
    public short dmTTOption;
    public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel;
    public int dmPelsWidth;
    public int dmPelsHeight;
    public int dmDisplayFlags;
    public int dmDisplayFrequency;
    public int dmICMMethod;
    public int dmICMIntent;
    public int dmMediaType;
    public int dmDitherType;
    public int dmReserved1;
    public int dmReserved2;
    public int dmPanningWidth;
    public int dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumDisplayDevicesW(string lpDevice, int iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, int dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumDisplaySettingsW(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);
  public class Display {
    public string Device { get; set; }
    public string Id { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
  }
  // DISPLAY_DEVICE_ATTACHED_TO_DESKTOP (adapter) and DISPLAY_DEVICE_ACTIVE (monitor) are 0x1,
  // DISPLAY_DEVICE_MIRRORING_DRIVER is 0x8, EDD_GET_DEVICE_INTERFACE_NAME is 0x1, ENUM_CURRENT_SETTINGS is -1.
  public static Display[] Get() {
    var list = new List<Display>();
    for (int i = 0; ; i++) {
      var adapter = new DISPLAY_DEVICE();
      adapter.cb = Marshal.SizeOf(adapter);
      if (!EnumDisplayDevicesW(null, i, ref adapter, 0)) { break; }
      if ((adapter.StateFlags & 0x1) == 0 || (adapter.StateFlags & 0x8) != 0) { continue; }
      var mode = new DEVMODE();
      mode.dmSize = (short)Marshal.SizeOf(mode);
      if (!EnumDisplaySettingsW(adapter.DeviceName, -1, ref mode)) { continue; }
      for (int j = 0; ; j++) {
        var monitor = new DISPLAY_DEVICE();
        monitor.cb = Marshal.SizeOf(monitor);
        if (!EnumDisplayDevicesW(adapter.DeviceName, j, ref monitor, 0x1)) { break; }
        if ((monitor.StateFlags & 0x1) == 0 || (monitor.StateFlags & 0x8) != 0) { continue; }
        list.Add(new Display { Device = adapter.DeviceName, Id = monitor.DeviceID, Width = mode.dmPelsWidth, Height = mode.dmPelsHeight });
        break;
      }
    }
    return list.ToArray();
  }
}
'@
$displays = @([DotfilesFancyZonesDisplays]::Get() | ForEach-Object {
  [ordered]@{ device = $_.Device; id = $_.Id; width = $_.Width; height = $_.Height }
})
$desktops = @()
$vd = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops' -Name 'VirtualDesktopIDs' -ErrorAction SilentlyContinue
if ($null -ne $vd -and $vd.VirtualDesktopIDs -is [byte[]]) {
  $raw = $vd.VirtualDesktopIDs
  for ($i = 0; $i + 16 -le $raw.Length; $i += 16) {
    $desktops += [System.Guid]::new([byte[]]($raw[$i..($i + 15)])).ToString('B').ToUpperInvariant()
  }
}
ConvertTo-Json -Compress -Depth 3 -InputObject ([ordered]@{ displays = $displays; desktops = $desktops })"#;
/// 聞くのを待つ上限 (WSL の `timeout 60`)
pub const PS_SECS: u64 = 60;

/// 書く判定 (組を決まりのレイアウトにする)
const WRITES: [Action; 4] = [
    Action::Fill,
    Action::Retarget,
    Action::Default,
    Action::Force,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Untouched,
    Same,
    Fill,
    Retarget,
    Default,
    Force,
    Kept,
    Missing,
}

/// つながっているディスプレイ (FancyZones と同じ形)
#[derive(Clone, Debug)]
struct Display {
    monitor: String,
    instance: String,
    number: Jv,
    width: Jv,
    height: Jv,
}

impl Display {
    fn landscape(&self) -> bool {
        jv::jq_cmp(&self.height, &self.width) != Ordering::Greater
    }

    fn resolution(&self) -> String {
        format!("{}x{}", self.width.tostring(), self.height.tostring())
    }
}

/// 組 1 つの計画
#[derive(Clone, Debug)]
struct Planned {
    i: usize,
    key: Option<String>,
    action: Action,
    target: Jv,
    tname: String,
    label: String,
    before: String,
    note: &'static str,
    new_al: Option<Jv>,
}

impl Planned {
    fn write(&self) -> bool {
        WRITES.contains(&self.action)
    }
}

/// 作る組の計画
#[derive(Clone, Debug)]
struct Created {
    device: Jv,
    key: String,
    target: Jv,
    label: String,
    write: bool,
    record: bool,
    new_al: Option<Jv>,
    tname: String,
    note: &'static str,
}

/// 組が読める形か (object で、device (monitor が文字列) と applied-layout が object。jq の `well_formed`)
fn well_formed(e: &Jv) -> bool {
    e.is_object()
        && matches!(e.get("device"), Some(Jv::Object(_)))
        && matches!(
            e.get("device").and_then(|d| d.get("monitor")),
            Some(Jv::String(_))
        )
        && matches!(e.get("applied-layout"), Some(Jv::Object(_)))
}

fn dev<'a>(e: &'a Jv, key: &str) -> &'a Jv {
    e.get("device")
        .and_then(|d| d.get(key))
        .unwrap_or(&Jv::Null)
}

/// 記録のキー (monitor|monitor-instance|monitor-number|virtual-desktop。シリアルは入れない。jq の `entry_key`)
fn entry_key(e: &Jv) -> String {
    format!(
        "{}|{}|{}|{}",
        dev(e, "monitor").tostring(),
        dev(e, "monitor-instance").tostring(),
        dev(e, "monitor-number").tostring(),
        dev(e, "virtual-desktop").tostring()
    )
}

fn al_field<'a>(e: &'a Jv, key: &str) -> &'a Jv {
    e.get("applied-layout")
        .and_then(|a| a.field(key))
        .unwrap_or(&Jv::Null)
}

/// テンプレートのまま (blank を除く。jq の `is_template`)
fn is_template(e: &Jv) -> bool {
    let t = al_field(e, "type");
    ["focus", "columns", "rows", "grid", "priority-grid"]
        .iter()
        .any(|x| jv::jq_eq(t, &Jv::from(*x)))
}

/// この段が前にあてたまま (jq の `is_recorded`)
fn is_recorded(e: &Jv, asg: &Jv) -> bool {
    jv::jq_eq(al_field(e, "type"), &Jv::from("custom"))
        && matches!(al_field(e, "uuid"), Jv::String(_))
        && jv::jq_eq(
            asg.field(&entry_key(e)).unwrap_or(&Jv::Null),
            al_field(e, "uuid"),
        )
}

/// 組の判定 (jq の `base_action`)
fn base_action(e: &Jv, target: &Jv, asg: &Jv, default_uuid: &Jv, force: bool) -> Action {
    let custom = jv::jq_eq(al_field(e, "type"), &Jv::from("custom"));
    if custom && jv::jq_eq(al_field(e, "uuid"), target) {
        Action::Same
    } else if is_template(e) {
        Action::Fill
    } else if is_recorded(e, asg) {
        Action::Retarget
    } else if custom && jv::jq_eq(al_field(e, "uuid"), default_uuid) {
        Action::Default
    } else if force {
        Action::Force
    } else {
        Action::Kept
    }
}

/// applied-layout の名前 (カスタムなら PC のレイアウトの名前、テンプレートと blank は type。jq の `layout_label`)
fn layout_label(al: &Jv, by_uuid: &[(String, Jv)]) -> String {
    let t = al.field("type").unwrap_or(&Jv::Null);
    if jv::jq_eq(t, &Jv::from("custom")) {
        let u = al.field("uuid").unwrap_or(&Jv::Null);
        match lookup(by_uuid, &u.tostring()).and_then(|l| l.field("name")) {
            Some(n) if !matches!(n, Jv::Null | Jv::Bool(false)) => n.tostring(),
            _ => format!("カスタム {}", u.tostring()),
        }
    } else {
        t.tostring()
    }
}

/// PC のレイアウトを組にあてるときの applied-layout (エディターが canvas のカスタムをあてたときと同じ値。jq の `applied_value`)
fn applied_value(pl: &Jv, uuid: &Jv) -> Jv {
    let info = pl.get("info");
    let zones = info
        .and_then(|i| i.get("zones"))
        .and_then(Jv::as_array)
        .map(Vec::len)
        .unwrap_or(0);
    let radius = match info.and_then(|i| i.get("sensitivity-radius")) {
        Some(n @ Jv::Number(_)) => n.clone(),
        _ => Jv::from(20),
    };
    Jv::Object(vec![
        ("uuid".into(), uuid.clone()),
        ("type".into(), Jv::from("custom")),
        ("show-spacing".into(), Jv::Bool(false)),
        ("spacing".into(), Jv::from(0)),
        ("zone-count".into(), Jv::from(zones as i64)),
        ("sensitivity-radius".into(), radius),
    ])
}

/// `split("&") | last` を文字列の中に埋めた字 (jq は空の文字列を空の配列に分けるので、last は null で "null" になる)
fn last_amp(s: &str) -> &str {
    if s.is_empty() {
        return "null";
    }
    s.rsplit('&').next().unwrap_or(s)
}

/// `ltrimstr("{") | .[0:8]`
fn vd8(s: &str) -> String {
    s.strip_prefix('{').unwrap_or(s).chars().take(8).collect()
}

/// PowerShell の返りを、FancyZones と同じ形 (DeviceID を # で分けた monitor・monitor-instance と、`\\.\DISPLAY<n>` の n) にする。形の合わない
/// ディスプレイは落とす (jq の `parse_displays`)
fn parse_displays(ps: &Jv) -> Vec<Display> {
    let zero = Jv::from(0);
    ps.get("displays")
        .and_then(Jv::as_array)
        .map(|a| {
            a.iter()
                .filter(|d| d.is_object())
                .filter_map(|d| {
                    let device = d.get("device")?.as_str()?;
                    let id = d.get("id")?.as_str()?;
                    let (w, h) = (d.get("width")?, d.get("height")?);
                    if !matches!(w, Jv::Number(_)) || !matches!(h, Jv::Number(_)) {
                        return None;
                    }
                    if jv::jq_cmp(w, &zero) != Ordering::Greater
                        || jv::jq_cmp(h, &zero) != Ordering::Greater
                    {
                        return None;
                    }
                    let parts: Vec<&str> = id.split('#').collect();
                    // match("DISPLAY([0-9]+)$") (末尾の改行 1 つの前でも合う)
                    let s = jv::anchored(device);
                    let digits = s.bytes().rev().take_while(u8::is_ascii_digit).count();
                    let (head, num) = s.split_at(s.len() - digits);
                    if parts.len() < 4 || digits == 0 || !head.ends_with("DISPLAY") {
                        return None;
                    }
                    let number: i64 = num.parse().ok()?;
                    Some(Display {
                        monitor: parts[1].to_string(),
                        instance: parts[2].to_string(),
                        number: Jv::Number(Num::int(number)),
                        width: w.clone(),
                        height: h.clone(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// PowerShell の返りの仮想デスクトップを、大文字の {...} の GUID の並び (重ねず、Windows の並びのまま) にする。形の合わないものと null の GUID は
/// 落とす (jq の `parse_desktops`)
fn parse_desktops(ps: &Jv) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for v in ps
        .get("desktops")
        .and_then(Jv::as_array)
        .into_iter()
        .flatten()
    {
        let Jv::String(s) = v else { continue };
        let up = s.to_ascii_uppercase();
        if !super::layouts::is_guid(&up) || up == "{00000000-0000-0000-0000-000000000000}" {
            continue;
        }
        if !out.contains(&up) {
            out.push(up);
        }
    }
    out
}

/// ディスプレイへのあて方の段。
pub(super) fn assign_layouts(ctx: &mut Ctx, fz: &mut Fz) {
    // 無いのは、FancyZones がまだ動いていない (ディスプレイを開いていない) とき
    if !fz.pc_applied.exists() {
        return;
    }
    let shown = fz.pc_applied.display().to_string();
    let failed = |ctx: &mut Ctx, fz: &mut Fz, lines: Vec<String>, text: &str| {
        warn(ctx, &lines);
        fz.rows
            .push(row(Kind::Failed, text.to_string(), &lines[1..]));
    };
    let apl_shape = |v: &Jv| {
        v.is_object()
            && v.get("applied-layouts")
                .is_none_or(|l| matches!(l, Jv::Array(_)))
    };
    let Some(apl) = read_retry(ctx, &fz.pc_applied, apl_shape) else {
        failed(
            ctx,
            fz,
            vec![
                format!(
                    "FancyZones の applied-layouts.json を読めないので、ディスプレイへのレイアウトのあて方を書きません: {shown}"
                ),
                "中身を確かめて直してから、流し直してください。".to_string(),
            ],
            "FancyZones の applied-layouts.json を読めないので、あて方を書いていない",
        );
        return;
    };
    let list = match apl.get("applied-layouts") {
        Some(Jv::Array(a)) => a.clone(),
        _ => Vec::new(),
    };
    if list.is_empty() {
        return;
    }
    if !layouts_problems(&fz.layouts).is_empty() {
        failed(
            ctx,
            fz,
            vec![format!(
                "{LAYOUTS_REL} に誤りがあるので、FancyZones のディスプレイへのレイアウトのあて方を書きません。"
            )],
            &format!("{LAYOUTS_REL} に誤りがあるので、あて方を書いていない"),
        );
        return;
    }
    let problems = rules_problems(&fz.rules, &fz.layouts);
    if !problems.is_empty() {
        let lines = vec![
            format!(
                "{RULES_REL} に誤りがあるので、FancyZones のディスプレイへのレイアウトのあて方を書きません:"
            ),
            problems.join("\n"),
        ];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Failed,
            format!("{RULES_REL} に誤りがあるので、あて方を書いていない"),
            &problems,
        ));
        return;
    }
    let asg_doc = match std::fs::read_to_string(&fz.assigned) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Some(Jv::parse(r#"{"version":1,"assignments":{}}"#).expect("空の記録"))
        }
        Err(_) => None,
        Ok(t) => Jv::parse(&t)
            .ok()
            .filter(|v| matches!(v.get("assignments"), Some(Jv::Object(_)))),
    };
    let Some(asg_doc) = asg_doc else {
        failed(
            ctx,
            fz,
            vec![
                format!(
                    "FancyZones のディスプレイへのあて方の記録が壊れているので、あて方を書きません: {}",
                    fz.assigned.display()
                ),
                format!(
                    "消してから流し直してください (前に決まりであてた組も、手であてたものとして残します。決まりのレイアウトにし直すなら {})。",
                    super::force_command(ctx)
                ),
            ],
            "FancyZones のディスプレイへのあて方の記録が壊れている",
        );
        return;
    };
    let asg = asg_doc.get("assignments").cloned().expect("確かめた");
    // あてるレイアウトが PC にあるかと、ゾーンの数を見るために、カスタムレイアウトの段の後の PC の custom-layouts.json を読む
    let Ok(pc) = fz.read_pc_layouts(ctx) else {
        failed(
            ctx,
            fz,
            vec![format!(
                "FancyZones の custom-layouts.json を読めないので、ディスプレイへのレイアウトのあて方を書きません: {}",
                fz.pc_layouts.display()
            )],
            "FancyZones の custom-layouts.json を読めないので、あて方を書いていない",
        );
        return;
    };
    let Some(shell) = ps1::find_windows_powershell(ctx) else {
        failed(
            ctx,
            fz,
            vec![
                "Windows PowerShell が見つからないので、ディスプレイの解像度が分からず、FancyZones のディスプレイへのレイアウトのあて方を書きません。".to_string(),
                "powershell.exe が PATH にあるかを確かめてください。".to_string(),
            ],
            "Windows PowerShell が見つからないので、ディスプレイの解像度が分からない",
        );
        return;
    };
    // 組があれば、埋める組が無くても聞く (組の無い仮想デスクトップは、Windows に仮想デスクトップの一覧を聞かないと分からない)
    let spec = ps1::encoded_command(shell, PS_BODY, Duration::from_secs(PS_SECS)).stdout_only();
    let mut all = Vec::new();
    let r = ctx.sys.run(&spec, &mut |l| all.push(l.to_string()));
    let out = r.output.join("\n");
    match r.exit {
        crate::process::Exit::Code(0) => {}
        crate::process::Exit::TimedOut => {
            failed(
                ctx,
                fz,
                vec![format!(
                    "Windows PowerShell が {PS_SECS} 秒たっても終わりませんでした (時間切れ)。FancyZones のディスプレイへのレイアウトのあて方は書きません。"
                )],
                "ディスプレイの解像度を聞けなかった (時間切れ)",
            );
            return;
        }
        ref other => {
            let code = match other {
                crate::process::Exit::Code(c) => format!("終了コード {c}"),
                crate::process::Exit::SpawnFailed(e) => format!("起こせなかった: {e}"),
                _ => "終了コードが無い".to_string(),
            };
            let mut lines = vec![format!(
                "Windows PowerShell でディスプレイの解像度を読めませんでした ({code})。FancyZones のディスプレイへのレイアウトのあて方は書きません:"
            )];
            lines.extend(all.iter().cloned());
            failed(
                ctx,
                fz,
                lines,
                &format!("ディスプレイの解像度を読めなかった ({code})"),
            );
            return;
        }
    }
    let ps = match Jv::parse(&out) {
        Ok(v)
            if v.is_object()
                && matches!(v.get("displays"), Some(Jv::Array(_)))
                && matches!(v.get("desktops"), Some(Jv::Array(_))) =>
        {
            v
        }
        _ => {
            let mut lines = vec!["Windows PowerShell の返りが、決めた形の JSON ではありません。FancyZones のディスプレイへのレイアウトのあて方は書きません:".to_string()];
            lines.extend(all.iter().cloned());
            failed(
                ctx,
                fz,
                lines,
                "ディスプレイの解像度を聞いた返りが、決めた形の JSON でない",
            );
            return;
        }
    };

    let disp = parse_displays(&ps);
    let vds = parse_desktops(&ps);
    let rules = super::layouts::read_rules(&fz.rules);
    let repo = super::layouts::read_repo(&fz.layouts);
    let force = fz.mode.force();
    let mut by_name: Vec<(String, Jv)> = Vec::new();
    for l in &repo {
        let k = l.get("name").cloned().unwrap_or(Jv::Null).tostring();
        match by_name.iter_mut().find(|(n, _)| *n == k) {
            Some((_, v)) => *v = l.clone(),
            None => by_name.push((k, l.clone())),
        }
    }
    let default_name = rules.get("default").cloned().unwrap_or(Jv::Null);
    let default_uuid = lookup(&by_name, &default_name.tostring())
        .and_then(|l| l.get("uuid"))
        .cloned()
        .unwrap_or(Jv::Null);
    let (by_uuid, present) = pc_tables(&pc, &repo, &fz.pending_layouts);
    let wf: Vec<Jv> = list.iter().filter(|e| well_formed(e)).cloned().collect();
    let landscape: Vec<&Display> = disp.iter().filter(|d| d.landscape()).collect();
    // 解像度の決まりのレイアウトの名前
    let target_name = |d: &Display| -> String {
        let res = Jv::String(d.resolution());
        rules
            .get("rules")
            .and_then(Jv::as_array)
            .and_then(|rs| {
                rs.iter()
                    .find(|r| jv::jq_eq(r.field("resolution").unwrap_or(&Jv::Null), &res))
                    .and_then(|r| r.field("layout"))
                    .filter(|l| !matches!(l, Jv::Null | Jv::Bool(false)))
                    .cloned()
            })
            .unwrap_or_else(|| default_name.clone())
            .tostring()
    };
    let target_layout =
        |tname: &str| -> Jv { lookup(&by_name, tname).cloned().unwrap_or(Jv::Null) };
    let same_screen = |e: &Jv, d: &Display| {
        jv::jq_eq(dev(e, "monitor"), &Jv::String(d.monitor.clone()))
            && jv::jq_eq(dev(e, "monitor-instance"), &Jv::String(d.instance.clone()))
    };
    let upper = |v: &Jv| v.tostring().to_ascii_uppercase();

    let mut created: Vec<Created> = Vec::new();
    for d in &landscape {
        let same: Vec<Jv> = wf.iter().filter(|e| same_screen(e, d)).cloned().collect();
        if same.is_empty() {
            continue;
        }
        let tname = target_name(d);
        let tl = target_layout(&tname);
        let t_uuid = tl.field("uuid").cloned().unwrap_or(Jv::Null);
        let pl = lookup(&present, &t_uuid.tostring()).cloned();
        for grp in jv::group_by(&same, |e| dev(e, "serial-number").clone()) {
            let at_number = |e: &&Jv| jv::jq_eq(dev(e, "monitor-number"), &d.number);
            let src = grp.iter().find(at_number).unwrap_or(&grp[0]).clone();
            let have: Vec<String> = grp
                .iter()
                .filter(at_number)
                .map(|e| upper(dev(e, "virtual-desktop")))
                .collect();
            for vd in &vds {
                if have.contains(vd) {
                    continue;
                }
                // 同じデスクトップにある同じ画面の古い組 (番号の違う組。本体は今これを使っている) のうち、並びで先のもの
                let old = grp
                    .iter()
                    .find(|e| upper(dev(e, "virtual-desktop")) == *vd)
                    .cloned();
                let mut device = src.get("device").cloned().unwrap_or(Jv::Null);
                device.set("monitor-number", d.number.clone());
                device.set("virtual-desktop", Jv::String(vd.clone()));
                let holder = Jv::Object(vec![("device".into(), device.clone())]);
                let key = entry_key(&holder);
                let label = format!(
                    "{} ({})・{}・仮想デスクトップ {}",
                    d.monitor,
                    last_amp(&d.instance),
                    d.resolution(),
                    vd8(vd)
                );
                let kept_old = old.as_ref().filter(|o| {
                    base_action(o, &t_uuid, &asg, &default_uuid, force) == Action::Kept
                });
                let c = if let Some(o) = kept_old {
                    // 古い組が手であてたもの (カスタムレイアウト・blank・知らない type) なら、そのレイアウトを写して記録しない (エディターは今の
                    // 番号の組を引くので、決まりのレイアウトにすると手であてたものが消える。--force なら古い組も目標にするので、ここには来ない)
                    let al = o.get("applied-layout").cloned().unwrap_or(Jv::Null);
                    Created {
                        device,
                        key,
                        target: t_uuid.clone(),
                        label,
                        write: true,
                        record: false,
                        tname: layout_label(&al, &by_uuid),
                        new_al: Some(al),
                        note: " (手であてた組と同じ)",
                    }
                } else if usable_layout(pl.as_ref()) {
                    Created {
                        device,
                        key,
                        target: t_uuid.clone(),
                        label,
                        write: true,
                        record: true,
                        new_al: Some(applied_value(pl.as_ref().expect("あてられる"), &t_uuid)),
                        tname: tname.clone(),
                        note: "",
                    }
                } else {
                    Created {
                        device,
                        key,
                        target: t_uuid.clone(),
                        label,
                        write: false,
                        record: false,
                        new_al: None,
                        tname: tname.clone(),
                        note: "",
                    }
                };
                created.push(c);
            }
        }
    }
    let nosrc: Vec<String> = landscape
        .iter()
        .filter(|d| !wf.iter().any(|e| same_screen(e, d)))
        .map(|d| {
            format!(
                "{} ({})・{}",
                d.monitor,
                last_amp(&d.instance),
                d.resolution()
            )
        })
        .collect();
    let entries: Vec<Planned> = list
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let untouched = Planned {
                i,
                key: None,
                action: Action::Untouched,
                target: Jv::Null,
                tname: String::new(),
                label: String::new(),
                before: String::new(),
                note: "",
                new_al: None,
            };
            if !well_formed(e) {
                return untouched;
            }
            let monitor = dev(e, "monitor");
            let d = disp
                .iter()
                .find(|d| {
                    jv::jq_eq(monitor, &Jv::String(d.monitor.clone()))
                        && jv::jq_eq(dev(e, "monitor-instance"), &Jv::String(d.instance.clone()))
                })
                .or_else(|| {
                    disp.iter().find(|d| {
                        jv::jq_eq(monitor, &Jv::String(d.monitor.clone()))
                            && jv::jq_eq(dev(e, "monitor-number"), &d.number)
                    })
                });
            let Some(d) = d.filter(|d| d.landscape()) else {
                return untouched;
            };
            let tname = target_name(d);
            let tl = target_layout(&tname);
            let t_uuid = tl.field("uuid").cloned().unwrap_or(Jv::Null);
            let pl = lookup(&present, &t_uuid.tostring()).cloned();
            let al = e.get("applied-layout").cloned().unwrap_or(Jv::Null);
            let base = base_action(e, &t_uuid, &asg, &default_uuid, force);
            let usable = usable_layout(pl.as_ref());
            let action = if WRITES.contains(&base) && !usable {
                Action::Missing
            } else {
                base
            };
            let note = match action {
                Action::Retarget => " (前に決まりであてたもの)",
                Action::Default => " (横向きの既定)",
                Action::Force => " (--force)",
                _ => "",
            };
            Planned {
                i,
                key: Some(entry_key(e)),
                action,
                label: format!(
                    "{} ({})・{}・仮想デスクトップ {}",
                    monitor.tostring(),
                    last_amp(&dev(e, "monitor-instance").tostring()),
                    d.resolution(),
                    vd8(&dev(e, "virtual-desktop").tostring())
                ),
                before: layout_label(&al, &by_uuid),
                new_al: WRITES
                    .contains(&action)
                    .then(|| applied_value(pl.as_ref().expect("あてられる"), &t_uuid)),
                target: t_uuid,
                tname,
                note,
            }
        })
        .collect();

    let nwrite = entries.iter().filter(|p| p.write()).count();
    let nsame = entries.iter().filter(|p| p.action == Action::Same).count();
    let nkept = entries.iter().filter(|p| p.action == Action::Kept).count();
    let nuntouched = entries
        .iter()
        .filter(|p| p.action == Action::Untouched)
        .count();
    let ncreate = created.iter().filter(|c| c.write).count();
    // 目標のレイアウトが PC に無い組 (PC で消して、カスタムレイアウトの段が知らせた) は、埋めず・作らずに知らせる
    let missing_names: Vec<Jv> = entries
        .iter()
        .filter(|p| p.action == Action::Missing)
        .map(|p| Jv::String(p.tname.clone()))
        .chain(
            created
                .iter()
                .filter(|c| !c.write)
                .map(|c| Jv::String(c.tname.clone())),
        )
        .collect();
    let missing = jv::group_by(&missing_names, |v| v.clone());
    for g in &missing {
        let lines = [
            format!(
                "決まりのレイアウト「{}」が PC の custom-layouts.json に無い (か canvas でない) ので、{} 組にあてていません: {}",
                g[0].tostring(),
                g.len(),
                fz.pc_layouts.display()
            ),
            format!(
                "PC で消したものなら、--force で足し直すとあてます (先に {} で何が変わるかを見られます)。",
                super::dry_force_command(ctx)
            ),
        ];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Manual,
            format!(
                "決まりのレイアウト「{}」が PC に無い (か canvas でない) ので、{} 組にあてていない",
                g[0].tostring(),
                g.len()
            ),
            &[format!(
                "PC で消したものなら、{} で足し直してからあてる",
                super::force_command(ctx)
            )],
        ));
    }
    let kept_line = format!(
        "手であてたカスタムレイアウト・blank の組 ({nkept} 組) は残しました。決まりのレイアウトで上書きするなら: {} (--force は、PC で直した・消した dotfiles のカスタムレイアウトも repo の中身に戻します。先に {} で何が変わるかを見られます)",
        super::force_command(ctx),
        super::dry_force_command(ctx)
    );
    let nosrc_line = format!(
        "次の画面は、同じ画面 (モニター ID と instance が同じ) の組がどの仮想デスクトップにも無いので、組を作りません: {}",
        nosrc.join("、")
    );
    let mut info_notes = Vec::new();
    if nkept > 0 {
        info_notes.push(kept_line.clone());
    }
    if !nosrc.is_empty() {
        info_notes.push(nosrc_line.clone());
    }

    if nwrite == 0 && ncreate == 0 {
        save_assigned(ctx, fz, &apl, &asg, &entries, &created, false);
        let note = same_note(nsame, nuntouched);
        if missing.is_empty() {
            ctx.say(format!(
                "FancyZones のディスプレイへのあて方は揃っています{note}。"
            ));
            fz.rows.push(row(
                Kind::Ok,
                format!("FancyZones のディスプレイへのあて方は揃っている{note}"),
                &info_notes,
            ));
        } else {
            ctx.say(format!(
                "FancyZones のディスプレイへのあて方で、変える組はありません{note}。"
            ));
        }
        if nkept > 0 {
            ctx.say(format!("  {kept_line}"));
        }
        if !nosrc.is_empty() {
            ctx.say(format!("  {nosrc_line}"));
        }
        return;
    }

    // 変える組と作る組を 1 組 1 行で (シリアルは出さない)。シリアルだけが違う組の同じ行は、1 行にまとめて組の数を添える
    let pre = fz.pre;
    let raw: Vec<String> = entries
        .iter()
        .filter(|p| p.write())
        .map(|p| format!("  {pre}{}: {} → {}{}", p.label, p.before, p.tname, p.note))
        .chain(
            created
                .iter()
                .filter(|c| c.write)
                .map(|c| format!("  {pre}{}: 組なし → {}{}", c.label, c.tname, c.note)),
        )
        .collect();
    let mut counted: Vec<(String, usize)> = Vec::new();
    for l in raw {
        match counted.iter_mut().find(|(x, _)| *x == l) {
            Some((_, n)) => *n += 1,
            None => counted.push((l, 1)),
        }
    }
    let lines: Vec<String> = counted
        .into_iter()
        .map(|(l, n)| if n > 1 { format!("{l} ({n} 組)") } else { l })
        .collect();
    if fz.mode.writes() {
        if fz.backup.copy(&fz.pc_applied.clone()).is_err() {
            let mut l = vec![format!(
                "FancyZones の applied-layouts.json を退避できないので、ディスプレイへのレイアウトのあて方を書きません: {}",
                fz.backup.root().display()
            )];
            l.push(lines.join("\n"));
            failed(
                ctx,
                fz,
                l,
                "FancyZones の applied-layouts.json を退避できないので、あて方を書いていない",
            );
            save_assigned(ctx, fz, &apl, &asg, &entries, &created, false);
            return;
        }
        // 書く中身: 計画で書く組の applied-layout を置き換え、作る組を末尾に足す (今ある組の device・並び・ほかの組は変えない)
        let mut new_list: Vec<Jv> = list.clone();
        for p in entries.iter().filter(|p| p.write()) {
            new_list[p.i].set("applied-layout", p.new_al.clone().expect("書く組"));
        }
        for c in created.iter().filter(|c| c.write) {
            new_list.push(Jv::Object(vec![
                ("device".into(), c.device.clone()),
                ("applied-layout".into(), c.new_al.clone().expect("作る組")),
            ]));
        }
        let mut doc = apl.clone();
        doc.set("applied-layouts", Jv::Array(new_list));
        if super::place(&fz.pc_applied, &pt_form(&doc)).is_err() {
            let mut l = vec![format!(
                "FancyZones の applied-layouts.json に書けないので、ディスプレイへのレイアウトのあて方を変えられませんでした: {shown}"
            )];
            l.push(lines.join("\n"));
            failed(
                ctx,
                fz,
                l,
                "FancyZones の applied-layouts.json に書けないので、あて方を変えられなかった",
            );
            save_assigned(ctx, fz, &apl, &asg, &entries, &created, false);
            return;
        }
        super::reload(ctx, fz, &fz.pc_applied.clone(), "applied-layouts.json");
        save_assigned(ctx, fz, &apl, &asg, &entries, &created, true);
    }

    let head = match fz.mode {
        Mode::Check => {
            format!("==> FancyZones のディスプレイへのあて方 (apply で変える組・作る組。{shown})")
        }
        _ => format!("==> {pre}FancyZones のディスプレイへのあて方 ({shown})"),
    };
    ctx.say(head);
    for l in &lines {
        ctx.say(l);
    }
    if nuntouched > 0 {
        ctx.say(format!(
            "  つながっていない・縦向きのディスプレイの組 ({nuntouched} 組) には触りません。"
        ));
    }
    if nkept > 0 {
        ctx.say(format!("  {kept_line}"));
    }
    if !nosrc.is_empty() {
        ctx.say(format!("  {nosrc_line}"));
    }
    if fz.mode.writes()
        && let Some(dir) = fz.backup.dir()
    {
        ctx.say(format!(
            "  書き換える前のファイルは {} に退避しました。",
            dir.display()
        ));
    }
    let (kind, verb) = match fz.mode {
        Mode::Apply { .. } => (Kind::Ok, "にした"),
        _ if nwrite > 0 => (Kind::Fix, "にする"),
        _ => (Kind::Missing, "にする"),
    };
    fz.rows.push(row(
        kind,
        format!("{pre}FancyZones のディスプレイの組 {nwrite} 組を決まりのレイアウト{verb}・組の無い仮想デスクトップに {ncreate} 組を作る"),
        &info_notes,
    ));
}

/// 揃っているときの括弧の中 (WSL の `same_note`)
fn same_note(nsame: usize, nuntouched: usize) -> String {
    let mut parts = Vec::new();
    if nsame > 0 {
        parts.push(format!("決まりのレイアウトの組 {nsame} 組"));
    }
    if nuntouched > 0 {
        parts.push(format!(
            "つながっていない・縦向きのディスプレイの組 {nuntouched} 組には触りません"
        ));
    }
    match parts.len() {
        0 => String::new(),
        _ => format!(" ({})", parts.join("。")),
    }
}

/// あて方の記録を書く (変わったときだけ。check と dry-run では書かない。WSL の `save_assigned`)。applied-layouts.json から消えた組のキーは落とし、
/// 目標と同じ組で記録が無いものと、書けたときは書いた組・作った組 (手であてた組から写したものを除く) を、目標のレイアウトの uuid で記録する。
fn save_assigned(
    ctx: &mut Ctx,
    fz: &mut Fz,
    apl: &Jv,
    asg: &Jv,
    entries: &[Planned],
    created: &[Created],
    wrote: bool,
) {
    if !fz.mode.writes() {
        return;
    }
    let made: Vec<&Created> = if wrote {
        created.iter().filter(|c| c.write).collect()
    } else {
        Vec::new()
    };
    let mut keys: Vec<String> = apl
        .get("applied-layouts")
        .and_then(Jv::as_array)
        .into_iter()
        .flatten()
        .filter(|e| well_formed(e))
        .map(entry_key)
        .collect();
    keys.extend(made.iter().map(|c| c.key.clone()));
    let kept: Vec<(String, Jv)> = asg
        .as_object()
        .map(|o| {
            o.iter()
                .filter(|(k, _)| keys.contains(k))
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    let had: Vec<String> = kept.iter().map(|(k, _)| k.clone()).collect();
    let mut obj = Jv::Object(kept);
    for p in entries {
        let Some(k) = &p.key else { continue };
        if (p.action == Action::Same && !had.contains(k)) || (wrote && p.write()) {
            obj.set(k, p.target.clone());
        }
    }
    for c in made.iter().filter(|c| c.record) {
        obj.set(&c.key, c.target.clone());
    }
    let new = Jv::Object(vec![
        ("version".into(), Jv::from(1)),
        ("assignments".into(), obj),
    ]);
    let new_text = format!("{}\n", new.sorted().indent(2));
    let old_text = if fz.assigned.exists() {
        std::fs::read_to_string(&fz.assigned)
            .ok()
            .and_then(|t| Jv::parse(&t).ok())
            .map(|v| format!("{}\n", v.sorted().indent(2)))
    } else {
        Some(format!(
            "{}\n",
            Jv::parse(r#"{"version":1,"assignments":{}}"#)
                .expect("空の記録")
                .sorted()
                .indent(2)
        ))
    };
    if old_text.as_deref() == Some(new_text.as_str()) {
        return;
    }
    if crate::fsutil::write_atomic(&fz.assigned, new_text.as_bytes()).is_err() {
        let lines = [
            format!(
                "FancyZones のディスプレイへのあて方の記録を書けませんでした: {}",
                fz.assigned.display()
            ),
            format!(
                "次の回は、決まりであてた組を手であてたものとして残すことがあります ({} で決まりのレイアウトにし直せます)。",
                super::force_command(ctx)
            ),
        ];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Failed,
            "FancyZones のディスプレイへのあて方の記録を書けない",
            &lines[1..],
        ));
    }
}
