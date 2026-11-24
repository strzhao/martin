# 数据工具与原始证据

## 金融数据桥

只读桥：`${ZCODE_FINANCE_BIN:-/Users/stringzhao/.hermes/profiles/hkstock/bin/zcode-finance}`，用户级兜底 `/Users/stringzhao/.local/bin/zcode-finance`。Node.js 22+。

可用 route：

| route | 实际数据能力 |
|---|---|
| `finance_wind_stock` | A/H 股票行情、财务、估值、股东、风险和公司行动 |
| `finance_wind_fund` | 基金档案、费率、净值、ETF 实时估值、定报持仓、规模和持有人 |
| `finance_wind_docs` | 公司公告与财经新闻文本 |
| `finance_hexin_stock` | A 股财务、估值、行情和问财补字段 |
| `finance_hexin_global_stock` | 港美股行情及部分财务数据 |
| `finance_hexin_fund` | 场外基金净值、档案和重仓名单 |
| `finance_search` | 官方与媒体资料发现及 URL 溯源 |

工具会变化，调用前用 `list --route <ROUTE> --json` 查看当前实际工具与参数，不凭记忆猜 schema：

```bash
BIN=/Users/stringzhao/.hermes/profiles/hkstock/bin/zcode-finance
"$BIN" doctor --json
"$BIN" list --route finance_wind_fund --json
"$BIN" call --route finance_wind_fund --tool <实际工具名> --args '<符合schema的JSON>' --json
```

按当前问题选择来源，不需要固定顺序或逢值双源。数据商返回空、召回漂移或口径冲突时，可使用其他数据商、HKEXnews、CNINFO、公司 IR、指数公司、基金法律文件等原始资料。FinanceSearch 和媒体适合发现线索，关键事实回到实际发布者。

## 原始证据

需要复用或审计的数据可写 `$DATA_DIR/evidence/<id>.json`。最小内容：

```yaml
id: <唯一ID>
provider: <实际来源，不是桥名>
query: <原始查询>
retrieved_at: <RFC3339>
data_as_of: <数据自身时点；不同数值可分别记录>
report_period: <适用时>
announcement_date: <适用时>
currency: <适用时>
unit: <适用时>
source_url: <官方或具体记录URL；没有则为null>
raw_response: <未经投资判断改写的原始响应>
```

- 一份证据对应一个实际来源，不把多个 provider 统一标成 Wind 或“披露”。
- `raw_response` 不放 `decision`、组合建议、置换结论或后期汇总。
- 派生值只有确需复用时才另存 `inputs + formula + result + coverage/as_of`；普通计算直接留在研究笔记。
- 凭据、token、cookie、完整密文不得进入证据。桥只在内存解密当前登录态，输出会脱敏。

## 数据边界

- 公共接口不能提供真实可用现金、未成交委托、个人持有期限、实际赎回费和成交回报；这些来自 App 或确认单。
- 场外基金只有日终官方净值，没有官方“实时净值”；盘中估值与日终净值分别记录。
- 基金定报持仓、指数成份权重和实时实际持仓不是一回事，保留各自日期与覆盖范围。
- 旧 `theses/`、`context/`、`plans/`、`briefs/` 和 `discoveries/` 仅作历史研究，按需回查，不默认采用其中的行动与阈值。
