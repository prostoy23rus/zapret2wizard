//! Scanner reports only; explicit --output strategy files keep their CLI path.
//!
//! BCW_REPORT_DIR must be an existing absolute non-root directory, without
//! symlinks or parent traversal. Caller creates a private per-invocation directory,
//! keeps it stable until child exit, then reads only that directory. No pruning,
//! directory creation, or recursive deletion: bounded run retention is caller-owned.

use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

pub(super) const REPORT_DIR_ENV: &str = "BCW_REPORT_DIR";
static NEXT_FILE: AtomicUsize = AtomicUsize::new(0);

#[derive(Debug)]
pub(super) struct ReportDirectory {
    path: PathBuf,
    explicit: bool,
}

impl ReportDirectory {
    pub(super) fn from_env() -> io::Result<Self> {
        Self::from_override(std::env::var_os(REPORT_DIR_ENV).as_deref())
    }

    // Tests supply explicit values; never mutate process environment or CWD.
    fn from_override(value: Option<&OsStr>) -> io::Result<Self> {
        match value {
            None => Ok(Self {
                path: std::env::current_dir()?,
                explicit: false,
            }),
            Some(value) => {
                let path = PathBuf::from(value);
                validate_directory(&path)?;
                Ok(Self {
                    path,
                    explicit: true,
                })
            }
        }
    }

    /// Complete, exclusive publication: collision adds a suffix rather than
    /// replacing a previous run. First report keeps the historical CLI name.
    pub(super) fn write(&self, prefix: &str, kind: &str, content: &str) -> io::Result<PathBuf> {
        validate_name(prefix)?;
        validate_name(kind)?;
        if self.explicit {
            validate_directory(&self.path)?;
        }
        let (temp, mut file) = loop {
            let id = NEXT_FILE.fetch_add(1, Ordering::Relaxed);
            let temp = self
                .path
                .join(format!(".bcw-report-{}-{id}.tmp", std::process::id()));
            match OpenOptions::new().write(true).create_new(true).open(&temp) {
                Ok(file) => break (temp, file),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        };
        let result = (|| {
            let written = file
                .write_all(content.as_bytes())
                .and_then(|_| file.sync_all());
            drop(file); // Windows cleanup needs the handle closed, including on error.
            written?;
            let mut target = self.path.join(format!("{prefix}_{kind}"));
            loop {
                // hard_link atomically publishes complete bytes on the same FS,
                // but unlike rename cannot clobber another report or symlink.
                match fs::hard_link(&temp, &target) {
                    Ok(()) => return Ok(target),
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                        let id = NEXT_FILE.fetch_add(1, Ordering::Relaxed);
                        target = self
                            .path
                            .join(format!("{prefix}_{}-{id}_{kind}", std::process::id()));
                    }
                    Err(e) => return Err(e),
                }
            }
        })();
        // Only our exclusive scratch file is ever removed.
        let cleanup = fs::remove_file(&temp);
        match (result, cleanup) {
            (Ok(path), Ok(())) => Ok(path),
            (Ok(_), Err(e)) | (Err(e), _) => Err(e),
        }
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{REPORT_DIR_ENV}: {message}"),
    )
}

fn validate_name(name: &str) -> io::Result<()> {
    if name.is_empty()
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    {
        return Err(invalid("invalid generated report name"));
    }
    Ok(())
}

fn validate_directory(path: &Path) -> io::Result<()> {
    if !path.is_absolute() || !path.components().any(|c| matches!(c, Component::Normal(_))) {
        return Err(invalid("expected an absolute non-root directory"));
    }
    let mut ancestor = PathBuf::new();
    for part in path.components() {
        if matches!(part, Component::ParentDir) {
            return Err(invalid("parent traversal is not allowed"));
        }
        ancestor.push(part.as_os_str());
        let metadata = fs::symlink_metadata(&ancestor)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(invalid("every component must be a real directory"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            loop {
                let id = NEXT_FILE.fetch_add(1, Ordering::Relaxed);
                let path = std::env::temp_dir()
                    .join(format!("bcw-report-test-{}-{id}", std::process::id()));
                match fs::create_dir(&path) {
                    Ok(()) => return Self(fs::canonicalize(path).unwrap()),
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                    Err(e) => panic!("scratch directory: {e}"),
                }
            }
        }
        fn reports(&self) -> ReportDirectory {
            ReportDirectory::from_override(Some(self.0.as_os_str())).unwrap()
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            // Exact newly-created test directory, not a production retention path.
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn default_directory_remains_cwd_without_env_mutation() {
        let reports = ReportDirectory::from_override(None).unwrap();
        assert_eq!(reports.path, std::env::current_dir().unwrap());
        assert!(!reports.explicit);
    }

    #[test]
    fn explicit_directory_keeps_historical_names_and_complete_contents() {
        let scratch = Scratch::new();
        let path = scratch
            .reports()
            .write("2026-11-23_20-40-00", "scan.json", "complete")
            .unwrap();
        assert_eq!(path, scratch.0.join("2026-11-23_20-40-00_scan.json"));
        assert_eq!(fs::read_to_string(path).unwrap(), "complete");
        assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 1);
    }

    #[test]
    fn completed_and_interrupted_writers_share_destination_and_no_replace_semantics() {
        let scratch = Scratch::new();
        // Separate instances model normal and signal-handler resolution paths.
        let completed = scratch.reports();
        let interrupted = scratch.reports();
        let first = completed.write("same", "scan.json", "completed").unwrap();
        let second = interrupted.write("same", "scan.json", "censored").unwrap();
        let vanilla = interrupted
            .write("same", "report_vanilla.txt", "partial")
            .unwrap();
        for path in [&first, &second, &vanilla] {
            assert_eq!(path.parent(), Some(scratch.0.as_path()));
        }
        assert_eq!(fs::read_to_string(first).unwrap(), "completed");
        assert_eq!(fs::read_to_string(second).unwrap(), "censored");
        assert_eq!(fs::read_to_string(vanilla).unwrap(), "partial");
        assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 3);
    }

    #[test]
    fn repeated_timestamps_preserve_previous_reports_and_unrelated_files() {
        let scratch = Scratch::new();
        fs::write(scratch.0.join("unrelated.txt"), "preserve").unwrap();
        let reports = scratch.reports();
        let old = reports.write("same", "scan.json", "first").unwrap();
        let new = reports.write("same", "scan.json", "second").unwrap();
        assert_ne!(old, new);
        assert!(new
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .ends_with("_scan.json"));
        assert_eq!(fs::read_to_string(old).unwrap(), "first");
        assert_eq!(fs::read_to_string(new).unwrap(), "second");
        assert_eq!(
            fs::read_to_string(scratch.0.join("unrelated.txt")).unwrap(),
            "preserve"
        );
        assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 3);
    }

    #[test]
    fn concurrent_writers_publish_distinct_complete_files() {
        let scratch = Scratch::new();
        let dir = &scratch.0;
        let paths = std::thread::scope(|s| {
            let jobs: Vec<_> = (0..12)
                .map(|n| {
                    s.spawn(move || {
                        let reports =
                            ReportDirectory::from_override(Some(dir.as_os_str())).unwrap();
                        let content = format!("report-{n}").repeat(1000);
                        let path = reports.write("same", "scan.json", &content).unwrap();
                        assert_eq!(fs::read_to_string(&path).unwrap(), content);
                        path
                    })
                })
                .collect();
            jobs.into_iter()
                .map(|j| j.join().unwrap())
                .collect::<std::collections::HashSet<_>>()
        });
        assert_eq!(paths.len(), 12);
        assert_eq!(fs::read_dir(dir).unwrap().count(), 12);
    }

    #[test]
    fn rejected_overrides_do_not_create_directories_or_fallback() {
        let scratch = Scratch::new();
        let file = scratch.0.join("file");
        fs::write(&file, "keep").unwrap();
        for path in [
            PathBuf::new(),
            PathBuf::from("relative"),
            scratch.0.join("missing"),
            file,
            scratch.0.join("..").join("escape"),
            scratch.0.ancestors().last().unwrap().to_path_buf(),
        ] {
            assert!(
                ReportDirectory::from_override(Some(path.as_os_str())).is_err(),
                "{path:?}"
            );
        }
        assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 1);
    }

    #[test]
    fn report_names_cannot_escape_the_destination() {
        let scratch = Scratch::new();
        for name in ["", "../escape", "a/b", "a\\b", "a\n"] {
            assert!(scratch.reports().write(name, "scan.json", "bad").is_err());
            assert!(scratch.reports().write("valid", name, "bad").is_err());
        }
        assert_eq!(fs::read_dir(&scratch.0).unwrap().count(), 0);
    }

    #[test]
    fn removed_directory_fails_without_recreation_or_fallback() {
        let scratch = Scratch::new();
        let reports = scratch.reports();
        fs::remove_dir(&scratch.0).unwrap();
        assert!(reports.write("same", "scan.json", "bad").is_err());
        assert!(!scratch.0.exists());
        fs::create_dir(&scratch.0).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn symlink_directory_or_ancestor_is_rejected() {
        use std::os::unix::fs::symlink;
        let scratch = Scratch::new();
        let real = scratch.0.join("real");
        fs::create_dir(&real).unwrap();
        fs::create_dir(real.join("nested")).unwrap();
        let link = scratch.0.join("link");
        symlink(&real, &link).unwrap();
        for path in [&link, &link.join("nested")] {
            assert!(ReportDirectory::from_override(Some(path.as_os_str())).is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn colliding_symlink_does_not_overwrite_target() {
        use std::os::unix::fs::symlink;
        let scratch = Scratch::new();
        let target = scratch.0.join("unrelated");
        fs::write(&target, "preserve").unwrap();
        symlink(&target, scratch.0.join("same_scan.json")).unwrap();
        let path = scratch.reports().write("same", "scan.json", "new").unwrap();
        assert_ne!(path, scratch.0.join("same_scan.json"));
        assert_eq!(fs::read_to_string(&target).unwrap(), "preserve");
        assert_eq!(fs::read_to_string(path).unwrap(), "new");
    }
}
