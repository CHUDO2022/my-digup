//! What the analysis window does to files (своя версия): into quarantine (out of the way, not deleted: it can go back),
//! into a folder the person picks, back to where it was, or deleted for good from quarantine. Every move is written to
//! a journal (journal.json in the quarantine folder), so it can be undone later, after a restart too.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    /// Where it was.
    pub original: String,
    /// Where it is now.
    pub stored: String,
    pub size: u64,
    /// Seconds since 1970.
    pub at: u64,
    /// "quarantine" or "moved".
    pub kind: String,
}

pub struct Files {
    folder: PathBuf,
}

impl Files {
    /// `folder`: where quarantined files and the journal live (beside the index).
    pub fn new(folder: PathBuf) -> Files {
        Files { folder }
    }

    fn journal_path(&self) -> PathBuf {
        self.folder.join("journal.json")
    }

    pub fn journal(&self) -> Vec<Entry> {
        std::fs::read(self.journal_path()).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
    }

    fn save(&self, entries: &[Entry]) -> Result<(), String> {
        std::fs::create_dir_all(&self.folder).map_err(|e| e.to_string())?;
        let temporary = self.journal_path().with_extension("json.new");
        std::fs::write(&temporary, serde_json::to_vec_pretty(entries).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        std::fs::rename(temporary, self.journal_path()).map_err(|e| e.to_string())
    }

    /// Moves `paths` into quarantine (`folder` None) or into `folder`. Returns what moved and what didn't (and why).
    pub fn take(&self, paths: &[String], folder: Option<&Path>) -> Value {
        let mut entries = self.journal();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let batch = format!("{}", SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0));
        let (mut moved, mut failed) = (Vec::new(), Vec::new());
        for (index, path) in paths.iter().enumerate() {
            let source = PathBuf::from(path);
            let Some(name) = source.file_name() else { continue };
            let target_folder = match folder {
                Some(folder) => folder.to_path_buf(),
                None => self.folder.join(&batch),
            };
            let target = free_name(&target_folder.join(name));
            let size = std::fs::metadata(&source).map(|m| m.len()).unwrap_or(0);
            match move_file(&source, &target) {
                Ok(()) => {
                    entries.push(Entry {
                        id: format!("{batch}-{index}"),
                        original: path.clone(),
                        stored: target.display().to_string(),
                        size,
                        at: now,
                        kind: if folder.is_some() { "moved" } else { "quarantine" }.into(),
                    });
                    moved.push(path.clone());
                }
                Err(error) => failed.push(json!({"path": path, "error": error})),
            }
        }
        let saved = self.save(&entries);
        json!({"moved": moved, "failed": failed, "journal": saved.err()})
    }

    /// Puts these entries' files back where they were.
    pub fn restore(&self, ids: &[String]) -> Value {
        let mut entries = self.journal();
        let (mut restored, mut failed) = (Vec::new(), Vec::new());
        entries.retain(|entry| {
            if !ids.contains(&entry.id) {
                return true;
            }
            let back = free_name(Path::new(&entry.original));
            match move_file(Path::new(&entry.stored), &back) {
                Ok(()) => {
                    restored.push(back.display().to_string());
                    false
                }
                Err(error) => {
                    failed.push(json!({"path": entry.original, "error": error}));
                    true
                }
            }
        });
        let saved = self.save(&entries);
        self.tidy();
        json!({"restored": restored, "failed": failed, "journal": saved.err()})
    }

    /// Deletes quarantined files for good (moved ones are only forgotten: they're the person's files where they put
    /// them).
    pub fn purge(&self, ids: &[String]) -> Value {
        let mut entries = self.journal();
        let (mut deleted, mut failed) = (0u64, Vec::new());
        entries.retain(|entry| {
            if !ids.contains(&entry.id) {
                return true;
            }
            if entry.kind != "quarantine" {
                return false;
            }
            match std::fs::remove_file(&entry.stored) {
                Ok(()) => {
                    deleted += entry.size;
                    false
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
                Err(error) => {
                    failed.push(json!({"path": entry.original, "error": error.to_string()}));
                    true
                }
            }
        });
        let saved = self.save(&entries);
        self.tidy();
        json!({"bytes": deleted, "failed": failed, "journal": saved.err()})
    }

    /// Empty batch folders go.
    fn tidy(&self) {
        if let Ok(read) = std::fs::read_dir(&self.folder) {
            for item in read.flatten() {
                if item.path().is_dir() {
                    let _ = std::fs::remove_dir(item.path());   // only when empty
                }
            }
        }
    }
}

/// `path`, or "name (2).ext", "name (3).ext"… when that's taken.
fn free_name(path: &Path) -> PathBuf {
    if !path.exists() {
        return path.to_path_buf();
    }
    let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let extension = path.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    let parent = path.parent().map(Path::to_path_buf).unwrap_or_default();
    (2..10_000)
        .map(|n| parent.join(format!("{stem} ({n}){extension}")))
        .find(|candidate| !candidate.exists())
        .unwrap_or_else(|| path.to_path_buf())
}

/// A rename where it can (same disk: instant), else a copy and then the original removed.
fn move_file(source: &Path, target: &Path) -> Result<(), String> {
    if !source.is_file() {
        return Err("файла нет на месте".into());
    }
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    if std::fs::rename(source, target).is_ok() {
        return Ok(());
    }
    std::fs::copy(source, target).map_err(|e| e.to_string())?;
    let copied = std::fs::metadata(target).map(|m| m.len()).unwrap_or(0);
    let original = std::fs::metadata(source).map(|m| m.len()).unwrap_or(1);
    if copied != original {
        let _ = std::fs::remove_file(target);
        return Err("копия вышла неполной".into());
    }
    std::fs::remove_file(source).map_err(|e| e.to_string())
}
