// 翻譯表:鍵 = 介面原文(繁中),值 = [English, 日本語]。{0}、{1} 是代入的值。
const T = {
  "個人": ["Home", "ホーム"],
  "桌面": ["Desktop", "デスクトップ"],
  "文件": ["Documents", "ドキュメント"],
  "下載項目": ["Downloads", "ダウンロード"],
  "圖片": ["Pictures", "ピクチャ"],
  "音樂": ["Music", "ミュージック"],
  "影片": ["Videos", "ビデオ"],
  "位置": ["Places", "場所"],
  "磁碟": ["Drives", "ドライブ"],
  "整理工具": ["Tools", "整理ツール"],
  "瀏覽": ["Browse", "ブラウズ"],
  "重複檔案": ["Duplicate Files", "重複ファイル"],
  "空間分析": ["Disk Usage", "容量分析"],
  "返回": ["Back", "戻る"],
  "下一頁": ["Forward", "進む"],
  "上層資料夾": ["Enclosing Folder", "上の階層のフォルダ"],
  "重新整理": ["Refresh", "更新"],
  "新增資料夾": ["New Folder", "新規フォルダ"],
  "未命名資料夾": ["New Folder", "名称未設定フォルダ"],
  "顯示/隱藏隱藏檔": ["Show/Hide Hidden Files", "隠しファイルを表示/非表示"],
  "搜尋": ["Search", "検索"],
  "整台電腦": ["This PC", "PC 全体"],
  "此資料夾": ["This Folder", "このフォルダ"],
  "輸入路徑,例如 /downloads 或 Backups\\資料夾": ["Type a path, e.g. /downloads or Backups\\folder", "パスを入力(例:/downloads、Backups\\フォルダ)"],
  "找不到這個位置": ["Can’t find this location", "この場所が見つかりません"],
  "前往": ["Go", "移動"],
  "名稱": ["Name", "名前"],
  "修改日期": ["Date Modified", "変更日"],
  "大小": ["Size", "サイズ"],
  "種類": ["Kind", "種類"],
  "所在位置": ["Location", "場所"],
  "符合度": ["Match", "一致度"],
  "資料夾": ["Folder", "フォルダ"],
  "{0} 檔案": ["{0} File", "{0} ファイル"],
  "檔案": ["File", "ファイル"],
  "{0} 個項目": ["{0} items", "{0} 項目"],
  "已選取 {0} 個": ["{0} selected", "{0} 項目を選択"],
  "建立索引中… 已找到 {0} 個項目": ["Indexing… {0} items found", "インデックス作成中… {0} 項目を検出"],
  "已索引 {0} 個項目": ["{0} items indexed", "{0} 項目をインデックス済み"],
  "重建索引": ["Rebuild Index", "インデックスを再構築"],
  "搜尋中…": ["Searching…", "検索中…"],
  "找不到符合的項目": ["No matching items", "一致する項目が見つかりません"],
  "索引建立中…": ["Indexing…", "インデックス作成中…"],
  "這個資料夾是空的": ["This folder is empty", "このフォルダは空です"],
  "無法開啟這個資料夾": ["Can’t open this folder", "このフォルダを開けません"],
  "開啟": ["Open", "開く"],
  "在檔案總管中顯示": ["Show in File Explorer", "エクスプローラーで表示"],
  "顯示所在位置": ["Show in Enclosing Folder", "内包フォルダで表示"],
  "拷貝路徑": ["Copy Path", "パスをコピー"],
  "重新命名": ["Rename", "名前を変更"],
  "移到資源回收筒": ["Move to Recycle Bin", "ごみ箱に移動"],
  "已移到資源回收筒:{0} 個項目": ["Moved {0} items to the Recycle Bin", "{0} 項目をごみ箱に移動しました"],
  "已拷貝路徑": ["Path copied", "パスをコピーしました"],
  "同名的項目已經存在": ["An item with that name already exists", "同じ名前の項目がすでにあります"],
  "名稱不能包含 \\ / : * ? \" < > |": ["Names can’t contain \\ / : * ? \" < > |", "名前に \\ / : * ? \" < > | は使えません"],
  "操作失敗:{0}": ["Failed: {0}", "失敗しました:{0}"],
  "掃描「{0}」": ["Scan “{0}”", "「{0}」をスキャン"],
  "掃描中…": ["Scanning…", "スキャン中…"],
  "停止": ["Stop", "停止"],
  "沒有找到重複的檔案": ["No duplicate files found", "重複ファイルは見つかりませんでした"],
  "{0} 組重複,可省下 {1}": ["{0} groups, {1} can be freed", "{0} グループ、{1} を節約できます"],
  "保留": ["Keep", "残す"],
  "把勾選的 {0} 個移到資源回收筒": ["Move {0} checked items to the Recycle Bin", "チェックした {0} 項目をごみ箱に移動"],
  "每組預設保留最舊的一份": ["The oldest copy in each group is kept by default", "各グループで最も古いファイルを残します"],
  "「{0}」佔用 {1}": ["“{0}” uses {1}", "「{0}」の使用量 {1}"],
  "{0} 個檔案": ["{0} files", "{0} ファイル"],
  "選一個資料夾,再按掃描": ["Pick a folder, then press Scan", "フォルダを選んでスキャンを押してください"],
  "語言": ["Language", "言語"],
  "跟隨系統": ["System", "システム"],
};

const LANGS = [
  { code: "", name: "跟隨系統" },
  { code: "zh-Hant", name: "繁體中文" },
  { code: "en", name: "English" },
  { code: "ja", name: "日本語" },
];

function currentLang() {
  let saved = "";
  try { saved = localStorage.getItem("lang") || ""; } catch {}
  if (saved) return saved;
  const nav = (navigator.language || "en").toLowerCase();
  if (nav.startsWith("zh")) return "zh-Hant";
  if (nav.startsWith("ja")) return "ja";
  return "en";
}

let LANG = currentLang();

function t(key, ...args) {
  const row = T[key];
  let s = key;
  if (row && LANG === "en") s = row[0];
  else if (row && LANG === "ja") s = row[1];
  return s.replace(/\{(\d)\}/g, (_, i) => args[+i] ?? "");
}

function setLang(code) {
  try { code ? localStorage.setItem("lang", code) : localStorage.removeItem("lang"); } catch {}
  LANG = currentLang();
}
