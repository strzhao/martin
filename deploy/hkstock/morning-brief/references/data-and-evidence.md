# 数据路由与证据账本

## 固定只读 route

| route | provider（桥输出） | 用途 |
|---|---|---|
| `finance_wind_stock` | Wind | A/H 股票基本面、估值与财务 |
| `finance_wind_fund` | Wind | ETF/主动公募档案、定报与持仓 |
| `finance_wind_docs` | Wind | 公告与定报原文发现 |
| `finance_hexin_stock` | Hexin | A 股交叉检查/问财 |
| `finance_hexin_global_stock` | Hexin | 港股及全球股票交叉检查 |
| `finance_hexin_fund` | Hexin | 基金交叉检查 |
| `finance_search` | FinanceSearch | 只作来源发现 |

命令：
```bash
BIN=/Users/stringzhao/.hermes/profiles/hkstock/bin/zcode-finance
"$BIN" doctor --json
"$BIN" list --route finance_wind_stock --json
"$BIN" call --route finance_wind_stock --tool <tools/list中的name> --args '{"symbol":"..."}' --json
```

默认超时 30000ms；`ZCODE_MCP_TIMEOUT_MS` 仅允许 1000–120000。凭据由桥每次从当前 ZCode 登录态读取并内存解密；不得打印、复制或写入证据。桥不可用时记录错误类别，不尝试绕开认证。

## 证据文件

每个关键响应写 `$HKSTOCK_DATA_DIR/evidence/<id>.json`；`id` 匹配 `^E[A-Za-z0-9_-]+$`，文件名必须相同。UTF-8 JSON object 必填：

```text
schema_version: 1
id, subject, asset_type (stock|fund), provider, route, tool
query: object（原始查询参数）
report_period, announcement_date, currency, unit, source_url: string|null
page: integer|null（>=1）
source_version, supersedes: string|null
retrieved_at: RFC 3339（含时区）
provenance: 披露|测算|预期|推断|媒体
raw_response: object|array
```

- provider 只能是 `Wind|同花顺 iFinD|Sina|Eastmoney|AkShare|CNINFO|HKEXnews|Media`。记录实际数据提供方，不写桥名；桥输出 Hexin 时转为 `同花顺 iFinD`。
- 无报告期语义用 null；公告日不得拿报告期代替。无具体记录 URL 用 null，不填数据商首页。保留原币种和单位。
- 公告/定报保存公告 ID、官方版本或内容哈希。更正/重述以 `supersedes` 指向旧证据，链必须闭合并无环；当前观点只用最新版本，历史记录保留当时版本。
- Media 只能配合 `provenance: 媒体` 与具体 `source_url`。搜索接口不是原始来源。
- raw_response 不改投资数值，且不得含 Authorization、token、cookie、key 或完整密文。

## 降级与冲突

- 降级时在简报 `## 证据与数据缺口` 写实际 provider 与原因，例如 `降级：AkShare；原因：VIP initialize 超时`。
- 全部源不可用：所有相关标的 `不判断`、`待补证据`，不产生新确定性观点，不把旧证据标成当前。
- 腾讯等跨市场财务常见 CNY/HKD、百万/亿元差异；先核对口径再比较。报告期或公告日不同也不能直接拼成同一期。
