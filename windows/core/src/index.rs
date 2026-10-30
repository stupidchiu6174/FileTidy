//! 全機檔名索引:背景建立,搜尋時全部在記憶體裡比對。
//! macOS 版用 FSEvents 即時更新;這裡先做「重建索引」,資料夾操作後由呼叫端重建或略過。

use crate::normalize::{fold, fuzzy, normalize, score_normalized};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};

/// 不往下列舉的資料夾(開發工具快取)
pub const SKIP_DIRS: &[&str] = &[
    ".git", "node_modules", ".build", "DerivedData", "Pods", ".Trash", "__pycache__", ".venv", "venv", ".gradle",
    ".cache", "Caches", ".npm", ".cargo", ".rustup",
];

/// 只在索引根目錄(個人資料夾、磁碟根目錄)略過的系統資料夾
pub const ROOT_SKIP_DIRS: &[&str] = &[
    "AppData", "Library", "System Volume Information", "Windows", "Program Files", "Program Files (x86)",
    "ProgramData", "Recovery", "OneDriveTemp",
];

pub fn should_skip(name: &str, at_root: bool) -> bool {
    let eq = |list: &[&str]| list.iter().any(|s| s.eq_ignore_ascii_case(name));
    name.starts_with('.') || name.starts_with('$') || eq(SKIP_DIRS) || (at_root && eq(ROOT_SKIP_DIRS))
}

#[derive(Clone, Debug)]
struct Item {
    path: String,
    /// fold 後、分隔符號統一為 / 的完整路徑(範圍比對、路徑結尾比對用)
    key: String,
    norm: String,
    mask: u64,
    parent: u32,
    is_dir: bool,
    size: u64,
    modified: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct Hit {
    pub path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: i64,
    pub score: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct Status {
    pub crawling: bool,
    pub count: usize,
}

#[derive(Default)]
struct Data {
    items: Vec<Item>,
    dir_norms: Vec<String>,
}

#[derive(Clone)]
pub struct Index {
    roots: Arc<Vec<PathBuf>>,
    data: Arc<RwLock<Data>>,
    crawling: Arc<AtomicBool>,
    found: Arc<AtomicUsize>,
}

/// 預設範圍:個人資料夾,以及系統磁碟以外的磁碟(外接硬碟、D:\…)。
pub fn default_roots() -> Vec<PathBuf> {
    let home = crate::resolver::home_dir();
    let mut roots = vec![home.clone()];
    if cfg!(windows) {
        let system = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into()).to_uppercase();
        roots.extend(
            crate::resolver::drive_roots()
                .into_iter()
                .filter(|d| !d.to_string_lossy().to_uppercase().starts_with(&system)),
        );
    }
    roots
}

pub fn path_key(p: &str) -> String {
    fold(&p.replace('\\', "/"))
}

fn mask(s: &str) -> u64 {
    s.chars().fold(0u64, |m, c| m | 1 << (c as u32 % 64))
}

fn mtime(md: &std::fs::Metadata) -> i64 {
    md.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs() as i64)
}

#[cfg(windows)]
pub fn is_hidden_or_system(md: &std::fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    md.file_attributes() & (0x2 | 0x4) != 0 // HIDDEN | SYSTEM
}
#[cfg(not(windows))]
pub fn is_hidden_or_system(_md: &std::fs::Metadata) -> bool {
    false
}

impl Index {
    pub fn new(roots: Vec<PathBuf>) -> Self {
        Index {
            roots: Arc::new(roots),
            data: Arc::default(),
            crawling: Arc::default(),
            found: Arc::default(),
        }
    }

    pub fn status(&self) -> Status {
        let crawling = self.crawling.load(Ordering::Relaxed);
        let count = if crawling { self.found.load(Ordering::Relaxed) } else { self.data.read().unwrap().items.len() };
        Status { crawling, count }
    }

    /// 在背景執行緒重建;已經在建立時不重複啟動。
    pub fn rebuild_in_background(&self) {
        if self.crawling.swap(true, Ordering::SeqCst) {
            return;
        }
        let me = self.clone();
        std::thread::spawn(move || me.crawl());
    }

    /// 同步建立(測試用,或呼叫端自己開執行緒)
    pub fn rebuild(&self) {
        self.crawling.store(true, Ordering::SeqCst);
        self.crawl();
    }

    fn crawl(&self) {
        self.found.store(0, Ordering::Relaxed);
        let mut data = Data::default();
        let mut stack: Vec<(PathBuf, u32, bool)> = Vec::new();
        for root in self.roots.iter() {
            data.dir_norms.push(normalize(&root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()));
            stack.push((root.clone(), (data.dir_norms.len() - 1) as u32, true));
        }
        while let Some((dir, parent, at_root)) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&dir) else { continue };
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                let Ok(ft) = e.file_type() else { continue };
                if ft.is_symlink() || should_skip(&name, at_root) {
                    continue;
                }
                let Ok(md) = e.metadata() else { continue };
                if is_hidden_or_system(&md) {
                    continue;
                }
                let path = e.path().to_string_lossy().into_owned();
                let norm = normalize(&name);
                if ft.is_dir() {
                    data.dir_norms.push(norm.clone());
                    stack.push((e.path(), (data.dir_norms.len() - 1) as u32, false));
                }
                data.items.push(Item {
                    key: path_key(&path),
                    mask: mask(&norm),
                    norm,
                    path,
                    parent,
                    is_dir: ft.is_dir(),
                    size: if ft.is_dir() { 0 } else { md.len() },
                    modified: mtime(&md),
                });
                self.found.fetch_add(1, Ordering::Relaxed);
            }
        }
        *self.data.write().unwrap() = data;
        self.crawling.store(false, Ordering::SeqCst);
    }

    /// 完全相符 > 前綴 > 包含 > 多關鍵字全中 > 所在資料夾名稱相符 > 容錯比對(精確結果太少時才做)
    pub fn search(&self, query: &str, scope: Option<&Path>, limit: usize) -> Vec<Hit> {
        let q = normalize(query.trim());
        if q.is_empty() {
            return vec![];
        }
        let qmask = mask(&q);
        let scope = scope.map(|s| {
            let k = path_key(&s.to_string_lossy());
            if k.ends_with('/') { k } else { k + "/" }
        });
        let data = self.data.read().unwrap();
        let mut hits: Vec<(f64, &Item)> = Vec::new();
        let mut weak: Vec<&Item> = Vec::new();
        for item in &data.items {
            if let Some(scope) = &scope {
                if !item.key.starts_with(scope.as_str()) {
                    continue;
                }
            }
            let mut s = score_normalized(query, &q, &item.norm);
            if s >= 0.85 {
                hits.push((s, item));
                continue;
            }
            if data.dir_norms.get(item.parent as usize).is_some_and(|d| d.contains(q.as_str())) {
                s = 0.6;
                hits.push((s, item));
            } else if item.mask & qmask == qmask {
                weak.push(item);
            }
        }
        if hits.len() < 30 {
            for item in weak {
                let s = fuzzy(&q, &item.norm);
                if s >= 0.35 {
                    hits.push((s, item));
                }
            }
        }
        hits.sort_by(|a, b| b.0.total_cmp(&a.0).then(b.1.modified.cmp(&a.1.modified)));
        hits.truncate(limit);
        hits.into_iter()
            .map(|(score, i)| Hit {
                name: Path::new(&i.path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                path: i.path.clone(),
                is_dir: i.is_dir,
                size: i.size,
                modified: i.modified,
                score,
            })
            .collect()
    }

    /// 依路徑的結尾找位置,例如 "Backups/psd1029_b1" 可以找到 D:\Work\Backups\psd1029_b1。
    /// 有多個符合時:資料夾優先,再來是路徑較短的,最後是最近修改的。
    pub fn locate(&self, input: &str) -> Option<PathBuf> {
        let cleaned = input.trim().trim_matches(|c| c == '"' || c == '\'').replace('\\', "/");
        let comps: Vec<&str> = cleaned.split('/').filter(|c| !c.is_empty() && *c != "." && *c != "~").collect();
        if comps.contains(&"..") || comps.first().is_some_and(|c| c.ends_with(':')) {
            return None;
        }
        let last = normalize(comps.last()?);
        if last.is_empty() {
            return None;
        }
        let suffix = fold(&format!("/{}", comps.join("/")));
        let data = self.data.read().unwrap();
        data.items
            .iter()
            .filter(|i| i.norm == last && i.key.ends_with(&suffix))
            .min_by(|a, b| {
                b.is_dir
                    .cmp(&a.is_dir)
                    .then(a.path.len().cmp(&b.path.len()))
                    .then(b.modified.cmp(&a.modified))
            })
            .map(|i| PathBuf::from(&i.path))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn search_and_locate() {
        let t = tempfile::tempdir().unwrap();
        let d = t.path();
        fs::create_dir_all(d.join("旅行")).unwrap();
        fs::create_dir_all(d.join("node_modules/pkg")).unwrap();
        fs::create_dir_all(d.join("Documents/Backups/psd1029_b1_20261030_094935")).unwrap();
        fs::create_dir_all(d.join("Archive/old/deep/Backups/other")).unwrap();
        for f in ["My Photo 01.jpg", "budget.xlsx", "旅行/IMG_2031.heic", "node_modules/pkg/hidden.js"] {
            fs::write(d.join(f), "x").unwrap();
        }
        let idx = Index::new(vec![d.to_path_buf()]);
        idx.rebuild();
        assert!(!idx.status().crawling);

        let name = |q: &str| idx.search(q, None, 300).first().map(|h| h.name.clone());
        assert_eq!(name("myphoto").as_deref(), Some("My Photo 01.jpg"));
        assert_eq!(name("photo my").as_deref(), Some("My Photo 01.jpg"));
        assert!(idx.search("旅 行", None, 300).iter().any(|h| h.name == "IMG_2031.heic"), "應靠所在資料夾名稱找到");
        assert!(idx.search("hidden", None, 300).is_empty(), "node_modules 內容不應被索引");
        assert!(idx.search("budget", Some(&d.join("旅行")), 300).is_empty(), "範圍外不應出現");

        let found = idx.locate("Backups/psd1029_b1_20261030_094935/").unwrap();
        assert!(found.ends_with("Documents/Backups/psd1029_b1_20261030_094935"));
        assert_eq!(idx.locate("backups\\PSD1029_b1_20261030_094935"), Some(found));
        assert!(idx.locate("/Backups").unwrap().ends_with("Documents/Backups"), "較短的路徑優先");
        assert_eq!(idx.locate("Backups/nope"), None);
    }
}
