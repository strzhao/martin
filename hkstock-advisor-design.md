# hkstock 3.0：AI Native 金融工作流

> 状态：实现契约已冻结；真实 VIP、真实 AI 场景与切流验收由 QA 执行。
> 范围：A 股、港股、ETF、场外公募；保留 hkstock profile、持仓/画像/thesis、cron/kanban/微信运输层，不新建第二套理财系统。

## 1. 产品原则

1. **一个研究员**：轻晨报、事件深研、股票/基金问答和 thesis 复盘共用同一工作流，不使用多 Agent 委员会。
2. **组合观点优先**：每标的给行动、教学式原因、改变观点的条件和仓位建议；默认持有/不动，不堆宏观与行情播报。
3. **证据先于结论**：关键数据保存原始响应与来源链，报告期、实际公告日、币种、单位和版本必须可核对。
4. **反证与活体记忆**：thesis 保存当前观点、关键假设、反证、证据和追加式历史；复盘回答验证/证伪/待观察。
5. **只研究不执行**：不自动交易、不撤单、不写旧 A 股账本；真实微信或对外发布须用户一次性批准。

## 2. 当前架构

```text
ZCode Wind / Hexin / docs / FinanceSearch
                  │
       zcode-finance（Node 22 薄桥）
                  │
       单 AI 研究员 morning-brief skill
                  │
     evidence + brief + event + thesis + review
                  │
          research_guard.py 确定性校验
                  │
      hkstock cron / kanban / wake-only 微信运输
```

mktd/AkShare 是降级与交叉核验源；巨潮/披露易是公告原文核验源。FinanceSearch 只作发现入口，不充当原始来源。指数基金 monitor 继续作为独立确定性探针，不在研究主链重复写信号。

## 3. 数据层：固定只读薄桥

`zcode-finance` 同时提供 CLI 和 stdio MCP server：

```text
zcode-finance doctor [--json]
zcode-finance list [--route <ROUTE>] [--json]
zcode-finance call --route <ROUTE> --tool <NAME> [--args <JSON>] [--json]
zcode-finance serve [--routes <CSV>]
```

仅允许 `finance_wind_stock`、`finance_wind_fund`、`finance_wind_docs`、`finance_hexin_stock`、`finance_hexin_global_stock`、`finance_hexin_fund`、`finance_search`。远程工具名在 stdio 映射为 `<route>__<original_name>`。

每次请求读取当前 ZCode 加密凭据，按官方 AES-256-GCM 规则在内存解密，携带 `Authorization`、`X-Bigmodel-Authorization`、`Bigmodel-Target-Type` 三组认证头。token 不明文落盘、不进日志、不进入静态 MCP 配置。强制 initialize，支持 tools/list、tools/call、ping、超时、错误分类和脱敏；仅工具 schema 做短时内存缓存，投资数据不做跨班次陈旧缓存。

生产只连 HTTPS ZCode 网关；HTTP 仅用于 loopback 契约测试。默认超时 30000ms，`ZCODE_MCP_TIMEOUT_MS` 合法范围 1000–120000ms。错误 exit：USAGE=2、CREDENTIAL=3、AUTH=4、UPSTREAM=5、REMOTE_TOOL=6。

## 4. 证据与研究契约

证据写 gitignore 的 `$HKSTOCK_DATA_DIR/evidence/<id>.json`，字段包括 `schema_version=1`、id、subject、`asset_type=stock|fund`、provider、route、tool、query、报告期、实际公告日、币种、单位、URL、页码、来源版本、supersedes、retrieved_at、provenance 和 raw_response。`Hexin` 在证据中规范映射为 `同花顺 iFinD`。

公告更正/重述通过 supersedes 形成无环闭链；当前观点使用最新版本，历史观点保留当时版本。缺字段、非法枚举、非法时间、page<1、认证材料或版本循环均由 guard 拒绝。

所有研究产物带 `workflow_id: hkstock-ai-native-v1` 与唯一 `report_id`：

- **简报**：必须有 `## 组合观点` 和 `## 证据与数据缺口`；表列至少为标的、行动、仓位建议、教学式原因、改变观点的条件、证据。
- **行动闭集**：买入、加仓、持有、减仓、清仓、观望、不判断。非不判断观点必须有本地 `[E...]` 锚。
- **缺口**：证据不足或冲突时该标的不判断、仓位为待补证据，并在缺口区列出原因；其他证据充足标的不受阻断。
- **降级**：显示实际 provider 与原因；全源失败不产生新确定性观点，不把旧证据标成当前。
- **仓位**：持仓/现金/风险预算不全时只给相对上限或待补持仓数据，禁止精确金额。
- **事件深研**：独立 event_id，包含事件影响、行动、教学式原因、触发条件、仓位建议、证据和 thesis 链接；晨报只引用摘要和可解析路径。
- **thesis**：frontmatter 含 subject、revision>=1、updated_at、review_after；正文包含当前观点、关键假设、反证与风险、证据、观点历史。历史只追加。
- **复盘**：覆盖全部到期 thesis，给验证/证伪/待观察、原假设与新增证据变化。T+1/T+5/T+20 命中率仅可作明确标注的辅助背景。

`research_guard.py` 提供 `evidence/brief/thesis/review` 四模式，只校验完整性、引用闭链、必需章节、版本与可注入副作用审计，不评价投资观点好坏。

## 5. 基金研究

ETF 必须覆盖指数规则、费率、跟踪质量、流动性与折溢价；主动公募必须覆盖经理真实任期、投资框架、风格漂移、费率和定报持仓。基金与直接持股按经济主体穿透重叠，说明组合隐性集中、已知权重下限和报告期；无法取得完整持仓时不编造精确集中度。

## 6. 并发与交付

晨报仍走既有 hkstock cron 直建卡、显式 wake 订阅与 watchdog；保留 schedule、provider/model 和运输配置。新候选、财报/基金定报、重大公告或 thesis 逻辑变化才触发深研，不新增盘中高频任务。

晨报最多创建一张事件深研后续卡，幂等键 `event-research-<source_event_id>`。同标的 thesis 用原子目录锁串行，临时文件加原子 rename 防覆盖。无重大事件不建卡。

## 7. Legacy 与旧 A 股迁移

`signals.jsonl` 和 `signal_review.py` 保留为历史/辅助证据，schema 与 append-only 不变，不进入新 cron。旧四段/五段模板、固定免责尾行、以短期命中率为主判据的口径全部废止。

主 checkout `.zcode/workflow-drafts/` 与 `out/a-share-*` 是只读事实源；一次性迁移摘要进入 hkstock 私有运行数据，原文件不归并、不持续同步，`out/a-share-*` 在 gitignore 明确排除。

**切流采用验收后开关**：只有新链真实验收通过且旧自动化停用入口可验证时，才停用旧自动写账/出票动作并核对无第二个 A 股 cron。无法安全验证就保留旧链并记录阻断，不宣称切流完成。

## 8. 部署、回滚与验证边界

仓内真源：

- `scripts/finance/zcode-mcp-bridge.mjs` 与 Node 契约测试
- `scripts/hkstock/research_guard.py`、匿名 fixture 与单元测试
- `deploy/hkstock/morning-brief/SKILL.md` 及一层 references
- `scripts/hkstock/deploy_finance.sh` 与运行配置迁移配方

部署只同步 profile bin、用户级 `zcode-finance` 和 morning-brief skill，并 `cmp` 自证；不覆盖私密运行数据。运行配置修改前备份。回滚恢复备份的 SOUL/cron，并重新部署上一版 skill/bridge；证据和 thesis 历史不删除。

蓝队只做编译、导入和单元测试。真实 VIP 查询、隔离四资产 AI 场景、故障降级、部署 readback、真实微信 S12 与旧链停用由 QA/编排器验收；dry-run 或未批准项不得写成 PASS。
