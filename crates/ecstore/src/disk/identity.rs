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
//! mode is meant for filesystems without stable inode numbers (CIFS/SMB), where
//! two hardlinks of one file may report different inodes:
//!
//! - file handles are the same when they are regular files on one device with
//!   equal length and equal SHA-256. Byte-identical metadata files are
//!   semantically identical, so accepting a distinct file with equal bytes is
//!   intended.
//! - a completed fsync is never assumed to cover another file, and raw inode
//!   fields carry no identity; both report "not the same".
//! - cached metadata matches when everything but the inode number is equal.

use rustfs_config::{
    DEFAULT_RUSTFS_FS_IDENTITY_MODE, ENV_RUSTFS_FS_IDENTITY_MODE, RUSTFS_FS_IDENTITY_MODE_CONTENT, RUSTFS_FS_IDENTITY_MODE_INODE,
};
#[cfg(unix)]
use std::io;
use std::sync::OnceLock;
use tracing::warn;

use super::{LOG_COMPONENT_ECSTORE, LOG_SUBSYSTEM_DISK};

const EVENT_DISK_IDENTITY_MODE_INVALID: &str = "disk_identity_mode_invalid";
const EVENT_DISK_IDENTITY_MODE_CONTENT: &str = "disk_identity_mode_content";

/// Same bound as the metadata receipt hashing in `os.rs`.
#[cfg(unix)]
const CONTENT_IDENTITY_MAX_BYTES: u64 = 64 * 1024 * 1024;
#[cfg(unix)]
const CONTENT_IDENTITY_READ_CHUNK_BYTES: usize = 64 * 1024;

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
                warn!(
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
        IdentityMode::Content => {
            let a_metadata = a.metadata()?;
            let b_metadata = b.metadata()?;
            if !a_metadata.is_file()
                || !b_metadata.is_file()
                || a_metadata.dev() != b_metadata.dev()
                || a_metadata.len() != b_metadata.len()
            {
                return Ok(false);
            }
            let length = a_metadata.len();
            Ok(sha256_at(a, length)? == sha256_at(b, length)?)
        }
    }
}

/// SHA-256 of the first `length` bytes of `file`, which must be its complete
/// contents. Positional reads leave the file offset untouched. A length above
/// the bound, a short read or trailing bytes yield `InvalidData`.
#[cfg(unix)]
pub(crate) fn sha256_at(file: &std::fs::File, length: u64) -> io::Result<[u8; 32]> {
    use sha2::{Digest, Sha256};
    use std::os::unix::fs::FileExt;
    if length > CONTENT_IDENTITY_MAX_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "file identity length exceeds the content bound"));
    }
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; CONTENT_IDENTITY_READ_CHUNK_BYTES];
    let mut offset = 0_u64;
    while offset < length {
        let wanted = usize::try_from(length - offset).map_or(buffer.len(), |remaining| remaining.min(buffer.len()));
        match file.read_at(&mut buffer[..wanted], offset) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::InvalidData, "file identity contents shrank while reading")),
            Ok(read) => {
                hasher.update(&buffer[..read]);
                offset += read as u64;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    loop {
        match file.read_at(&mut buffer[..1], length) {
            Ok(0) => break,
            Ok(_) => return Err(io::Error::new(io::ErrorKind::InvalidData, "file identity contents grew while reading")),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(hasher.finalize().into())
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
        // Raw inode fields carry no identity here; the hardlink branch that
        // consumes them is never taken because the copy path is forced.
        IdentityMode::Content => false,
    }
}

pub(crate) fn same_file_metadata(a: &std::fs::Metadata, b: &std::fs::Metadata, mode: IdentityMode) -> bool {
    match mode {
        IdentityMode::Inode => super::fs::same_file(a, b),
        // A miss only costs a re-read and re-validation of the cached file.
        IdentityMode::Content => same_file_metadata_without_inode(a, b),
    }
}

#[cfg(unix)]
fn same_file_metadata_without_inode(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    a.dev() == b.dev()
        && a.file_type() == b.file_type()
        && a.len() == b.len()
        && a.permissions() == b.permissions()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
}

#[cfg(not(unix))]
fn same_file_metadata_without_inode(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    super::fs::same_file(a, b)
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
    fn content_mode_handles_compare_regular_file_bytes() {
        use std::io::{Read, Seek, SeekFrom};
        let dir = tempfile::tempdir().expect("temporary directory");
        let first = dir.path().join("first");
        let link = dir.path().join("link");
        let twin = dir.path().join("twin");
        let flipped = dir.path().join("flipped");
        let longer = dir.path().join("longer");
        fs::write(&first, b"same bytes").expect("write first");
        fs::hard_link(&first, &link).expect("create hardlink");
        fs::write(&twin, b"same bytes").expect("write twin");
        fs::write(&flipped, b"same bytez").expect("write flipped");
        fs::write(&longer, b"same bytes!").expect("write longer");
        let mut a = fs::File::open(&first).expect("open first");
        let mut again = fs::File::open(&first).expect("open first again");
        let open = |path: &std::path::Path| fs::File::open(path).expect("open");

        assert!(same_file_handle(&a, &again, IdentityMode::Content).expect("same file"));
        assert!(same_file_handle(&a, &open(&link), IdentityMode::Content).expect("hardlink"));
        assert!(same_file_handle(&a, &open(&twin), IdentityMode::Content).expect("equal bytes in a distinct file"));
        assert!(!same_file_handle(&a, &open(&flipped), IdentityMode::Content).expect("same length, other bytes"));
        assert!(!same_file_handle(&a, &open(&longer), IdentityMode::Content).expect("other length"));
        assert!(!same_file_handle(&a, &open(dir.path()), IdentityMode::Content).expect("directory"));
        assert!(!same_file_handle(&open(dir.path()), &open(dir.path()), IdentityMode::Content).expect("two directories"));

        a.seek(SeekFrom::Start(3)).expect("seek first");
        again.seek(SeekFrom::Start(5)).expect("seek again");
        assert!(same_file_handle(&a, &again, IdentityMode::Content).expect("offsets are irrelevant"));
        assert_eq!(a.stream_position().expect("position"), 3);
        assert_eq!(again.stream_position().expect("position"), 5);
        let mut rest = Vec::new();
        a.read_to_end(&mut rest).expect("read rest");
        assert_eq!(rest, b"e bytes");
    }

    #[test]
    fn content_mode_rejects_files_above_the_bound_without_reading_them() {
        let dir = tempfile::tempdir().expect("temporary directory");
        let first = dir.path().join("first");
        let second = dir.path().join("second");
        for path in [&first, &second] {
            fs::File::create(path)
                .and_then(|file| file.set_len(CONTENT_IDENTITY_MAX_BYTES + 1))
                .expect("sparse file");
        }
        let a = fs::File::open(&first).expect("open first");
        let b = fs::File::open(&second).expect("open second");
        let err = same_file_handle(&a, &b, IdentityMode::Content).expect_err("oversized files must be refused");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn content_sha256_detects_length_changes() {
        let dir = tempfile::tempdir().expect("temporary directory");
        let path = dir.path().join("file");
        fs::write(&path, b"abcdef").expect("write file");
        let file = fs::File::open(&path).expect("open file");
        assert!(sha256_at(&file, 6).is_ok());
        assert_eq!(sha256_at(&file, 5).expect_err("trailing bytes").kind(), io::ErrorKind::InvalidData);
        assert_eq!(sha256_at(&file, 7).expect_err("short read").kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn content_mode_metadata_ignores_inode_but_not_content_changes() {
        let dir = tempfile::tempdir().expect("temporary directory");
        let path = dir.path().join("file");
        let link = dir.path().join("link");
        fs::write(&path, b"bytes").expect("write file");
        fs::hard_link(&path, &link).expect("create hardlink");
        let before = fs::metadata(&path).expect("metadata");

        assert!(same_file_metadata(&before, &fs::metadata(&path).expect("metadata"), IdentityMode::Content));
        assert!(same_file_metadata(&before, &fs::metadata(&link).expect("metadata"), IdentityMode::Content));

        fs::write(&path, b"longer bytes").expect("rewrite with another length");
        assert!(!same_file_metadata(&before, &fs::metadata(&path).expect("metadata"), IdentityMode::Content));

        let file = fs::OpenOptions::new().write(true).open(&path).expect("open for write");
        file.set_len(5).expect("restore length");
        file.set_modified(before.modified().expect("mtime") + std::time::Duration::from_millis(1))
            .expect("shift mtime");
        let shifted = fs::metadata(&path).expect("metadata");
        assert_eq!(shifted.len(), before.len());
        assert!(!same_file_metadata(&before, &shifted, IdentityMode::Content));
    }

    #[test]
    fn content_mode_keeps_durability_and_raw_fields_closed() {
        let dir = tempfile::tempdir().expect("temporary directory");
        let path = dir.path().join("file");
        fs::write(&path, b"bytes").expect("write file");
        let a = fs::File::open(&path).expect("open file");
        let again = fs::File::open(&path).expect("open file again");

        assert!(!durability_proof_transfers(&a, &again, IdentityMode::Content).expect("content durability"));
        assert!(!same_identity_fields(1, 2, 1, 2, IdentityMode::Content));
        assert!(prefer_copy_over_hardlink(IdentityMode::Content));
        assert!(!prefer_copy_over_hardlink(IdentityMode::Inode));
    }
}
