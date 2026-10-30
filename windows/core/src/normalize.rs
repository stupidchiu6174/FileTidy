use unicode_normalization::UnicodeNormalization;

/// 統一成「可比對形式」:全半形、大小寫、重音一致,並移除空白與標點。
/// 所以 "My  Photo-01"、"my_photo01"、"ＭＹ ＰＨＯＴＯ０１" 都會變成 "myphoto01"。
pub fn normalize(s: &str) -> String {
    base(s).chars().filter(|c| c.is_alphanumeric()).collect()
}

/// 只做大小寫/全半形/組字的統一,保留標點(比對檔名、路徑用)。
pub fn fold(s: &str) -> String {
    s.nfkc().collect::<String>().to_lowercase()
}

fn base(s: &str) -> String {
    // NFKD 拆出重音符號後去掉(é → e),再組回 NFC
    let stripped: String = s.nfkd().filter(|c| !is_combining_mark(*c)).collect();
    stripped.nfc().collect::<String>().to_lowercase()
}

fn is_combining_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

/// 0...1。完全相符 > 前綴 > 包含 > 多關鍵字全中 > 依序出現 > 字元相似度(容錯字)
pub fn score(query: &str, target: &str) -> f64 {
    let q = normalize(query);
    let t = normalize(target);
    score_normalized(query, &q, &t)
}

/// 和 `score` 一樣,但目標已經正規化過(索引裡存的就是正規化後的檔名)。
pub fn score_normalized(raw_query: &str, q: &str, t: &str) -> f64 {
    if q.is_empty() || t.is_empty() {
        return 0.0;
    }
    if t == q {
        return 1.0;
    }
    if t.starts_with(q) {
        return 0.97;
    }
    if t.contains(q) {
        return 0.9;
    }
    let tokens: Vec<String> = raw_query.split_whitespace().map(normalize).filter(|s| !s.is_empty()).collect();
    if tokens.len() > 1 && tokens.iter().all(|k| t.contains(k.as_str())) {
        return 0.85;
    }
    fuzzy(q, t)
}

/// 依序出現/打錯字的容錯比對,比較貴,只在精確結果太少時使用。
pub fn fuzzy(q: &str, t: &str) -> f64 {
    let qc: Vec<char> = q.chars().collect();
    let tc: Vec<char> = t.chars().collect();
    let mut best = 0.0;
    if let Some(span) = subsequence_span(&qc, &tc) {
        best = 0.4 + 0.3 * qc.len() as f64 / span as f64;
    }
    if qc.len() >= 2 {
        let dice = dice_bigram(&qc, &tc);
        if dice >= 0.4 {
            best = f64::max(best, 0.5 * dice);
        }
    }
    best
}

/// 查詢字元依序出現在目標中時,回傳涵蓋的最短區間長度。
fn subsequence_span(q: &[char], t: &[char]) -> Option<usize> {
    let first = *q.first()?;
    let mut best: Option<usize> = None;
    for start in (0..t.len()).filter(|&i| t[i] == first) {
        let (mut qi, mut ti) = (0, start);
        while ti < t.len() && qi < q.len() {
            if t[ti] == q[qi] {
                qi += 1;
            }
            ti += 1;
        }
        if qi == q.len() {
            best = Some(best.map_or(ti - start, |b| b.min(ti - start)));
        }
    }
    best
}

fn dice_bigram(a: &[char], b: &[char]) -> f64 {
    use std::collections::HashMap;
    if a.len() < 2 || b.len() < 2 {
        return 0.0;
    }
    let grams = |s: &[char]| {
        let mut d: HashMap<(char, char), usize> = HashMap::new();
        for w in s.windows(2) {
            *d.entry((w[0], w[1])).or_default() += 1;
        }
        d
    };
    let (ga, gb) = (grams(a), grams(b));
    let overlap: usize = ga.iter().map(|(k, v)| (*v).min(*gb.get(k).unwrap_or(&0))).sum();
    2.0 * overlap as f64 / (a.len() - 1 + b.len() - 1) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_ignores_spaces_punctuation_case_width() {
        assert_eq!(normalize("My  Photo-01"), "myphoto01");
        assert_eq!(normalize("my_photo01"), "myphoto01");
        assert_eq!(normalize("ＭＹ　ＰＨＯＴＯ０１"), "myphoto01");
        assert_eq!(normalize("Café"), "cafe");
    }

    #[test]
    fn lexical_scoring() {
        assert!(score("my photo", "my_photo_01") > 0.85);
        assert!(score("photo my", "my_photo_01") > 0.8);
        assert!(score("報 告 2024", "年度報告2024") > 0.85);
        assert!(score("mphoto", "my_photo") > 0.4);
        assert!(score("invoce", "invoice") > 0.3);
        assert_eq!(score("zzz", "invoice"), 0.0);
    }
}
