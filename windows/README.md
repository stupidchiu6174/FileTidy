# FileTidy for Windows

Windows 版的 FileTidy。macOS 版是 SwiftUI,沒辦法直接在 Windows 編譯,所以這裡用 [Tauri](https://tauri.app)(Rust + 網頁介面)另外寫了一份,功能先做核心的部分。

## 下載

GitHub 的 **Actions › Windows build** 每次推送都會在 Windows 上編譯,成品在該次執行頁面底下的 **FileTidy-Windows**:

- `FileTidy_x.y.z_x64-setup.exe`:安裝程式(建議)
- `FileTidy_x.y.z_x64_en-US.msi`:MSI 安裝檔
- `filetidy.exe`:免安裝版,需要系統已有 WebView2(Windows 10/11 通常內建)

## 功能

- 瀏覽:返回/下一頁/上層、可點擊的路徑列、排序、多選、右鍵選單、重新命名(F2)、新增資料夾(Ctrl+Shift+N)、移到資源回收筒(Delete)、在檔案總管中顯示
- **輸入不完整的路徑**:路徑列(Ctrl+L / Alt+D / Ctrl+Shift+G)和搜尋框都可以輸入
  - `/downloads`、`\downloads`、`~/doc`、`documents\proj` → 依序在磁碟根目錄、個人資料夾、目前資料夾底下找,不分大小寫,也接受唯一的開頭
  - `/下載`、`~/ダウンロード` → 系統資料夾的中文/日文名稱
  - `%USERPROFILE%\Downloads`、`"C:\Users\me"`、`file:///C:/...`
  - `Backups/psd1029_b1_20261030_094935/` → 都找不到時用索引依路徑結尾找,在哪個磁碟都可以
- 全機搜尋:個人資料夾與其他磁碟(不含系統磁碟)的檔名索引,容錯比對(順序顛倒、打錯字、所在資料夾名稱)
- 重複檔案:比大小 → 前 64KB → 完整 SHA-256,每組預設保留最舊的一份
- 空間分析:資料夾內每個項目佔用的大小
- 介面:繁中、英文、日文(左下角切換),跟隨系統深色模式

和 macOS 版相比還沒有:語意搜尋、檔案變動即時更新索引(目前按狀態列右邊的索引數字可以重建)、自動分類、批次改名、操作紀錄與復原、繁簡互通搜尋、AI 摘要。

## 開發

需要 Rust、Node.js 22。在 Linux 上另外需要 `libwebkit2gtk-4.1-dev`。

```bash
cd windows
npm ci
cargo test -p filetidy-core
npx tauri dev
```

在 Windows 上產生安裝檔:`npx tauri build`,成品在 `target/release/bundle/`。

- `core/`:跨平台核心(路徑解析、索引、重複檔、空間分析),有單元測試
- `src-tauri/`:桌面程式外殼,把核心功能提供給介面
- `ui/`:介面(純 HTML/CSS/JS,不需要建置步驟)
