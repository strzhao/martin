# 上游 hermes PR 最佳实践 → 我方「PR 形态标准」研读底稿（2026-09-18）

> 委托：委托人 2026-09-18 23:2x「hermes 自己有非常好的最佳实践说明，你安排 operator 了解下，更新进来」。
> 来源（全部实读，非转述）：`NousResearch/hermes-agent` @ `origin/main = c661785f872b`（2026-09-18 17:10 +0200）的
> `AGENTS.md`（446 行）/ `CONTRIBUTING.md`（1002 行）/ `.github/PULL_REQUEST_TEMPLATE.md` / `.coderabbit.yaml`。
> 红线：gh 全程只读（`pr view` / `api -X GET` / 本地 `git show origin/main:<path>`），零 push、零评论、零对外。
> 落点三处见 §5。本文件 = 引用底稿，供下游卡按锚点取原文。

## 1 上游源材料清单（对读时按锚点取原文，本文不抄全文）

| 源 | 位置 | 说了什么（一行） |
|---|---|---|
| AGENTS.md §Contribution Rubric | `AGENTS.md:31-102` | 项目意图层：What we want / What we don't，兼作自动 triage sweeper 的判据边界 |
| AGENTS.md §verify the premise | `AGENTS.md:104-131` | 「被写好却被关」的头号原因是**前提取错**（设计即隔离 / 前提与运行时不符 / 缺失是刻意的 / 越界复活旧方向） |
| AGENTS.md §Footprint Ladder | `AGENTS.md:133-152` | 新能力六档阶梯（延伸现有 → CLI+skill → service-gated → 插件 → MCP → 新 core tool，末档最后手段） |
| AGENTS.md §Commits, Merges, PRs | `AGENTS.md:316-325` | 每件修 = 1–2 条不变量测试（在 base 上先证红）；salvage 同门槛；收编时拒绝 facade 追加/god helper/compat alias/wrapper |
| AGENTS.md §Testing | `AGENTS.md:327-424` | `scripts/run_tests.sh`；行为契约非快照；禁 change-detector；**禁读源码的形状断言**（`AGENTS.md:409`）；跨 OS 用 marker 且必须真机跑 |
| AGENTS.md §Facade + siblings | `AGENTS.md:227-259` | 文件 ~2000 行 / 函数 ~300 行或 CC30 = 该先拆；大机械重构是**想要的活**但要**声明** |
| CONTRIBUTING.md §Contribution Priorities / Search First | `CONTRIBUTING.md:7-35` | 优先级：bug fix > 跨平台 > 安全 > 性能 > 新 skill > 新 tool；**开 PR 前搜 open+merged 双态**；已有开放车覆盖 ⇒ 去 review/改进那辆，别开竞争 dup |
| CONTRIBUTING.md §Pull Request Process | `CONTRIBUTING.md:931-983` | 分支命名 / **一个逻辑变更一个 PR（禁 fix+refactor+feature 混装）** / PR 描述四件套（what+why、how to test、平台、关联 issue）/ Conventional Commits |
| PR 模板 | `.github/PULL_REQUEST_TEMPLATE.md` | 提交前清单：搜过重复、只含相关改动、测试通过、bug fix 必带测试、声明测试平台、文档/配置/跨平台 N/A 项逐条勾 |
| CodeRabbit 配置 | `.coderabbit.yaml` | **合并闸 = CI「All required checks pass」+ 维护者 review**；机器人 review 零合入权重（protect-main 要求 0 approving reviews），且仓级 auto-review 已关 |
| hermes-sweeper 授权边界 | `AGENTS.md:33-36` + 我方 `hermes-contribution.md:139` | 自动 sweeper **只能**以 `implemented_on_main` / `cannot_reproduce` / `incoherent` 三个理由关 PR；品味类 close 留给人 |

## 2 提炼：我方 PR 形态标准（10 条，可执行判据）

每条 = 判据 + 上游锚 + 我方判例锚。**判据用法**：立项/出手前逐条自答，答不出即降级为 watch 或 pass。

1. **面 = 整个缺陷类，不是一处症状**。先在当前 `origin/main` 复现、指到行，再列全兄弟调用点，件覆盖全族消费点。
   锚：`AGENTS.md:47-48`（「fix the whole bug class — sibling call paths included」）｜我方案例 1（覆盖面劣势 4/9 最高频败因）、案例 9。
2. **值取运行时权威源**。展示/判定用的模型名、路径、开关一律取运行时解析值（session scope），禁读静态 `load_config()` 或兼容期全局常量。
   锚：`AGENTS.md:276-288`（未绑 profile scope 的读 = 静默默认值泄漏）｜我方 #65794 判词原文「The feedback can name the wrong model」。
3. **测试 = 1–2 条不变量，先证红**。断言两数据之间的关系，不冻结当前值；**禁 change-detector、禁源码形状/源码文本断言**（`grep 源码 + assert.match` 一律违规）；走真路径 E2E（真 import + temp `HERMES_HOME`）。
   锚：`AGENTS.md:323-325 / 396-407 / 409-424`｜我方 #65794 被点名的第 3 条问题即源码断言测试。
4. **成本比例自带对账**。任何往既有路径加成本的补丁必须给出「LOC/侵入度 vs 实际伤害」的一行算术；维护者偏好 fail-open + 下次启动自愈，不要新增 fail-closed 拒绝路径。
   锚：`AGENTS.md:89-90`（修法不得毁掉被保护的特性）｜我方 #86062 判例原文「a +453 LOC on-open integrity probe is `disproportionate`」。
5. **需求锚决定优先级类别**。bug 件锚 issue；**无 issue 锚的 feature 属「维护者要不要」类**，上限被压（我方可预期 P3 档）。大机械重构是受欢迎的活，但**必须声明**——声明后「请求」本身就是抽取。
   锚：`AGENTS.md:53-55`（「Every line traces to the request」只管 *feature* PR；声明的重构请求 = 抽取本身）｜我方 #65794（无 issue 锚 + P3 + 三个 `sweeper:risk-*` + `sweeper:blast-moderate`）。
6. **落点 churn 预检（处置成本乘法公式）**：`处置成本 ≈ 面积 × 分支年龄 × 落点 churn`。立项时写下落点的 churn 与拆分计划，并问「60 天后这件还 rebase 得动吗」。
   锚：`AGENTS.md:249-251`（god file / 大函数先拆）｜我方 #65794 活例（见 §3）。
7. **出手前搜双态 + 让路形态**。搜 open **与** merged 的 issue/PR；已被开放车覆盖 ⇒ 转去 review/改进那辆，或高姿态让路，不开竞争 dup（duplicate-check 在 review 时才触发，代价已付）。
   锚：`CONTRIBUTING.md:25,32`｜我方 §3.3 A/B/C 表（absorb / differentiate / stand-down）。
8. **单关注点**。一个逻辑变更一个 PR，不混 fix + refactor + feature；反过来，收编/续作他人车时同样拒绝 facade 追加、god helper、compat alias、wrapper。
   锚：`CONTRIBUTING.md:948` + `AGENTS.md:323-325`。
9. **合并闸的真相**：闸 = CI required checks + 维护者 review；**机器人 review 零合入权重**（CodeRabbit auto-review 仓级已关）。
   锚：`.coderabbit.yaml` 头部注释｜推论：优化目标只能是「让维护者一眼能合」（可合性 + 前提可验 + 成本可控），不是「让机器人给好评」。
10. **前提校验先于写作**。四形态自查：设计即隔离？前提与运行时不符？缺失是刻意的（`git log -p -S` 查）？是否在复活已被否决的方向？
    锚：`AGENTS.md:104-131`。

## 3 活例解剖：#65794（+1361 LOC × 62 天 × 落点重写窗口）

实查（2026-09-18，gh 只读）：`state=OPEN`、`createdAt=2026-07-16T16:48:21Z`、`+1361/−4`、`changedFiles=4`
（`agent/image_routing.py` / `gateway/run.py` / `tests/gateway/test_image_feedback.py` / `tests/gateway/test_image_feedback_gateway_real.py`）、
`headRefOid=3cf1be89340b`、`mergeStateStatus=DIRTY`、labels 含 `P3` + `sweeper:risk-session-state` / `risk-message-delivery` / `risk-compatibility` / `blast-moderate`。

- **上游判词**（2026-07-18，`hermes-sweeper` 机器行 `keep_open salvageability=medium`）三条问题全落在**形态**上：
  ① 展示用模型名读静态配置，而 main 已把权威值改为运行时 ContextVar ⇒「name the wrong model」；
  ② 兄弟路径（后台任务 vision enrichment）未覆盖；
  ③ 测试读实现源码（违 `AGENTS.md` 的禁源码断言条）。
  我方 2026-07-20 已逐条改（`e1316af09`），此后 **62 天零回应**（末次活动 08-06T16:46:16Z）。
- **处置成本实测**（09-18，`contrib-data/pr-disposition-20260918.md` §1.4）：试 rebase `rc=1`、**7 块 / 9176 冲突行**；落点 `gateway/run.py` 自共同祖先删 25107 行 / 增 3566 行（409 提交），`run.py`/`run_turn.py` 已拆分，`_enrich_message_with_vision` 现由 `run_turn.py` 调用 ⇒ **这不是 rebase 而是重做**。
- **公式**：`处置成本 ≈ 面积 × 分支年龄 × 落点 churn` —— 三个乘数任意一个偏大即指数化；本车三项全大（+1361 LOC × 62 天 × god file 拆分窗口）⇒ 9176 行冲突。
- **教训（立项时该问的）**：假如 07-16 立项那一刻问过「落点 60 天后还在吗」，本车要么缩面（单关注点：只做提示行，不动 model 解析）、要么先落 issue 锚再开窗。**面积/落点/需求锚是立项自检项，不是事后复盘项**。
- **当前裁决**：继续守候不 rebase（面全库唯一、无竞品压力；rebase 不改决定合入的三条主因），复查点 2026-10-18。

## 4 与我方既有台账的接口（9 例 → 形态标准）

- 案例 1「覆盖面劣势是最高频败因（4/9）」= 上游条款 1 的我方实证；上游把这条写成了硬要求（含 sibling paths），我方把「覆盖面可能输给竞品」升格为「覆盖面是**通过性**门槛」。
- 案例 6（#86062 disproportionate）= 上游条款 4；上游还有一层我方台账原先没有的偏好：**fail-open + 下次自愈**优于新增拒绝路径。
- 案例 8/9（有货必带、被吸收且改进）= 上游「Contributor credit preserved」（`AGENTS.md:72-73`：salvage 用 cherry-pick 保署名）的另一面；上游**主动**保护署名，所以「有货」的价值高于「说对」。
- 新增维（本库原先缺）：**测试形态**（条款 3）与**落点 churn**（条款 6）——两者在 #65794 上同时咬人，是本库第 10 例的教训来源。

## 5 落地三处（本卡交付）

1. `contrib-data/quality-cases.md`：教训总纲增补「形态标准」段（10 条压缩版 + 锚点）+ 案例行新增第 10 例（#65794 活例）。
2. `deploy/contrib-operator/SKILL.md` §4.3 forge：立项自检增补形态条款（本文件 §2 的可执行浓缩），真源改完 cp 双点 + `diff` 自证。
3. 本文件（引用底稿）。
