#!/usr/bin/env python3
"""產生(只涵蓋檔案管理模組 FileTidy/FileTidyCore;LiriOS 其他部分目前只有中文)
產生 Resources/Localizations/{zh-Hant,en,ja}.lproj。
流程:1) 用編譯器萃取程式碼裡所有可本地化字串的精確鍵值 2) 對照 tools/translations.py
     3) 檢查漏翻、多餘、佔位符不一致 4) 輸出 .strings 檔。有問題時以非 0 結束。
用法:python3 tools/make_strings.py
"""
import glob, json, os, re, shutil, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from translations import T, ZH_OVERRIDES, INFO_PLIST

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Localizations")
EXTRACT = "/tmp/lirios-lsout"
SCRATCH = "/tmp/lirios-ls-build"

def extract_keys():
    shutil.rmtree(EXTRACT, ignore_errors=True); os.makedirs(EXTRACT)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    subprocess.run(["swift", "build", "--target", "FileTidy", "--scratch-path", SCRATCH, "-Xswiftc", "-emit-localized-strings",
                    "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", EXTRACT],
                   cwd=ROOT, check=True, capture_output=True)
    keys = []
    for f in sorted(glob.glob(EXTRACT + "/*.stringsdata")):
        for entries in json.load(open(f)).get("tables", {}).values():
            for e in entries:
                if e["key"] not in keys: keys.append(e["key"])
    return keys

def placeholders(s):
    # %@ %lld %1$@ %2$lld ... 只比對型別序列(位置式寫法依位置排序)
    found = re.findall(r"%(?:(\d+)\$)?(@|lld|d|f)", s)
    if found and all(p for p, _ in found):
        return [t for _, t in sorted(found, key=lambda x: int(x[0]))]
    return [t for _, t in found]

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def write(lang, mapping):
    d = os.path.join(OUT, f"{lang}.lproj"); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        f.write("/* 由 tools/make_strings.py 產生,請改 tools/translations.py */\n")
        for k, v in mapping.items():
            f.write(f'"{esc(k)}" = "{esc(v)}";\n')

def main():
    keys = [k for k in extract_keys() if k.strip()]
    problems = 0
    missing = [k for k in keys if k not in T]
    if missing:
        problems += len(missing); print("❌ 漏翻:")
        for k in missing: print("   ", repr(k))
    unused = [k for k in T if k not in keys and k not in ZH_OVERRIDES]
    if unused:
        print("⚠️ 翻譯表裡有但程式碼沒用到(可清理):")
        for k in unused: print("   ", repr(k))
    for k, (en, ja) in T.items():
        for lang, v in (("en", en), ("ja", ja)):
            if placeholders(k) != placeholders(v):
                problems += 1; print(f"❌ 佔位符不一致 [{lang}] {k!r} → {v!r}")
    en = {k: T[k][0] for k in T}; ja = {k: T[k][1] for k in T}
    zh = {k: ZH_OVERRIDES.get(k, k) for k in T}
    for lang, m in (("en", en), ("ja", ja), ("zh-Hant", zh)): write(lang, m)
    for lang, idx in (("zh-Hant", 0), ("en", 1), ("ja", 2)):
        d = os.path.join(OUT, f"{lang}.lproj")
        with open(os.path.join(d, "InfoPlist.strings"), "w", encoding="utf-8") as f:
            for k, vals in INFO_PLIST.items(): f.write(f'"{k}" = "{esc(vals[idx])}";\n')
    print(f"鍵值 {len(keys)} 個,翻譯 {len(T)} 個,問題 {problems} 個")
    sys.exit(1 if problems else 0)

main()
