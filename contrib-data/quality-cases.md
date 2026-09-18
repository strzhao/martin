# 质量案例库（quality-cases）

> **用途**：own-PR / forge 立项前的对读材料。使用方式：立项 AI 读本库「教训」列 + 与本件同场景的案例行，自答「我这个件在对方 taste 里站不站得住、覆盖面会不会输给潜在竞品」——判断自己做，本库只供事实与教训，不设判据清单。
> **纪律**：每案 = 一行精炼（上下文宝贵）；原始材料锚点随案附（gh 链接/台账行），需要深挖时按锚点取全量。新案例由「出手后对抗 review」或终局回灌时追加（append-only，不改旧行）。

## 教训总纲（从 10 例提炼，AI 立项时对读）

1. **覆盖面劣势是最高频败因**（4/10）：上游偏好「一次修全一个缺陷的全部消费点」。立项时问：这个 bug 有几个调用点/消费者？竞品来了会以什么形态覆盖？我的面是不是它的真子集？
2. **成本比例感是硬门槛**（1 例翻车）：维护者明确拒过 +453 LOC「disproportionate」，偏好 fail-open+自愈。立项时问：这个件的 LOC/侵入度 vs 问题的实际伤害，比例站得住吗？有没有更省的形态？
3. **速度劣势不属质量问题但属时机问题**（3 例）：空槽窗口以分钟计。立项时问：这个槽如果有人正在造，多久会被占？我方件若 4 分钟后被反超，还有什么留下的价值（互补面/独家证据）？
4. **被采纳≠署名到手**（#113999/#114159 两例）：review 写得对但没货，substance 被采纳署名归零。出手前问：这次动作的可 pick 件是什么？
5. **「被吸收且改进」是我方可接受的败法**（#114159 终局）：对方拿走方向、给出更强实现、书面署名认可——这是 review-first 的正常收敛，不是失败；失败的是既无件又被无视。

### 形态标准（上游章程落地版；来源 = `contrib-data/pr-standard-distilled-20260918.md`，锚点按需取原文）

立项/出手前逐条自答，答不出即降级为 watch 或 pass：

1. 面 = **整个缺陷类**不是一处症状：在 `origin/main` 复现指到行 + 列全兄弟调用点（上游 `AGENTS.md:47-48`）——覆盖面是**通过性**门槛，不只是竞品风险（本库案例 1/9）
2. 值取**运行时权威源**，禁读静态配置/兼容期全局（`AGENTS.md:276-288`；#65794「name the wrong model」）
3. 测试 1–2 条不变量、base 先红、走真路径 E2E；禁 change-detector、**禁源码形状/源码文本断言**（`AGENTS.md:323-325/396-424`；#65794 第 3 问）
4. 成本自带一行算术（LOC/侵入度 vs 伤害）+ 偏好 fail-open 下次自愈，勿新增 fail-closed 拒绝路径（#86062「disproportionate」）
5. 需求锚：无 issue 锚的 feature = 「维护者要不要」类（可预期 P3）；大机械重构欢迎但**必须声明**（`AGENTS.md:53-55`）
6. 落点 churn 预检：`处置成本 ≈ 面积 × 分支年龄 × 落点 churn`（案例 10 实测三乘数全大 ⇒ rebase 变重做）
7. 出手前搜 **open + merged 双态**；已有开放车覆盖该面 ⇒ 转 review/改进或让路，不开竞争 dup（`CONTRIBUTING.md:25,32`；§3.3 A/B/C）
8. 单关注点、不混装（禁 fix+refactor+feature）；收编时同样拒绝 facade 追加·god helper·compat alias·wrapper（`CONTRIBUTING.md:948` + `AGENTS.md:323-325`）
9. 合并闸 = CI required checks + 维护者 review，**机器人 review 零合入权重**（`.coderabbit.yaml`）⇒ 优化目标只能是「让维护者一眼能合」
10. **前提校验先于写作**：设计即隔离？前提与运行时不符？缺失是刻意的（`git log -p -S`）？是否在复活已被否决的方向？（`AGENTS.md:104-131`）

## 案例行

| # | 日期 | 我方资产 | 对手 | 结果 | 劣势维度 | 教训（一句话） | 锚点 |
|---|---|---|---|---|---|---|---|
| 1 | 09-11 | forge-deleted-wal-symlink-canon | #107411 | differentiate 让路 | 实现完整度 | 对方一轮闭环修掉两处调用点+第三消费者+更严测试，我方只覆盖主路径 | absorb-ledger.json[2] |
| 2 | 09-11 | forge-kanban-multiplex-spawn-scope | #106050+#107413 | A 路吸收 4 点 | 设计彻底性 | 对方 hydrate 先于 build 的顺序优势+负例测试，全数吸收后再立新锚 | absorb-ledger.json[3] |
| 3 | 09-11 | forge-kimi-coding-probe-row | #107479 | differentiate | 测试覆盖 | 对方 106 行测试含双探针负控制；我方两条新证据独占性低成对方补洞素材 | absorb-ledger.json[4] |
| 4 | 09-11 | rq-20260911-81297（全量 UNIQUE 设想） | #57832 | stand-down | 设计彻底性 | 对方部分 UNIQUE 范式逐点支配我方方案且实测更稳（归档-重建不炸） | absorb-ledger.json[5] |
| 5 | 09-11 | forge-weixin-stale-classify C1 | #96437 | stand-down | 实现完整度 | 对方 CAS 删除防并发盲删点我方缺；我方生产数据恰是其缺的拼图但投了=武装对手 | absorb-ledger.json[6] |
| 6 | 09-12 | commit-1d0e71e822（FTS 四点加固 +453 LOC） | teknium1 关 #86062 | **关闭翻车** | 成本比例感 | 维护者原文「disproportionate」+偏好 fail-open 自愈——方向性误判，最贵一课 | absorb-ledger.json[16] |
| 7 | 09-13 | probe 稿（109904） | #109920（kokhlo） | 稿成 4-5 分钟被占 | 速度/时机 | 小时级班次吃不到分钟级空槽，瞬时空槽默认按 pass 处理 | absorb-ledger.json[17] |
| 8 | 09-17 | review #113999（无件） | clempat 修复 | 全盘采纳、署名归零 | 出手形态 | 68 分钟窗口可 forge 未 forge；采纳≠进仓，有货必带 | decision-log.md 09-17 判例 |
| 9 | 09-18 | own-PR #114159（读侧） | #114220（kshitij） | **被吸收且改进**（健康败法） | 实现完整度 | 对方收窄后缀白名单+同步沙箱读点更强，但署名认可+测试 cherry-pick offer 到手——可接受的输法 | absorb-ledger.json[22] |
| 10 | 09-18 | own-PR #65794（+1361/−4，4 文件） | 上游 sweeper 07-18 判词「keep_open salvageability=medium」+ 62 天零回应 | **守候中活例**（判不 rebase，复查 10-18） | 面积/落点/需求锚 | 处置成本 ≈ 面积×分支年龄×落点 churn，三乘数全大即指数化：+1361 LOC × 62 天 × 落点 `run.py` 拆分窗口（25107 删/3566 增/409 提交）⇒ rebase 实测 7 块/9176 行 = 重做而非 rebase；且无 issue 锚的 feature 被标 P3 | pr-disposition-20260918.md §1.4 |

## 正面基准（对标对象，不是败例）

- **#109149**（aux vision notice）：issue 后 24m43s、+192/-11、3 文件、8 条回归测试、Fixes 锚——「一次修全+测试自带」的竞品标准形态。
- **#103201**（rg eacces）：+378/-34 超集含诊断管道——「把相关面顺手修干净」的形状（对读：我方何时该做超集 vs 何时保持单关注点）。
- 我方健康样板 **#111453 被收编**（60f3763c23 署名进 main）与 **t_709c2ef3**（catch 到会删生产数据的 D1）——我方达到过这个标准。
