// Copyright 2024 RustFS Team
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! File-identity decisions behind one mode switch.
//!
//! `inode` mode compares `(st_dev, st_ino)` as RustFS always did. `content`
//! mode is meant for filesystems without stable inode numbers (CIFS/SMB); every
//! `content` arm currently fails closed, i.e. reports "not the same".

use rustfs_config::{
    DEFAULT_RUSTFS_FS_IDENTITY_MODE, ENV_RUSTFS_FS_IDENTITY_MODE, RUSTFS_FS_IDENTITY_MODE_CONTENT, RUSTFS_FS_IDENTITY_MODE_INODE,
};
#[cfg(unix)]
use std::io;
use std::sync::OnceLock;
use tracing::{error, warn};

use super::{LOG_COMPONENT_ECSTORE, LOG_SUBSYSTEM_DISK};

const EVENT_DISK_IDENTITY_MODE_INVALID: &str = "disk_identity_mode_invalid";
const EVENT_DISK_IDENTITY_MODE_CONTENT: &str = "disk_identity_mode_content";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum IdentityMode {
    Inode,
    Content,
}

pub(crate) fn parse_identity_mode(value: Option<&str>) -> Result<IdentityMode, String> {
    let Some(value) = value else {
        return Ok(IdentityMode::Inode);
    };
    match value.trim().to_ascii_lowercase().as_str() {
        RUSTFS_FS_IDENTITY_MODE_INODE => Ok(IdentityMode::Inode),
        RUSTFS_FS_IDENTITY_MODE_CONTENT => Ok(IdentityMode::Content),
        _ => Err(format!("invalid {ENV_RUSTFS_FS_IDENTITY_MODE} value {value:?}; expected inode|content")),
    }
}

/// Effective mode, read from the environment once. The first call also emits the
/// startup notice for `content` mode.
pub(crate) fn identity_mode() -> IdentityMode {
    static MODE: OnceLock<IdentityMode> = OnceLock::new();
    *MODE.get_or_init(|| {
        let raw = std::env::var(ENV_RUSTFS_FS_IDENTITY_MODE).ok();
        let mode = match parse_identity_mode(raw.as_deref()) {
            Ok(mode) => mode,
            Err(err) => {
                error!(
                    event = EVENT_DISK_IDENTITY_MODE_INVALID,
                    component = LOG_COMPONENT_ECSTORE,
                    subsystem = LOG_SUBSYSTEM_DISK,
                    env = ENV_RUSTFS_FS_IDENTITY_MODE,
                    default = DEFAULT_RUSTFS_FS_IDENTITY_MODE,
                    error = %err,
                    "Invalid filesystem identity mode; falling back to default"
                );
                IdentityMode::Inode
            }
        };
        if mode == IdentityMode::Content {
            warn!(
                event = EVENT_DISK_IDENTITY_MODE_CONTENT,
                component = LOG_COMPONENT_ECSTORE,
                subsystem = LOG_SUBSYSTEM_DISK,
                env = ENV_RUSTFS_FS_IDENTITY_MODE,
                mode = RUSTFS_FS_IDENTITY_MODE_CONTENT,
                "Filesystem identity mode is content; intended for filesystems without stable inode numbers such as CIFS/SMB"
            );
        }
        mode
    })
}

#[cfg(unix)]
pub(crate) fn same_file_handle(a: &std::fs::File, b: &std::fs::File, mode: IdentityMode) -> io::Result<bool> {
    use std::os::unix::fs::MetadataExt;
    match mode {
        IdentityMode::Inode => {
            let a = a.metadata()?;
            let b = b.metadata()?;
            Ok(a.dev() == b.dev() && a.ino() == b.ino())
        }
        IdentityMode::Content => Ok(false),
    }
}

/// Whether a completed fsync of `a` also covers `b`, i.e. `b` is the very same inode.
#[cfg(unix)]
pub(crate) fn durability_proof_transfers(a: &std::fs::File, b: &std::fs::File, mode: IdentityMode) -> io::Result<bool> {
    match mode {
        IdentityMode::Inode => same_file_handle(a, b, IdentityMode::Inode),
        // Final semantics, not a placeholder: equal bytes cannot prove that
        // another file's data reached stable storage.
        IdentityMode::Content => Ok(false),
    }
}

#[cfg(unix)]
pub(crate) fn same_identity_fields(a_dev: u64, a_ino: u64, b_dev: u64, b_ino: u64, mode: IdentityMode) -> bool {
    match mode {
        IdentityMode::Inode => a_dev == b_dev && a_ino == b_ino,
        IdentityMode::Content => false,
    }
}

pub(crate) fn same_file_metadata(a: &std::fs::Metadata, b: &std::fs::Metadata, mode: IdentityMode) -> bool {
    match mode {
        IdentityMode::Inode => super::fs::same_file(a, b),
        // A miss only costs a re-read of the cached file.
        IdentityMode::Content => false,
    }
}

/// Hardlink identity cannot be verified without stable inodes, so the verified
/// copy path is used instead.
#[cfg(unix)]
pub(crate) fn prefer_copy_over_hardlink(mode: IdentityMode) -> bool {
    mode == IdentityMode::Content
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn parse_defaults_to_inode() {
        assert_eq!(parse_identity_mode(None), Ok(IdentityMode::Inode));
    }

    #[test]
    fn parse_accepts_both_values_case_insensitive_and_trimmed() {
        assert_eq!(parse_identity_mode(Some("inode")), Ok(IdentityMode::Inode));
        assert_eq!(parse_identity_mode(Some("content")), Ok(IdentityMode::Content));
        assert_eq!(parse_identity_mode(Some("  CoNtEnT \n")), Ok(IdentityMode::Content));
        assert_eq!(parse_identity_mode(Some(" INODE ")), Ok(IdentityMode::Inode));
    }

    #[test]
    fn parse_rejects_unknown_value_naming_allowed_values() {
        let err = parse_identity_mode(Some("hash")).expect_err("unknown value must be rejected");
        assert!(err.contains("inode|content"), "{err}");
        assert!(parse_identity_mode(Some("")).is_err());
    }

    #[test]
    fn inode_mode_matches_same_file_and_hardlink_but_not_equal_bytes() {
        let dir = tempfile::tempdir().expect("temporary directory");
        let first = dir.path().join("first");
        let link = dir.path().join("link");
        let other = dir.path().join("other");
        fs::write(&first, b"same bytes").expect("write first");
        fs::write(&other, b"same bytes").expect("write other");
        fs::hard_link(&first, &link).expect("create hardlink");

        let a = fs::File::open(&first).expect("open first");
        let again = fs::File::open(&first).expect("open first again");
        let linked = fs::File::open(&link).expect("open hardlink");
        let different = fs::File::open(&other).expect("open other");

        assert!(same_file_handle(&a, &again, IdentityMode::Inode).expect("same file"));
        assert!(same_file_handle(&a, &linked, IdentityMode::Inode).expect("hardlink"));
        assert!(!same_file_handle(&a, &different, IdentityMode::Inode).expect("different file"));
        assert!(durability_proof_transfers(&a, &again, IdentityMode::Inode).expect("same file"));
        assert!(!durability_proof_transfers(&a, &different, IdentityMode::Inode).expect("different file"));

        let (ma, mo) = (a.metadata().expect("metadata"), different.metadata().expect("metadata"));
        assert!(same_file_metadata(&ma, &again.metadata().expect("metadata"), IdentityMode::Inode));
        assert!(!same_file_metadata(&ma, &mo, IdentityMode::Inode));
    }

    #[test]
    fn inode_mode_field_comparison_needs_both_fields_equal() {
        assert!(same_identity_fields(1, 2, 1, 2, IdentityMode::Inode));
        assert!(!same_identity_fields(1, 2, 1, 3, IdentityMode::Inode));
        assert!(!same_identity_fields(1, 2, 2, 2, IdentityMode::Inode));
    }

    #[test]
    fn content_mode_fails_closed() {
        let dir = tempfile::tempdir().expect("temporary directory");
        let path = dir.path().join("file");
        fs::write(&path, b"bytes").expect("write file");
        let a = fs::File::open(&path).expect("open file");
        let again = fs::File::open(&path).expect("open file again");

        assert!(!same_file_handle(&a, &again, IdentityMode::Content).expect("content handle"));
        assert!(!durability_proof_transfers(&a, &again, IdentityMode::Content).expect("content durability"));
        assert!(!same_identity_fields(1, 2, 1, 2, IdentityMode::Content));
        let metadata = a.metadata().expect("metadata");
        assert!(!same_file_metadata(&metadata, &metadata, IdentityMode::Content));
        assert!(prefer_copy_over_hardlink(IdentityMode::Content));
        assert!(!prefer_copy_over_hardlink(IdentityMode::Inode));
    }
}
