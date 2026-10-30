//! 把使用者輸入的路徑(可能不完整、大小寫不對、少了開頭、斜線方向不同)解析成實際存在的位置。
//! 例如 "/downloads" → C:\Users\me\Downloads、"~/doc" → 文件、"desktop\專案" → 桌面\專案、
//! "%USERPROFILE%\下載" → Downloads。找不到時,呼叫端可再用索引依路徑結尾找(`Index::locate`)。

use crate::normalize::fold;
use std::path::{Path, PathBuf};

/// 解析時會嘗試的起點。
#[derive(Clone, Debug)]
pub struct Context {
    pub home: PathBuf,
    /// 目前所在的資料夾
    pub base: Option<PathBuf>,
    /// 磁碟根目錄(Windows:C:\、D:\…;其他系統:/)
    pub drives: Vec<PathBuf>,
}

impl Context {
    pub fn system(base: Option<PathBuf>) -> Self {
        Context { home: home_dir(), base, drives: drive_roots() }
    }
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// 目前存在的磁碟根目錄。
pub fn drive_roots() -> Vec<PathBuf> {
    if cfg!(windows) {
        let system = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into()).to_uppercase();
        let mut v: Vec<PathBuf> = (b'A'..=b'Z')
            .map(|c| PathBuf::from(format!("{}:\\", c as char)))
            .filter(|p| p.exists())
            .collect();
        // 系統磁碟排第一
        v.sort_by_key(|p| !p.to_string_lossy().to_uppercase().starts_with(&system));
        v
    } else {
        vec![PathBuf::from("/")]
    }
}

/// 看起來像路徑的輸入,搜尋框才會嘗試解析成位置。
pub fn looks_like_path(input: &str) -> bool {
    let s = input.trim();
    s.starts_with('~') || s.contains('/') || s.contains('\\') || has_drive(s) || (s.starts_with('%') && s[1..].contains('%'))
}

fn has_drive(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':'
}

/// 依序嘗試各個起點,每一層先找完全相符,再找不分大小寫/常見的本地化名稱(「下載」→ Downloads);
/// 都找不到時才接受唯一的開頭相符("/down" → Downloads)。
pub fn resolve(input: &str, ctx: &Context) -> Option<PathBuf> {
    let mut s = input.trim().to_string();
    if s.len() >= 2 {
        let (f, l) = (s.chars().next().unwrap(), s.chars().last().unwrap());
        if f == l && (f == '"' || f == '\'') {
            s = s[1..s.len() - 1].to_string();
        }
    }
    if let Some(rest) = s.strip_prefix("file://") {
        s = percent_decode(rest.strip_prefix('/').filter(|r| has_drive(r)).unwrap_or(rest));
    }
    s = expand_env(&s);
    let s = s.replace('\\', "/");
    if s.is_empty() {
        return None;
    }

    // 網路路徑(\\server\share)不猜,存在就用
    if s.starts_with("//") {
        let p = PathBuf::from(if cfg!(windows) { s.replace('/', "\\") } else { s.clone() });
        return p.exists().then_some(p);
    }

    let (roots, rest): (Vec<PathBuf>, &str) = if s == "~" || s.starts_with("~/") {
        (vec![ctx.home.clone()], &s[1..])
    } else if has_drive(&s) {
        let sep = if cfg!(windows) { '\\' } else { '/' };
        (vec![PathBuf::from(format!("{}{sep}", &s[..2].to_uppercase()))], &s[2..])
    } else if s.starts_with('/') {
        // Unix 的絕對路徑一定從 / 開始找;Windows 的 "\xxx" 則是目前磁碟的根目錄
        let mut r: Vec<PathBuf> = if cfg!(windows) { vec![] } else { vec![PathBuf::from("/")] };
        r.extend(ctx.drives.iter().cloned());
        r.push(ctx.home.clone());
        r.extend(ctx.base.clone());
        (r, s.as_str())
    } else {
        let mut r: Vec<PathBuf> = ctx.base.iter().cloned().collect();
        r.push(ctx.home.clone());
        r.extend(ctx.drives.iter().cloned());
        (r, s.as_str())
    };
    let components: Vec<&str> = rest.split('/').filter(|c| !c.is_empty()).collect();

    let mut seen = std::collections::HashSet::new();
    let roots: Vec<PathBuf> = roots.into_iter().filter(|r| seen.insert(fold(&r.to_string_lossy()))).collect();
    for allow_prefix in [false, true] {
        for root in &roots {
            if let Some(p) = walk(root, &components, allow_prefix) {
                return Some(p);
            }
        }
    }
    None
}

fn walk(root: &Path, components: &[&str], allow_prefix: bool) -> Option<PathBuf> {
    let mut cur = root.to_path_buf();
    for c in components {
        match *c {
            "." => continue,
            ".." => {
                cur.pop();
                continue;
            }
            _ => {}
        }
        cur = child(&cur, c, allow_prefix)?;
    }
    cur.exists().then_some(cur)
}

fn child(dir: &Path, name: &str, allow_prefix: bool) -> Option<PathBuf> {
    let Ok(rd) = std::fs::read_dir(dir) else {
        let exact = dir.join(name);
        return exact.exists().then_some(exact);
    };
    // 用實際列出的名稱,讓顯示的路徑大小寫正確
    let names: Vec<String> = rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    if names.iter().any(|n| n == name) {
        return Some(dir.join(name));
    }
    let key = fold(name);
    if let Some(n) = names.iter().find(|n| fold(n) == key) {
        return Some(dir.join(n));
    }
    if let Some(canonical) = known_folder_alias(&key) {
        if let Some(n) = names.iter().find(|n| fold(n) == canonical) {
            return Some(dir.join(n));
        }
    }
    // 列表裡沒有、但實際存在:Windows 的 8.3 短檔名(RUNNER~1)、不列出的連結
    let exact = dir.join(name);
    if exact.exists() {
        return Some(exact);
    }
    if !allow_prefix {
        return None;
    }
    let prefixed: Vec<&String> = names.iter().filter(|n| !n.starts_with('.') && fold(n).starts_with(&key)).collect();
    (prefixed.len() == 1).then(|| dir.join(prefixed[0]))
}

/// 系統資料夾在不同語言下的名稱(Windows 檔案總管與 macOS 會顯示本地化名稱,實際資料夾名是英文)。
fn known_folder_alias(key: &str) -> Option<&'static str> {
    const ALIASES: &[(&str, &[&str])] = &[
        ("downloads", &["下載", "下載項目", "下载", "ダウンロード"]),
        ("desktop", &["桌面", "デスクトップ"]),
        ("documents", &["文件", "文檔", "文档", "我的文件", "ドキュメント", "書類"]),
        ("pictures", &["圖片", "图片", "相片", "ピクチャ"]),
        ("videos", &["影片", "視訊", "视频", "ビデオ", "movies"]),
        ("movies", &["ムービー"]),
        ("music", &["音樂", "音乐", "ミュージック"]),
    ];
    ALIASES.iter().find(|(_, names)| names.iter().any(|n| fold(n) == key)).map(|(c, _)| *c)
}

/// %USERPROFILE%、%OneDrive% 這類環境變數。
fn expand_env(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(start) = rest.find('%') {
        let after = &rest[start + 1..];
        let Some(end) = after.find('%') else { break };
        let var = &after[..end];
        match std::env::var(var).ok().or_else(|| (var.eq_ignore_ascii_case("userprofile")).then(|| home_dir().to_string_lossy().into_owned())) {
            Some(v) if !var.is_empty() => {
                out.push_str(&rest[..start]);
                out.push_str(&v);
            }
            _ => out.push_str(&rest[..start + end + 2]),
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() && b[i + 1].is_ascii_hexdigit() && b[i + 2].is_ascii_hexdigit() {
            let hex = |c: u8| (c as char).to_digit(16).unwrap() as u8;
            out.push(hex(b[i + 1]) * 16 + hex(b[i + 2]));
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn setup() -> (tempfile::TempDir, Context) {
        let t = tempfile::tempdir().unwrap();
        for d in ["Downloads", "Documents/Projects/年度報告", "Desktop"] {
            fs::create_dir_all(t.path().join(d)).unwrap();
        }
        fs::write(t.path().join("Documents/Projects/notes.txt"), "x").unwrap();
        let ctx = Context { home: t.path().to_path_buf(), base: None, drives: vec![] };
        (t, ctx)
    }

    #[test]
    fn finds_incomplete_paths() {
        let (t, ctx) = setup();
        let h = t.path();
        let r = |s: &str| resolve(s, &ctx);
        assert_eq!(r("/downloads"), Some(h.join("Downloads")));
        assert_eq!(r("\\downloads\\"), Some(h.join("Downloads")));
        assert_eq!(r("~/downloads"), Some(h.join("Downloads")));
        assert_eq!(r("~"), Some(h.to_path_buf()));
        assert_eq!(r("documents/projects"), Some(h.join("Documents").join("Projects")));
        assert_eq!(r("documents\\projects"), Some(h.join("Documents").join("Projects")));
        assert_eq!(r("~/doc/proj/年度"), Some(h.join("Documents").join("Projects").join("年度報告")));
        assert_eq!(r("~/Documents/Projects/NOTES.TXT"), Some(h.join("Documents").join("Projects").join("notes.txt")));
        assert_eq!(r("\"~/desktop\""), Some(h.join("Desktop")));
        assert_eq!(r("/下載"), Some(h.join("Downloads")));
        assert_eq!(r("~/ダウンロード"), Some(h.join("Downloads")));
        assert_eq!(r("~/d"), None); // Downloads/Documents/Desktop 都符合 → 不猜
        assert_eq!(r("/no-such-folder-xyz"), None);
    }

    #[test]
    fn relative_to_current_folder_first() {
        let (t, mut ctx) = setup();
        ctx.base = Some(t.path().join("Documents"));
        assert_eq!(resolve("projects", &ctx), Some(t.path().join("Documents").join("Projects")));
    }

    #[test]
    fn absolute_and_env_paths() {
        let (t, ctx) = setup();
        let abs = t.path().join("Downloads");
        assert_eq!(resolve(&abs.to_string_lossy(), &ctx), Some(abs.clone()));
        // 大小寫不對的完整路徑,回傳實際的大小寫
        assert_eq!(resolve(&t.path().join("downloads").to_string_lossy(), &ctx), Some(abs.clone()));
        std::env::set_var("FILETIDY_TEST_DIR", t.path());
        assert_eq!(resolve("%FILETIDY_TEST_DIR%/downloads", &ctx), Some(abs));
    }

    #[test]
    fn detects_path_like_input() {
        assert!(looks_like_path("/downloads"));
        assert!(looks_like_path("Backups\\x"));
        assert!(looks_like_path("C:"));
        assert!(looks_like_path("~"));
        assert!(looks_like_path("%USERPROFILE%"));
        assert!(!looks_like_path("downloads"));
        assert!(!looks_like_path("50%"));
    }
}
