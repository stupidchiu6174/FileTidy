//! 空間分析:列出資料夾裡每個項目(含子資料夾全部內容)佔用的大小。

use serde::Serialize;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Debug, Serialize)]
pub struct Usage {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub files: u64,
}

pub fn analyze(dir: &Path, cancel: &AtomicBool) -> Vec<Usage> {
    let Ok(rd) = std::fs::read_dir(dir) else { return vec![] };
    let mut out: Vec<Usage> = rd
        .flatten()
        .filter_map(|e| {
            let ft = e.file_type().ok()?;
            if ft.is_symlink() {
                return None;
            }
            let (size, files) = if ft.is_dir() { total(&e.path(), cancel) } else { (e.metadata().ok()?.len(), 1) };
            Some(Usage {
                name: e.file_name().to_string_lossy().into_owned(),
                path: e.path().to_string_lossy().into_owned(),
                is_dir: ft.is_dir(),
                size,
                files,
            })
        })
        .collect();
    if cancel.load(Ordering::Relaxed) {
        return vec![];
    }
    out.sort_by(|a, b| b.size.cmp(&a.size));
    out
}

fn total(dir: &Path, cancel: &AtomicBool) -> (u64, u64) {
    let (mut size, mut files) = (0, 0);
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_symlink() {
                continue;
            }
            if ft.is_dir() {
                stack.push(e.path());
            } else if let Ok(md) = e.metadata() {
                size += md.len();
                files += 1;
            }
        }
    }
    (size, files)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sums_folder_sizes() {
        let t = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(t.path().join("big/inner")).unwrap();
        std::fs::write(t.path().join("big/inner/x"), vec![0u8; 1000]).unwrap();
        std::fs::write(t.path().join("big/y"), vec![0u8; 500]).unwrap();
        std::fs::write(t.path().join("small"), vec![0u8; 10]).unwrap();
        let u = analyze(t.path(), &AtomicBool::new(false));
        assert_eq!(u[0].name, "big");
        assert_eq!((u[0].size, u[0].files), (1500, 2));
        assert_eq!((u[1].name.as_str(), u[1].size), ("small", 10));
    }
}
