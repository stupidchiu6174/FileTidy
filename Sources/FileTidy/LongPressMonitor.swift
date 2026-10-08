import AppKit

/// 在表格上按住超過 0.45 秒(且沒有拖動)就觸發預覽。
/// 用 AppKit 事件監聽而不是 SwiftUI 手勢,避免吃掉 Table 原本的選取/雙擊/拖放。
@MainActor
final class LongPressMonitor {

    private var monitor: Any?
    private var timer: Timer?
    private var downScreenPoint: NSPoint = .zero
    private let delay: TimeInterval = 0.45
    private let slop: CGFloat = 4
    private var pressFired = false
    private var pollTimer: Timer?
    private var onFireRef: (() -> Void)?

    func install(onFire: @escaping () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .pressure]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, onFire: onFire) }
            return event
        }
    }

    private func handle(_ event: NSEvent, onFire: @escaping () -> Void) {
        switch event.type {
        case .pressure:
            // stage 2 = 用力按到底(Force Click);同一次按壓只觸發一次
            if event.stage >= 2, !pressFired, isOverTable(event) {
                pressFired = true
                cancel()
                onFire()
            } else if event.stage == 0 {
                pressFired = false
            }
        case .leftMouseDown:
            pressFired = false
            cancel()
            guard event.clickCount == 1, isOverTable(event) else { return }
            downScreenPoint = NSEvent.mouseLocation
            onFireRef = onFire
            startPolling()
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.timer = nil
                    // NSTableView 在按下後會進入自己的追蹤迴圈,收不到放開/拖動事件,
                    // 所以在這裡直接查詢「左鍵是否仍按著、游標是否幾乎沒動」。
                    let now = NSEvent.mouseLocation
                    let stillDown = NSEvent.pressedMouseButtons & 1 != 0
                    let moved = hypot(now.x - self.downScreenPoint.x, now.y - self.downScreenPoint.y) > self.slop
                    if stillDown, !moved { onFire() }
                }
            }
        default:
            cancel()
            stopPolling()
        }
    }

    private func cancel() { timer?.invalidate(); timer = nil }

    /// NSTableView 按下滑鼠後會進入自己的追蹤迴圈,壓力事件會被扣在佇列裡直到放開。
    /// 這裡用 .common 模式的計時器(追蹤期間也會跑),主動把壓力事件取出來,讓 Force Click 即時生效。
    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func poll() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { stopPolling(); return }
        // 游標移動超過門檻代表使用者在拖曳(不是 Force Click),立刻停止,避免干擾拖放
        let now = NSEvent.mouseLocation
        if hypot(now.x - downScreenPoint.x, now.y - downScreenPoint.y) > slop { stopPolling(); cancel(); return }
        while let e = NSApp.nextEvent(matching: .pressure, until: .distantPast, inMode: .eventTracking, dequeue: true) {
            if e.stage >= 2, !pressFired {
                pressFired = true
                cancel()
                onFireRef?()
            }
        }
    }

    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    private func isOverTable(_ event: NSEvent) -> Bool {
        guard let view = event.window?.contentView?.hitTest(event.locationInWindow) else { return false }
        var v: NSView? = view
        while let cur = v {
            if cur is NSTableView || cur is DragSourceView { return true }
            v = cur.superview
        }
        return false
    }
}
