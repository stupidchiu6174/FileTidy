import Foundation
import NaturalLanguage

// MARK: - 正規化

public enum TextNormalizer {
    /// 統一成「可比對形式」:全半形、大小寫、重音、繁簡一致,並移除空白與標點。
    /// 所以 "My  Photo-01"、"my_photo01"、"MY PHOTO 01" 都會變成 "myphoto01"。
    public static func normalize(_ s: String) -> String {
        base(s).filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    /// 給嵌入模型用的文字:保留詞與詞的邊界(底線/連字號/駝峰 → 空格)。
    public static func semanticText(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        t = base(t)
        t = String(t.map { $0.isPunctuation || $0.isSymbol ? " " : $0 })
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func base(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? t
        return t
    }
}

// MARK: - 嵌入模型

public protocol TextEmbedder: AnyObject {
    var name: String { get }
    func embed(_ text: String) -> [Float]?
}

/// 使用 Apple 內建的 NaturalLanguage 句向量(完全在本機執行,不需下載或連網)。
/// 想換成自己的 Core ML 模型時,只要實作 TextEmbedder 即可。
public final class NLSentenceEmbedder: TextEmbedder {
    public let name: String
    private let embedding: NLEmbedding

    public init?(language: NLLanguage) {
        guard let e = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        embedding = e
        name = "NLEmbedding(\(language.rawValue))"
    }

    /// 依檔名語言挑選模型;找不到對應語言時退回英文。
    public static func make(forSamples samples: [String]) -> NLSentenceEmbedder? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(samples.prefix(300).map(TextNormalizer.semanticText).joined(separator: ". "))
        var lang = recognizer.dominantLanguage ?? .english
        if lang == .traditionalChinese { lang = .simplifiedChinese }  // 文字已先轉簡體
        return NLSentenceEmbedder(language: lang) ?? NLSentenceEmbedder(language: .english)
    }

    public func embed(_ text: String) -> [Float]? {
        guard !text.isEmpty, let v = embedding.vector(for: text) else { return nil }
        return v.map { Float($0) }
    }
}

public func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let d = (na * nb).squareRoot()
    return d == 0 ? 0 : Double(dot / d)
}

// MARK: - 字面比對

public enum LexicalMatcher {
    /// 0...1。完全相符 > 前綴 > 包含 > 多關鍵字全中 > 依序出現 > 字元相似度(容錯字)
    public static func score(query: String, target: String) -> Double {
        let q = TextNormalizer.normalize(query)
        let t = TextNormalizer.normalize(target)
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t == q { return 1 }
        if t.hasPrefix(q) { return 0.97 }
        if t.contains(q) { return 0.9 }

        let tokens = query.split(whereSeparator: \.isWhitespace).map { TextNormalizer.normalize(String($0)) }.filter { !$0.isEmpty }
        if tokens.count > 1, tokens.allSatisfy({ t.contains($0) }) { return 0.85 }

        var best = 0.0
        if let span = subsequenceSpan(Array(q), in: Array(t)) {
            best = 0.4 + 0.3 * Double(q.count) / Double(span)
        }
        if q.count >= 2 {
            let dice = diceBigram(q, t)
            if dice >= 0.4 { best = max(best, 0.5 * dice) }
        }
        return best
    }

    /// 查詢字元依序出現在目標中時,回傳涵蓋的最短區間長度。
    static func subsequenceSpan(_ q: [Character], in t: [Character]) -> Int? {
        var best: Int?
        for start in t.indices where t[start] == q[0] {
            var qi = 0, ti = start
            while ti < t.count, qi < q.count {
                if t[ti] == q[qi] { qi += 1 }
                ti += 1
            }
            if qi == q.count { best = min(best ?? .max, ti - start) }
        }
        return best
    }

    static func diceBigram(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> [String: Int] {
            let c = Array(s)
            var d: [String: Int] = [:]
            for i in 0..<(c.count - 1) { d[String(c[i...i + 1]), default: 0] += 1 }
            return d
        }
        guard a.count >= 2, b.count >= 2 else { return 0 }
        let ga = grams(a), gb = grams(b)
        let overlap = ga.reduce(0) { $0 + min($1.value, gb[$1.key] ?? 0) }
        return 2 * Double(overlap) / Double(a.count - 1 + b.count - 1)
    }
}

