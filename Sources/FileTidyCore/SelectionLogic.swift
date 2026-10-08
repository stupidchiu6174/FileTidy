import Foundation

/// 點擊選取的規則(與 Finder 一致)。純函式,方便測試。
/// - 一般點擊:選這一個,並成為「起點」。點在已選取的多選項目上時先保留多選(才能拖曳整組),放開時由呼叫端收斂。
/// - ⌘ 點擊:切換這一個,並成為起點。
/// - ⇧ 點擊:選取「起點 → 點擊處」的連續範圍(取代目前選取,不是疊加);起點不變。
public enum SelectionLogic {
    public struct State: Equatable {
        public var selection: Set<URL>
        public var anchor: URL?
        public init(selection: Set<URL>, anchor: URL?) { self.selection = selection; self.anchor = anchor }
    }

    public static func click(_ url: URL, command: Bool, shift: Bool, order: [URL], state: State) -> State {
        var s = state
        if command {
            if s.selection.contains(url) { s.selection.remove(url) } else { s.selection.insert(url) }
            s.anchor = url
        } else if shift, let anchor = resolvedAnchor(state, order: order),
                  let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: url) {
            s.selection = Set(order[min(a, b)...max(a, b)])
            s.anchor = anchor
        } else if !s.selection.contains(url) {
            s.selection = [url]
            s.anchor = url
        }
        return s
    }

    /// 起點:記錄的起點仍在選取中就用它;否則(例如用方向鍵或在別的欄位點選過)取選取中排在最前面的項目。
    static func resolvedAnchor(_ state: State, order: [URL]) -> URL? {
        if let a = state.anchor, state.selection.contains(a), order.contains(a) { return a }
        return order.first(where: { state.selection.contains($0) })
    }

    /// 「游標」所在的項目:連續範圍中,與起點相反的那一端(單選時就是它自己)。鍵盤移動以它為基準。
    public static func cursor(order: [URL], state: State) -> URL? {
        let idx = order.indices.filter { state.selection.contains(order[$0]) }
        guard let lo = idx.min(), let hi = idx.max() else { return nil }
        guard let anchor = state.anchor, let ai = order.firstIndex(of: anchor), state.selection.contains(anchor) else { return order[hi] }
        return order[ai == lo ? hi : lo]
    }

    /// 鍵盤移動:⇧ 方向鍵從起點延伸到新位置;沒按 ⇧ 則只選新位置並成為起點。
    public static func move(to url: URL, shift: Bool, order: [URL], state: State) -> State {
        var s = state
        if shift, let anchor = resolvedAnchor(state, order: order),
           let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: url) {
            s.selection = Set(order[min(a, b)...max(a, b)])
            s.anchor = anchor
        } else {
            s.selection = [url]
            s.anchor = url
        }
        return s
    }
}
