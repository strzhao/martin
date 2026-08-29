# 英文轨风格规范：dev.to / #showdev（实证版）

> 2026-08-29 从 dev.to #showdev 本周高赞实证提炼（语料 `corpus/devto-12yo-android-saas.md` 23❤42💬、`corpus/devto-image-editor-ondevice.md` 8❤5💬 + 8 条标题库）。优先级：本文 > 语料 > 通用直觉。

## 结构模板（从 23❤ 样本逆向）

```
标题：I built <X> <反差/自嘲钩子>     （"I'm 12. I don't have a laptop. I built…"）
开场：Hi everyone! 👋 + 2-3 句身份/处境（建立叙事视角，反差感即钩子）
## 🛠️ The Stack（技术栈小节，带 emoji 小标题是 dev.to 常态）
## 🐛 <叙事化的踩坑段>（"Boss Fight" Bugs——把 debug 写成故事，每个坑 = 症状→排查→The Fix）
## 🏆 User #1 / 真实使用故事（有真实对话引用最佳："THAT'S MY FRIEND TEXTING YOU, IDIOT."）
## 🚀 Try it（Live link + repo + 一个 GIF/截图）
## 🙏 反馈请求（具体化选择题："Should I add A or B?"——比空泛 welcome feedback 回复率高得多）
```

## 实证规律

1. **emoji 小标题正常用**（🛠️🐛🏆🚀🙏）——与 V2EX 零 emoji 相反，两个平台不要互相污染。
2. **第一人称叙事压倒性**：标题库 8 篇里 7 篇 I built / Why I built 开头。
3. **反差与自嘲是钩子**：「12 岁没电脑」「because apparently having too many hobbies eventually leads to building your own app」。
4. **Bug 段是重头戏**：症状具体（代码级：`height: 100vh` 在移动端的坑）→ The Fix 给出实际改法。技术读者来这里看踩坑，不看营销。
5. **真实对话引用**是最强活人感（用户/朋友的原话，原样引用带表情）。
6. **求反馈具体化**：给 2-3 个二选一问题，降低读者回复成本。
7. 篇幅：2500-5500 chars 是本周样本区间（比 V2EX 长一档）。
8. TL;DR 顶部仍有价值（扫读者），但叙事开场可以替代——二选一，看文章类型（产品 show 偏叙事，how-to 偏 TL;DR）。

## 语气：中文母语者写英文的诚实感

- 短句直接，允许轻微不完美（不追求 native 油滑，这反而可信）。
- 具体压倒泛化：真命令、真数字、真场景。
- "I kept losing track of tasks while pair-coding with Claude Code" > "Developers often struggle with…"。

## 英文 AI 指纹黑名单（L1 扫描覆盖）

delve / leverage / unleash / supercharge / revolutionize / empower / seamless / game-changing / cutting-edge / revolutionary / In today's fast-paced world / It's worth noting / In conclusion / Let's dive in / incredibly+adj 连用

## #showdev 礼仪

- showdev 社区预期：做了个东西 show 出来——演示/截图/链接必有其一
- 诚实 disclosure：开源给 repo，SaaS 说清免费额度
- 首帖走 oss-ops L2：dev.to API 支持先存草稿（published=false），用户最后过目再发
