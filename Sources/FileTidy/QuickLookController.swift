import AppKit
import Quartz

/// Finder 式的快速查看:從列的圖示放大彈出、收合時縮回圖示;
/// 點視窗空白處、按 Esc 或空白鍵都會關閉。
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    /// 回傳該檔案目前在螢幕上的圖示位置(螢幕座標)與過場影像;不在畫面內則回傳 nil(無動畫)
    var sourceProvider: ((URL) -> (frame: NSRect, image: NSImage?)?)?
    private var monitors: [Any] = []

    private var panel: QLPreviewPanel { QLPreviewPanel.shared() }
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible }

    func show(urls: [URL], current: URL) {
        guard let index = urls.firstIndex(where: { $0.path == current.path }) else { return }
        // 已經在預覽同一個檔案時,再觸發視為關閉(與 Finder 的空白鍵一致)
        if isVisible, (panel.currentPreviewItem as? URL) == current { close(); return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        panel.close()
        removeMonitors()
    }

    // MARK: 資料來源

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }

    // MARK: 放大/縮回動畫

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item as? URL, let src = sourceProvider?(url) else { return .zero }
        return src.frame
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item as? URL else { return nil }
        return sourceProvider?(url)?.image
    }

    /// 面板自己是 key window 時,按鍵會先送到這裡(不會經過一般的鍵盤監聽)
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 || event.keyCode == 49 {  // Esc / Space
            close()
            return true
        }
        return false
    }

    // MARK: 點空白處 / Esc / 空白鍵關閉

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let click = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                // 點在預覽面板以外(也就是 檔案管理視窗)就關閉
                if event.window !== self.panel { self.close() }
            }
            return event
        }
        let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isVisible else { return false }
                if event.keyCode == 53 || event.keyCode == 49 {  // Esc / Space
                    self.close(); return true
                }
                return false
            }
            return handled ? nil : event
        }
        monitors = [click, key].compactMap { $0 }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func windowWillClose(_ notification: Notification) { removeMonitors() }
}
