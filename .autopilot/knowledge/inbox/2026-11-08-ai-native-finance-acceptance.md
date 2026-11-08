### [2026-11-08] 真实 Agent 验收必须绑定原始运行身份与副作用
<!-- tags: hermes, e2e, sandbox, evidence, finance -->

**Scenario**: 验收包含真实模型、外部数据、文件/网络副作用和消息投递的 AI 工作流，尤其当测试支持复用历史产物时。

**Lesson**: 真实产物、成功回执和内容正确性必须分别验证，并绑定到同一个原始运行身份；完成状态、provider、session、文件/网络副作用与凭据扫描都应 fail-closed。补投或后续重放只能作为独立证据，不能改写原自动链的结论。

**Evidence**: 本次曾出现 default profile 误绑、生产 session 可满足隔离断言、wrapper 固定成功、旧 sidecar 缺字段被默认空数组掩盖等问题；最终通过精确 session、每 run sidecar、原始 allowed-target 账本和注入正控闭合。S12.P2 的原 wake-only 正文不一致则始终保留 FAIL，direct 原文补投未用于冒充原链通过。

**Anti-overfitting check**: 原则不依赖具体模型、版本、路径、场景编号或计数；删掉 Evidence 后仍成立，可迁移到其他真实 Agent 工作流验收。
