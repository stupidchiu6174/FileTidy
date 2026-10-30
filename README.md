# FileTidy

macOS 檔案管理視窗:瀏覽、整理工具、重複檔、磁碟用量,可以設成預設的檔案檢視器。介面有繁中、英文、日文。

## 需求

macOS 26 以上、Swift 6.2。

## 使用

```bash
swift run FileTidyApp
swift test
```

也可以當函式庫用:把 `FileTidyWindow()` 放進你的 SwiftUI `App`,在啟動時呼叫 `FileTidyIntegration.didFinishLaunching()`。

## 翻譯

`tools/translations.py` 是翻譯表,`python3 tools/make_strings.py` 會產生 `Resources/Localizations/*.lproj`,有漏翻就會失敗。這些檔案要放進 .app 的 Resources 才會生效,用 `swift run` 時介面是原文(繁中)。

原本是 LiriOS 的一部分,部分介面文字還會提到 LiriOS。
