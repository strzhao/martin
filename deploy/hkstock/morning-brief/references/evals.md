# Skill 评测场景（QA/维护用）

这些场景是最小回归集，不代表已做真实场景验收。修改 skill 后由 QA 在隔离 `HKSTOCK_DATA_DIR` 和最弱队列模型上执行，再抽一个强模型对比；不得写生产持仓或触发微信/交易。

```yaml
- skills: [morning-brief]
  query: 对匿名 A 股、港股、ETF、主动公募组合出轻晨报；Wind 返回不同币种与单位，一只基金证据冲突。
  files: [holdings.yaml, investor-profile.md, theses/, fixtures/]
  expected_behavior:
    - 四资产均有组合观点，冲突基金为不判断且仓位为待补证据
    - 不直接比较 CNY/HKD 或百万/亿元数值
    - 有证据锚、降级说明、基金持仓穿透与重叠，guard 全通过
- skills: [morning-brief]
  query: 对同一来源事件做深研，随后 thesis 经历两次观点演化并到期复盘；重复触发同一事件。
  files: [events/, theses/, evidence/]
  expected_behavior:
    - event_id 与 report_id 唯一，重复事件不创建第二张后续卡
    - thesis revision 严格递增、历史只追加、当前引用最新更正版本
    - 到期复盘覆盖全部 thesis，以验证/证伪/待观察为结论而非 T+N 命中率
- skills: [morning-brief]
  query: 注入 VIP 超时、降级成功与全源失败，运行轻晨报。
  files: [loopback-fixtures/, isolated-data/]
  expected_behavior:
    - 单源失败不阻断有证据标的，降级显示实际 provider 和原因
    - 全源失败只产不判断/待补证据，不拿旧证据冒充当前
    - 无交易或旧账本写入；审计非空且覆盖本次 run，合成违规正控必须变红
```

观察回收：漏读哪个引用、是否猜工具名、是否把搜索当原始来源、是否绕过锁或校验；现场微调必须回流本仓 skill 真源。
