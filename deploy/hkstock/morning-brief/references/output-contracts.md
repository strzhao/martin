# 研究产物契约

## Contents

- 公共 frontmatter
- 轻晨报
- 事件深研
- thesis
- 周复盘

## 公共 frontmatter

```yaml
---
workflow_id: hkstock-ai-native-v1
report_id: <全数据根唯一>
---
```

事件另加 `event_id`；复盘可加 `review_date: YYYY-MM-DD` 作为到期判定日。

## 轻晨报

写 `$HKSTOCK_DATA_DIR/briefs/<date>-brief.md`，必须含以下两段和表列：

```markdown
## 组合观点
| 标的 | 行动 | 仓位建议 | 教学式原因 | 改变观点的条件 | 证据 |
|---|---|---|---|---|---|
| <标的> | 持有 | 相对上限 10% | <判断方法，不只复述事实> | <可验证触发条件> | [E...] |

## 证据与数据缺口
- <缺失、冲突、降级 provider 与原因、基金持仓穿透与重叠>
- [事件深研 <event_id>](../events/<event>.md)：<仅摘要>
```

- 证据不足或冲突无法调和：该标的 `不判断`，仓位栏恰为 `待补证据`，缺口区列出原因。
- 有基金证据时必须有持仓穿透和重叠分析。旧版四段/五段模板、固定免责尾行与宏观堆叠不再使用。
- 事件链接必须可解析到本地文件；晨报不内嵌深研全文。

## 事件深研

写 `$HKSTOCK_DATA_DIR/events/<event_id>.md`：

```markdown
---
workflow_id: hkstock-ai-native-v1
report_id: <唯一>
event_id: <来源事件唯一 ID>
---
## 事件影响
行动：<闭集之一>
教学式原因：<事件如何改变现金流/行业结构/基金框架>
触发条件：<下一步验证或证伪条件>
仓位建议：<相对上限或待补持仓数据>
证据：[E...]
thesis：[<subject>](../theses/<subject>.md)
```

## thesis

frontmatter 另含 `subject`、`revision: <integer>=1`、`updated_at: <RFC3339>`、`review_after: <YYYY-MM-DD>`。正文五段逐字：

```markdown
## 当前观点
## 关键假设
## 反证与风险
## 证据
## 观点历史
### revision 1
- revision: 1
- 当时证据: [E...]
- 触发条件: <当时为何形成/改变观点>
```

当前证据区至少一个锚且使用最新更正版本；历史可以引用已被更正的旧版本。revision 严格递增，最新历史与 frontmatter 一致。历史 revision 的证据、结论、时间和触发条件一经写入不得原位修改；缺锚只能补录原始证据或在当前观点记录缺口，不能换写过去。所有更新必须经过 `thesis_store.py`。

## 周复盘

写 `$HKSTOCK_DATA_DIR/reviews/<date>-review.md`，覆盖 `review_after <= review_date` 的全部 thesis：

```markdown
## 到期复盘
| 标的 | 结论 | 原假设 | 新增证据变化 |
|---|---|---|---|
| <subject> | <验证、证伪或待观察之一> | <原假设> | <新增证据及其影响> |

## 证据与数据缺口
```

短期 T+1/T+5/T+20 或命中率只能明确标作辅助背景，不得替代原假设验证。`signal_review.py` 不进入新 cron。
