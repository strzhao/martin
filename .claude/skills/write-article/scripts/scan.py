#!/usr/bin/env python3
# write-article L1 硬规则扫描：中文 AI 味禁词 / 英文 AI 指纹词 / 结构套话 / 营销黑话
# 用法: python3 scan.py <file.md> [--lang zh|en|auto]
# 退出码: 0 干净 / 1 有命中（详情见输出）
# 词表来源: khazix-writer L1 适配 + V2EX 语料实证 + oss-ops 反 slop 红线（持续追加）

import re
import sys

ZH_BANNED = [
    (r"说白了", "坦率的讲 / 其实就是"),
    (r"这意味着|意味着什么", "所以呢 / 那结果会怎样"),
    (r"本质上", "说到底 / 其实"),
    (r"换句话说", "你想想看 / 也就是说"),
    (r"不可否认", "直接删掉，正面陈述"),
    (r"综上所述|总的来说", "具体回扣句"),
    (r"值得注意的是|不难发现", "删掉直接说"),
    (r"首先[，,].{0,40}其次", "自然转场词"),
    (r"让我们来看看|接下来让我们", "直接进入内容"),
    (r"在当今.{0,12}的时代|随着.{0,12}的(不断)?发展", "具体事件开头"),
    (r"赋能|抓手|闭环|极致体验|颠覆性|革命性", "说人话，给具体事实"),
]

EN_FINGERPRINT = [
    (r"\bdelve(d)? into\b", "dig into / look at"),
    (r"\bleverag(e|ing)\b", "use"),
    (r"\bunleash\b|\bsupercharge\b|\brevolutioniz(e|ed|ing)\b|\bempower(ing|ed)?\b", "具体动词"),
    (r"\bseamless(ly)?\b|\bgame[- ]changing\b|\bcutting[- ]edge\b|\brevolutionary\b", "具体描述"),
    (r"[Ii]n today'?s fast[- ]paced world|[Ii]n the ever[- ]evolving", "具体事件开头"),
    (r"[Ll]ook no further", "直接给结论"),
    (r"[Ii]t'?s worth noting that", "删掉直接说"),
    (r"[Ii]n conclusion\b|[Ll]et'?s dive in|Without further ado", "直接收 / 直接进"),
    (r"\bincredibly \w+|\babsolutely \w+|\btruly \w+", "删程度词"),
]

MARKETING = [
    (r"限时|独家|错过不再|速来|赶紧(收藏|上车)", "V2EX 营销腔，毙"),
    (r"求(个)?(赞|三连|转发|星标|关注)", "轻互动即可，乞求话术毙"),
]


def scan(text: str, lang: str):
    hits = []
    tables = []
    if lang in ("zh", "auto"):
        tables += ZH_BANNED + MARKETING
    if lang in ("en", "auto"):
        tables += EN_FINGERPRINT
    lines = text.split("\n")
    for i, line in enumerate(lines, 1):
        for pat, fix in tables:
            for m in re.finditer(pat, line):
                hits.append((i, m.group(0), fix))
    return hits


def main():
    if len(sys.argv) < 2:
        print("usage: scan.py <file.md> [--lang zh|en|auto]"); sys.exit(2)
    path = sys.argv[1]
    lang = "auto"
    if "--lang" in sys.argv:
        lang = sys.argv[sys.argv.index("--lang") + 1]
    text = open(path, encoding="utf-8").read()
    hits = scan(text, lang)
    if not hits:
        print(f"✅ L1 扫描干净（{path}）")
        sys.exit(0)
    print(f"❌ L1 扫描命中 {len(hits)} 处（{path}）：")
    for i, (ln, word, fix) in enumerate(hits, 1):
        print(f"  {i:>2}. L{ln}  「{word}」  → {fix}")
    sys.exit(1)


if __name__ == "__main__":
    main()
