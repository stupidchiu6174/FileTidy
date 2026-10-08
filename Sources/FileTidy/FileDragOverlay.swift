import SwiftUI
import AppKit

/// 檔名欄位上的透明 AppKit 視圖:用原生 NSDraggingSession 啟動拖曳。
///
/// 為什麼不用 SwiftUI 的 `.draggable` / `.itemProvider`:在 Table 的列上,它們寫進拖曳剪貼簿的資料是空的
/// (實測 public.file-url 為 0 位元組,同樣的拖曳在 Finder 裡成功)。這裡改成跟 Finder 一樣,
/// 用 NSURL 作為 NSPasteboardWriting 直接寫入檔案 URL。
///
/// 因為這個視圖接手了檔名欄位的滑鼠事件,所以選取(含 ⌘/⇧ 多選)、雙擊開啟與右鍵選單都要在這裡處理或轉交。
struct FileDragOverlay: NSViewRepresentable {
    var url: URL
    var selectedURLs: () -> [URL]
    var onMouseDown: (NSEvent.ModifierFlags) -> Void
    var onPlainClick: () -> Void
    var onContextClick: () -> Void
    var onActivate: () -> Void
    /// 圖示檢視時為圖示邊長(讓快速查看知道從哪裡放大);列表為 0
    var iconPoints: CGFloat = 0

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.url = url
        view.selectedURLs = selectedURLs
        view.onMouseDown = onMouseDown
        view.onPlainClick = onPlainClick
        view.onContextClick = onContextClick
        view.onActivate = onActivate
        view.iconPoints = iconPoints
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var url = URL(fileURLWithPath: "/")
    var selectedURLs: () -> [URL] = { [] }
    var onMouseDown: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onPlainClick: () -> Void = {}
    var onContextClick: () -> Void = {}
    var onActivate: () -> Void = {}
    var iconPoints: CGFloat = 0

    private var downEvent: NSEvent?
    private var didDrag = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func enclosingTable() -> NSTableView? {
        var v: NSView? = superview
        while let cur = v { if let t = cur as? NSTableView { return t }; v = cur.superview }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        didDrag = false
        // 鍵盤操作(空白鍵預覽、Return 改名、⌫)需要表格是第一回應者
        if let table = enclosingTable() { window?.makeFirstResponder(table) }
        onMouseDown(event.modifierFlags)
        if event.clickCount == 2 { downEvent = nil; onActivate() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !didDrag else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        didDrag = true

        var urls = selectedURLs()
        if !urls.contains(where: { $0.path == url.path }) { urls = [url] }
        let origin = convert(down.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { i, u in
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: u.path)
            let offset = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(NSRect(x: origin.x - 16 + offset, y: origin.y - 16 - offset, width: 32, height: 32), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        // 沒有拖曳的單擊:多選狀態下收斂為只選這一個(與 Finder 一致)
        if !didDrag, event.clickCount == 1, event.modifierFlags.intersection([.command, .shift]).isEmpty { onPlainClick() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let table = enclosingTable() { window?.makeFirstResponder(table) }
        onContextClick()
        nextResponder?.rightMouseDown(with: event)  // 交給表格,顯示 SwiftUI 的右鍵選單
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .link] : [.move, .copy, .generic]
    }
}


extension DragSourceView {
    /// 在視窗裡找出某個檔案的拖曳來源視圖(列表的檔名欄或圖示檢視的格子)
    static func find(path: String, in root: NSView) -> DragSourceView? {
        var found: [DragSourceView] = []
        func walk(_ v: NSView) {
            if let d = v as? DragSourceView, d.url.path == path { found.append(d) }
            v.subviews.forEach(walk)
        }
        walk(root)
        // 圖示檢視中同一個檔案有「圖示」與「檔名」兩塊,優先用圖示那塊(快速查看從它放大)
        return found.first(where: { $0.iconPoints > 0 }) ?? found.first
    }

    /// 從某個視圖往上找所屬的 DragSourceView
    static func enclosing(_ view: NSView?) -> DragSourceView? {
        var v = view
        while let cur = v { if let d = cur as? DragSourceView { return d }; v = cur.superview }
        return nil
    }
}
