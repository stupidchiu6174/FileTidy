//! 列出單一資料夾的內容(瀏覽視窗用)。

use crate::index::is_hidden_or_system;
use serde::Serialize;
use std::path::Path;

#[derive(Clone, Debug, Serialize)]
pub struct Entry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: i64,
    pub hidden: bool,
}

pub fn list_dir(dir: &Path, show_hidden: bool) -> std::io::Result<Vec<Entry>> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir)?.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        // metadata() 會跟隨捷徑/連結;壞掉的連結就用連結本身的資訊
        let Ok(md) = e.metadata().or_else(|_| e.path().symlink_metadata()) else { continue };
        let hidden = name.starts_with('.') || is_hidden_or_system(&md);
        if hidden && !show_hidden {
            continue;
        }
        out.push(Entry {
            path: e.path().to_string_lossy().into_owned(),
            is_dir: md.is_dir(),
            size: if md.is_dir() { 0 } else { md.len() },
            modified: md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_secs() as i64),
            hidden,
            name,
        });
    }
    out.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then_with(|| natural_cmp(&a.name, &b.name)));
    Ok(out)
}

/// 和檔案總管一樣的「自然排序」:file2 排在 file10 前面,不分大小寫。
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut na = String::new();
                while let Some(c) = a.peek().copied().filter(char::is_ascii_digit) {
                    na.push(c);
                    a.next();
                }
                let mut nb = String::new();
                while let Some(c) = b.peek().copied().filter(char::is_ascii_digit) {
                    nb.push(c);
                    b.next();
                }
                let (ta, tb) = (na.trim_start_matches('0'), nb.trim_start_matches('0'));
                let o = ta.len().cmp(&tb.len()).then_with(|| ta.cmp(tb));
                if o != Ordering::Equal {
                    return o;
                }
            }
            (Some(x), Some(y)) => {
                let o = x.to_lowercase().cmp(y.to_lowercase());
                if o != Ordering::Equal {
                    return o;
                }
                a.next();
                b.next();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn natural_sort() {
        let mut v = vec!["file10", "File2", "file1", "a"];
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, ["a", "file1", "File2", "file10"]);
    }

    #[test]
    fn lists_folders_first_and_hides_dotfiles() {
        let t = tempfile::tempdir().unwrap();
        std::fs::create_dir(t.path().join("zdir")).unwrap();
        std::fs::write(t.path().join("a.txt"), "hi").unwrap();
        std::fs::write(t.path().join(".hidden"), "").unwrap();
        let names: Vec<String> = list_dir(t.path(), false).unwrap().into_iter().map(|e| e.name).collect();
        assert_eq!(names, ["zdir", "a.txt"]);
        assert_eq!(list_dir(t.path(), true).unwrap().len(), 3);
    }
}
