//! FileTidy 的跨平台核心(Windows 版用):不完整路徑解析、全機索引與搜尋、重複檔、空間分析。
//! 對應 macOS 版的 Sources/FileTidyCore。

pub mod dupes;
pub mod index;
pub mod listing;
pub mod normalize;
pub mod resolver;
pub mod usage;
