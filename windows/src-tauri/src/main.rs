// 發行版不要多開一個主控台視窗
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use filetidy_core::{dupes, index, listing, resolver, usage};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::State;

struct AppState {
    index: index::Index,
    /// 目前這次重複檔/空間分析的停止旗標;開始新的一次或換頁時,舊的會被設成 true
    cancel: Mutex<Arc<AtomicBool>>,
}

type Res<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

#[derive(Serialize)]
struct Place {
    /// 介面翻譯用的代號(home、desktop…);磁碟是 "drive"
    key: &'static str,
    name: String,
    path: String,
}

#[tauri::command]
fn places() -> Vec<Place> {
    let mut v = Vec::new();
    let known: [(&'static str, Option<PathBuf>); 7] = [
        ("home", dirs::home_dir()),
        ("desktop", dirs::desktop_dir()),
        ("documents", dirs::document_dir()),
        ("downloads", dirs::download_dir()),
        ("pictures", dirs::picture_dir()),
        ("music", dirs::audio_dir()),
        ("videos", dirs::video_dir()),
    ];
    for (key, p) in known {
        if let Some(p) = p.filter(|p| p.is_dir()) {
            v.push(Place { key, name: String::new(), path: p.to_string_lossy().into_owned() });
        }
    }
    for d in resolver::drive_roots() {
        let s = d.to_string_lossy().into_owned();
        let name = s.trim_end_matches(['\\', '/']).to_string();
        v.push(Place { key: "drive", name: if name.is_empty() { s.clone() } else { name }, path: s });
    }
    v
}

#[tauri::command]
fn list_dir(path: String, show_hidden: bool) -> Res<Vec<listing::Entry>> {
    listing::list_dir(Path::new(&path), show_hidden).map_err(err)
}

#[derive(Serialize)]
struct Crumb {
    name: String,
    path: String,
}

/// 路徑列每一層(C:\ › Users › me › Downloads)
#[tauri::command]
fn crumbs(path: String) -> Vec<Crumb> {
    let mut list: Vec<Crumb> = Path::new(&path)
        .ancestors()
        .map(|p| {
            let s = p.to_string_lossy().into_owned();
            let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| s.trim_end_matches(['\\', '/']).to_string());
            Crumb { name: if name.is_empty() { s.clone() } else { name }, path: s }
        })
        .collect();
    list.reverse();
    list
}

#[tauri::command]
fn parent(path: String) -> Option<String> {
    Path::new(&path).parent().map(|p| p.to_string_lossy().into_owned())
}

#[derive(Serialize)]
struct Resolved {
    path: String,
    is_dir: bool,
}

#[tauri::command]
fn looks_like_path(input: String) -> bool {
    resolver::looks_like_path(&input)
}

/// 不完整的路徑:先在根目錄/個人資料夾/目前資料夾底下找,找不到再用索引依路徑結尾找
#[tauri::command]
fn resolve_path(state: State<AppState>, input: String, base: Option<String>) -> Option<Resolved> {
    let ctx = resolver::Context::system(base.map(PathBuf::from));
    let p = resolver::resolve(&input, &ctx).or_else(|| state.index.locate(&input))?;
    Some(Resolved { is_dir: p.is_dir(), path: p.to_string_lossy().into_owned() })
}

#[tauri::command]
async fn search(state: State<'_, AppState>, query: String, scope: Option<String>) -> Res<Vec<index::Hit>> {
    let idx = state.index.clone();
    tauri::async_runtime::spawn_blocking(move || idx.search(&query, scope.as_deref().map(Path::new), 300))
        .await
        .map_err(err)
}

#[tauri::command]
fn index_status(state: State<AppState>) -> index::Status {
    state.index.status()
}

#[tauri::command]
fn rebuild_index(state: State<AppState>) {
    state.index.rebuild_in_background();
}

#[tauri::command]
fn open_path(path: String) -> Res<()> {
    open::that_detached(&path).map_err(err)
}

/// 在檔案總管中顯示並選取
#[tauri::command]
fn reveal(path: String) -> Res<()> {
    #[cfg(windows)]
    {
        std::process::Command::new("explorer").arg(format!("/select,{path}")).spawn().map_err(err)?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let dir = Path::new(&path).parent().unwrap_or(Path::new(&path));
        open::that_detached(dir).map_err(err)
    }
}

#[tauri::command]
fn trash_items(paths: Vec<String>) -> Res<()> {
    trash::delete_all(&paths).map_err(err)
}

#[tauri::command]
fn rename(path: String, new_name: String) -> Res<String> {
    let name = new_name.trim();
    if name.is_empty() || name.contains(['\\', '/', ':', '*', '?', '"', '<', '>', '|']) {
        return Err("invalid-name".into());
    }
    let from = PathBuf::from(&path);
    let to = from.with_file_name(name);
    // 只改大小寫時,Windows 會認為目標已存在
    if to.exists() && !to.to_string_lossy().eq_ignore_ascii_case(&from.to_string_lossy()) {
        return Err("exists".into());
    }
    std::fs::rename(&from, &to).map_err(err)?;
    Ok(to.to_string_lossy().into_owned())
}

/// 建立「未命名資料夾」;同名時加上 2、3…
#[tauri::command]
fn new_folder(dir: String, base_name: String) -> Res<String> {
    let dir = PathBuf::from(dir);
    let mut target = dir.join(&base_name);
    let mut n = 2;
    while target.exists() {
        target = dir.join(format!("{base_name} {n}"));
        n += 1;
    }
    std::fs::create_dir(&target).map_err(err)?;
    Ok(target.to_string_lossy().into_owned())
}

/// 停掉上一次的分析,換一個新的停止旗標
fn fresh_cancel(state: &AppState) -> Arc<AtomicBool> {
    let mut cur = state.cancel.lock().unwrap();
    cur.store(true, Ordering::SeqCst);
    *cur = Arc::new(AtomicBool::new(false));
    cur.clone()
}

#[tauri::command]
async fn find_duplicates(state: State<'_, AppState>, root: String) -> Res<Vec<dupes::DupGroup>> {
    let cancel = fresh_cancel(&state);
    tauri::async_runtime::spawn_blocking(move || dupes::find(Path::new(&root), &cancel)).await.map_err(err)
}

#[tauri::command]
async fn disk_usage(state: State<'_, AppState>, dir: String) -> Res<Vec<usage::Usage>> {
    let cancel = fresh_cancel(&state);
    tauri::async_runtime::spawn_blocking(move || usage::analyze(Path::new(&dir), &cancel)).await.map_err(err)
}

#[tauri::command]
fn cancel_task(state: State<AppState>) {
    state.cancel.lock().unwrap().store(true, Ordering::SeqCst);
}

#[tauri::command]
fn home_dir() -> String {
    resolver::home_dir().to_string_lossy().into_owned()
}

fn main() {
    let idx = index::Index::new(index::default_roots());
    idx.rebuild_in_background();
    tauri::Builder::default()
        .manage(AppState { index: idx, cancel: Mutex::default() })
        .invoke_handler(tauri::generate_handler![
            places,
            list_dir,
            crumbs,
            parent,
            looks_like_path,
            resolve_path,
            search,
            index_status,
            rebuild_index,
            open_path,
            reveal,
            trash_items,
            rename,
            new_folder,
            find_duplicates,
            disk_usage,
            cancel_task,
            home_dir,
        ])
        .run(tauri::generate_context!())
        .expect("FileTidy 啟動失敗");
}
