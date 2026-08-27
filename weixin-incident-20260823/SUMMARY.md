# weixin 通道投递故障取证 — 2026-08-23

## 故障窗口
- 08-20 09:05–09:38 晨间 cron 三波失败（token 36.3–36.9h）
- 08-20 10:22 一次入站互动后恢复（对照组）
- 08-22 09:05 / 08-22 22:08 失败（token ~57h）
- 08-23 09:05/09:09/09:32 三任务投递失败（token 57.8→58.3h 递增）
- gateway PID 97088（08-15 启动，运行 8 天）；08-21~08-23 三天 inbound=0

## 根因链（gateway-extract.log / errors-extract.log 逐行）
1. 真实错误：`ret=-2 errcode=None errmsg='prepare failed'`（iLink 会话 prepare 层，非 context_token 层）
2. **tokenless retry 同样失败** → 恢复需入站或重连，#80426 效力边界实锤
3. 熔断器误归类：`rate-limit circuit OPENED: 1 event(s) in 30s window`（threshold=1，服务端错误进限流窗口）→ 单发失败即 30s fail-fast，吞掉重试链
4. 三层防线全灭序列：live adapter(计数 69-71) → 熔断 → `falling back to standalone`(计数 1-2) → prepare failed → 第二熔断器
5. cron list 表象=`⚠ rate limited`（熔断文案覆盖真实根因）

## 恢复实验（21:25，对照 08-20 10:22 第二次验证）
- 21:25:41.923 `context token refreshed`（与 inbound 同秒、与 token 文件 mtime 同秒）
- token diff：同长度 136 / 同前缀 / **值不同** → 服务端主动换发，非本地重写
- 21:25:47 回复发送成功，零失败记录
- typing 探测 inconclusive（回复 2.5s 太快无 typing 窗口）
- 结论：**收发通道分离**——入站通道三天一直健康（零 inbound=用户没发），出站 prepare 层过期；入站即恢复

## 补投
21:28 期货日报 / 21:30 AI 日报 / 21:32 今日待办，全部 ok 无 ⚠

## 文件清单
- token-backup-e68a27a2 / 5dbdf498.context-tokens.json（故障态 token）
- token-after-recovery.json（恢复后 token）
- account-e68a27a2.json / sync-e68a27a2.json
- gateway-extract.log（78 行四窗口摘录）/ errors-extract.log（132 行）

## 上游价值
- #35283（07-19 撤回的 weixin 投递可靠性 PR）重开的精确弹药：stale session→prepare 层更深、熔断器=当年"想并入"的放大器
- 新 PR 骨架：①熔断器事件归类（ret=-2≠频率事件）②prepare failed 降级链（重连/标记待互动）③异通道告警（微信死时邮件兜底，#83993 方向 3）
