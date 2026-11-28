//! OS ごとの FFI。unsafe はここだけに置く (workspace の lints で `unsafe_code = "deny"`)。
//!
//! どちらの OS も同じ名前を出す: `Group` (時間切れで止める組)・`prepare_group`・`signal_of`・`is_executable`・
//! `interrupts_to_child`・`set_mode`・`mode_of`・`set_owner_only`・`access_of` (Windows の DACL)・`read_hidden` (端末から
//! 字を出さずに 1 行)。Unix だけ `execve_first` (exec_replace が使う)。

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub(crate) use unix::*;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub(crate) use windows::*;
