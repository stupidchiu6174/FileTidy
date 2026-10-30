//! 重複檔:先比大小,再比前 64KB 雜湊,最後比完整 SHA-256,避免對每個檔案都整檔讀取。

use crate::index::{is_hidden_or_system, should_skip};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Debug, Serialize)]
pub struct DupFile {
    pub path: String,
    pub name: String,
    pub modified: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct DupGroup {
    pub size: u64,
    pub wasted: u64,
    /// 最舊的排第一(建議保留)
    pub files: Vec<DupFile>,
}

/// 掃描 `root` 底下所有檔案找重複。`cancel` 設成 true 時盡快停止並回傳空結果。
pub fn find(root: &Path, cancel: &AtomicBool) -> Vec<DupGroup> {
    let mut by_size: HashMap<u64, Vec<(PathBuf, i64)>> = HashMap::new();
    let mut stack = vec![(root.to_path_buf(), true)];
    while let Some((dir, at_root)) = stack.pop() {
        if cancel.load(Ordering::Relaxed) {
            return vec![];
        }
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            let (Ok(ft), Ok(md)) = (e.file_type(), e.metadata()) else { continue };
            if ft.is_symlink() || should_skip(&name, at_root) || is_hidden_or_system(&md) {
                continue;
            }
            if ft.is_dir() {
                stack.push((e.path(), false));
            } else if md.len() > 0 {
                let modified = md
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map_or(0, |d| d.as_secs() as i64);
                by_size.entry(md.len()).or_default().push((e.path(), modified));
            }
        }
    }

    let mut groups = Vec::new();
    for (size, same_size) in by_size.into_iter().filter(|(_, v)| v.len() > 1) {
        let mut by_partial: HashMap<[u8; 32], Vec<(PathBuf, i64)>> = HashMap::new();
        for f in same_size {
            if cancel.load(Ordering::Relaxed) {
                return vec![];
            }
            if let Some(h) = hash(&f.0, Some(64 * 1024)) {
                by_partial.entry(h).or_default().push(f);
            }
        }
        for partial in by_partial.into_values().filter(|v| v.len() > 1) {
            let mut by_full: HashMap<[u8; 32], Vec<(PathBuf, i64)>> = HashMap::new();
            if size <= 64 * 1024 {
                by_full.insert([0; 32], partial); // 前 64KB 就是整個檔案
            } else {
                for f in partial {
                    if cancel.load(Ordering::Relaxed) {
                        return vec![];
                    }
                    if let Some(h) = hash(&f.0, None) {
                        by_full.entry(h).or_default().push(f);
                    }
                }
            }
            for mut same in by_full.into_values().filter(|v| v.len() > 1) {
                same.sort_by_key(|f| f.1);
                groups.push(DupGroup {
                    size,
                    wasted: size * (same.len() as u64 - 1),
                    files: same
                        .into_iter()
                        .map(|(p, modified)| DupFile {
                            name: p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                            path: p.to_string_lossy().into_owned(),
                            modified,
                        })
                        .collect(),
                });
            }
        }
    }
    groups.sort_by(|a, b| b.wasted.cmp(&a.wasted));
    groups
}

fn hash(path: &Path, limit: Option<u64>) -> Option<[u8; 32]> {
    let f = std::fs::File::open(path).ok()?;
    let mut reader: Box<dyn Read> = match limit {
        Some(n) => Box::new(f.take(n)),
        None => Box::new(f),
    };
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = reader.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(hasher.finalize().into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_identical_files_only() {
        let t = tempfile::tempdir().unwrap();
        let d = t.path();
        std::fs::create_dir(d.join("sub")).unwrap();
        std::fs::write(d.join("a.txt"), "same content").unwrap();
        std::fs::write(d.join("sub/b.txt"), "same content").unwrap();
        std::fs::write(d.join("c.txt"), "diff content").unwrap(); // 同大小不同內容
        let big = vec![7u8; 200 * 1024];
        let mut big2 = big.clone();
        *big2.last_mut().unwrap() = 8; // 前 64KB 相同,結尾不同
        std::fs::write(d.join("big1.bin"), &big).unwrap();
        std::fs::write(d.join("big2.bin"), &big2).unwrap();
        std::fs::write(d.join("big3.bin"), &big).unwrap();

        let groups = find(d, &AtomicBool::new(false));
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].files.len(), 2);
        assert!(groups[0].files.iter().all(|f| f.name.starts_with("big") && f.name != "big2.bin"));
        let mut small: Vec<&str> = groups[1].files.iter().map(|f| f.name.as_str()).collect();
        small.sort();
        assert_eq!(small, ["a.txt", "b.txt"]);
    }
}
