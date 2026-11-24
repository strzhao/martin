# hkstock 行动／等待对称决策补丁集成说明

状态：**评测 PASS（2026-11-24 双档全矩阵），可集成。** 详见 `hkstock-data/research/2026-11-24-action-wait-symmetry-eval.md` 的验收裁决节。

## 补丁范围

候选真源：

- `deploy/hkstock/morning-brief/SKILL.md`
- `deploy/hkstock/morning-brief/references/evals.md`
- `scripts/hkstock/materialize_action_wait_evals.py`（只把内嵌 fixture 物化到隔离目录，不运行模型、不访问网络）

本 worktree 的候选文件来自 2026-11-24 主仓工作版本：

- baseline SKILL SHA-256：`ae76a841fc781dc49a954b67c677b4ad4a710d44fd1d0e82d2010f4e962271c0`
- baseline evals SHA-256：`f8a277a831ff60892e453356c87c3b3923b27d9c2f6925cd272b9f79c07c8ddc`

主仓现行真源和运行副本本次均未修改、未部署。主仓已有的 hkstock-watch、IPO 及其他会话改动必须保留。

## 集成前置条件

1. 完整验收报告明确为 PASS；若为 FAIL，只保留负面结果，不集成 SKILL。
2. 主仓目标 SKILL 自上述 baseline 后没有新的未协调修改；先比较哈希，不能用本补丁覆盖新改动。
3. 主仓 `deploy_finance.sh` 的其他部署输入没有不准备上线的变化。
4. 不修改 cron、provider、model、生产持仓、watch 卡或真实投递。

## 主仓集成步骤（由主仓会话执行）

1. 将本 worktree 的两个候选文件同步到主仓相同相对路径；`references/evals.md` 仍是 QA 资产，不进入 hermes active references。
2. 更新以下既有入口的 hkstock 句子，保留周围所有其他内容：
   - 主仓 `CLAUDE.md` 的 hkstock v2 段：新买入/加仓正向候选对行动与等待同尺比较，最终零仓/等待在窄条件下也经一次 fresh reviewer；普通问答、无新研究普通持有、未形成新买入/加仓正向候选的拒绝置换和初步线索不触发。
   - 主仓 `INDEX.md` 的 hkstock 私人研究员行：补充行动/等待机会成本、通道状态与对称复核。
   - 主仓 `.autopilot/knowledge/index.md` 的 hkstock eval 行：由原三场景扩展为原三场景 + 四个行动/等待/通道场景 + 两个豁免控制。
3. 运行：
   - `bash /Users/stringzhao/workspace/martin/scripts/hkstock/tests/t1_holdings.acceptance.test.sh`
   - `bash /Users/stringzhao/workspace/martin/scripts/hkstock/tests/t2_gate.acceptance.test.sh`
4. 预检部署输入后运行 `bash /Users/stringzhao/workspace/martin/scripts/hkstock/deploy_finance.sh`。
5. 用 `cmp` 校验主仓真源与 `/Users/stringzhao/.hermes/profiles/hkstock/skills/morning-brief/` 的 SKILL 和 data reference 一致，并确认 active references 中不存在 `evals.md`。
6. 将最终验收报告复制到主仓 `hkstock-data/research/2026-11-24-action-wait-symmetry-eval.md`。
7. 不提交、不推送、不交易、不触发真实投递，除非用户另行明确指示。

## 回滚

使用集成前保存的精确 SKILL 和文档副本反向恢复，再运行同一部署与 `cmp`。不得整仓 reset/clean，不得覆盖主仓其他未提交改动；失败评测与报告必须保留。
