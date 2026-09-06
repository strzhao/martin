# 设计决策记录

<!-- tags: python, macos, environment -->

## 2026-05-03 — whisper 语音识别环境在 Apple Silicon 上的最优方案

**决策**：选择 mlx-whisper 作为主引擎（Apple MLX 框架，Metal GPU/ANE 加速），faster-whisper 作为备选（CTranslate2 CPU 优化），openai-whisper 仅作兼容层。

**原因**：
- M4 Max 128GB + Metal 4 环境下，mlx-whisper 利用 ANE + GPU 联合加速，tiny 模型推理 < 1.5s
- MLX 是 Apple 官方框架，无需额外配置即可使用 Metal GPU
- whisper.cpp 虽然更快但需要编译步骤，CI/CD 不便
- openai-whisper 依赖 PyTorch（~2GB），仅保留作为 API 兼容

**前提**：brew 安装的 Python 3.12 受 PEP 668 保护，必须先 `python3 -m venv .venv` 创建虚拟环境。

**模型选择**：tiny（~75MB）快速测试 / base（~150MB）日常转写 / large-v3（~3GB）高精度

## 2026-06-11 — 本地 LLM API 封装为 CLI 工具的技术选型

<!-- tags: cli, typescript, llm, qwen -->

**背景**：本地 llama.cpp llama-server 提供 OpenAI 兼容 API（`/v1/chat/completions`），但直接 curl 调用有多个痛点（JSON 转义、base64 OS 差异、参数记忆）。需要封装为 CLI 工具方便 Claude Code 等 Agent 调用。

**选择**：TypeScript + commander + tsup，独立 `qwen` 命令（非 opencli external）。

**拒绝的替代方案**：
- Shell 脚本：JSON 处理脆弱，base64 命令跨平台差异大
- opencli internal adapter：框架设计为浏览器自动化，API 包装过度依赖
- opencli external register：增加一层间接调用，不如独立命令直接

**权衡**：TypeScript 工程需要编译步骤（tsup），但换来类型安全、跨平台一致的 base64 编码、commander 自动生成 `--help`。

## 2026-06-11 — travel-planner skill 多源信息采集 + HTML 输出架构

<!-- tags: skill, travel, api, opencli, multi-source, html -->

**决策**：6 路并行搜索（高德 API + opencli dianping/xhs/bilibili/weixin + WebSearch）→ 交叉验证 → HTML 模板注入 → 零依赖 HTTP 服务器 → tunnel 公网暴露。

**原因**：
- 纯 WebSearch 只能获取第三方转载，无法获取原文评分/字幕/互动数据
- opencli dianping shop 返回结构化评分（口味/环境/服务），信息密度最高
- opencli bilibili subtitle 逐句字幕含真实探店评价+价格，文字攻略无法提供
- 高德 API 提供天气/POI 评分/路线，结构化数据 LLM 无法自编
- 交叉验证（≥2 源确认）有效过滤营销内容

**关键 dry-run 发现**：
- 高德 QPS 并发 4 请求触发限流，需串行 + 0.3s 间隔
- 高德关键词精准度决定命中率：「绍兴菜」>>「餐厅」
- 小红书 note 被 `SECURITY_BLOCK` 拦截，仅 search 可用
- B站字幕是意外的高价值源
- Qwen3.6-35B thinking 模型视觉识别需 max_tokens ≥ 2000

**HTML 输出模式**：单文件 HTML 模板（`__TRIP_DATA__` 占位符）→ Python inject.py 注入 → Node.js 零依赖 http 服务器 → tunnel CLI（frpc）暴露公网 URL 供微信访问。

## 2026-06-13 — restaurant-recommender skill：复用 travel-planner 架构创建第二个领域 skill

<!-- tags: skill, restaurant, food, architecture-reuse, multi-source -->

**决策**：复制 travel-planner 的已验证架构（多源搜索 → 交叉验证 → JSON → lint → HTML 注入 → HTTP 服务 → tunnel），仅替换领域模型（trip/timeline → recommendation/restaurants）和 UI（时间线 → 排名卡片）。

**验证**：红队验收测试 37/37 通过，QA 审查通过，auto-fix 完成 3 项修复（inject.py 错误处理、lint.py tiers 校验、server.js pipe error 监听）。

**复用率**：inject.py 100%、template.html CSS 体系 70%、lint.py 框架 50%、SKILL.md 多源搜索模式 60%、references 80%。

**新增模式**：
- `test_data_valid.json` + `test_data_invalid.json` 作为 lint.py 的 fixture 数据
- `test_lint.py` / `test_inject.py` / `test_server.py` 作为红队验收测试的标准三板斧
- 新 skill 使用独立端口（3457 vs 3456）避免与 travel-planner 冲突

<!-- tags: hermes, observability, sqlite, config-chain, events-sink, dogfood -->
## [2026-08-23] hermes 事件落库(T1)架构四决策(全部实证驱动)
①**懒启动 atexit 而非 gateway 挂接**:信息隔离的验收谓词冻结「import 即用免初始化」契约,倒逼推翻"仅 gateway 进程落库"原设计——删掉 gateway/run.py 挂接反而 diff 更小,任何进程统一语义。②**新 telemetry DB 不设 journal_mode**:本机 SQLite 3.50.4 落 #70055 WAL-reset 门控窗口,`apply_wal_with_fallback` 对全新 DB 强制 delete(venv 复现);接受框架策略走 busy_timeout,勿硬设 WAL 与门控打架(门控前提本身存疑:teknium1 A/B 证 3.53 照样复现,潜在上游议题)。③**telemetry.* 消费链分叉坑**:`telemetry.shared_metrics.enabled` 走 raw yaml reader(缺失=禁用),新键默认值必须生效就得走 `load_config_readonly()`(含 DEFAULT_CONFIG 合并)——同一配置段两种读法语义相反。④**检查器/spy 类 SQLite 连接**:显式 `check_same_thread=False` + 失败缓存不重试 + WARNING 单行化(exc_info 的 traceback 文本会污染"无未捕获异常"类验收断言,traceback 降 DEBUG)。

<!-- tags: hermes, weixin, token, forensics, dogfood, context-token -->
## [2026-08-24] weixin context token v2:issued_at 落盘 + 双 dict 职责分离
T2 给 ContextTokenStore 引入 v2 文件格式({user_id: {"token": str, "issued_at": epoch}}):①`_issued_at`(权威锚点,仅 v2 文件条目与 set() 填充)与 `_set_at`(运行时 age,v1 用 mtime 回填)职责分离——杜绝 mtime 值伪装 issued_at;②未知 issued_at 落盘**省略键不写 null**;③v1/v2/混合逐条 isinstance 判别;④回滚到 v1 读侧时 dict 条目被跳过 → token 缓存清空,靠下一条入站消息自愈(部署协议须知)。TTL 取证从此不再依赖文件 mtime(08-23 事故的 22.5-33.8h 手工三方 join 根因之一被消灭)。

## [2026-09-06] L2-A 审批交互化选型：卡内短码能力 URL + 页面判定层下沉 tunnel-cli
微信审批从「打字 批 #id」升级为「点链接即批」。关键裁决：①安全模型=审批页公开读公开写的前提下，提交有效性唯一凭据=名字栏==卡内短码（短码经 `?key=` 自动回填，微信零打字）；两段式（点击+微信确认）因多一轮交互被否，威胁模型如实声明「防机会主义不防设备攻破」。②页面与判定层（审批页模板/decision 判定提取/预填）下沉 tunnel-cli 成为通用能力，martin 只留编排薄壳（发卡/轮询/执行）——复用其 blocks/渲染/results 管线，避免重复建设。③执行器选确定性 bash 而非 hermes agent（凌晨无人值守场景零 LLM 方差；微信文本回复路继续走 skill）。④暗 launch：plist 不自动装载、config 开关缺省 false、特性和开关分离——带 bug 的 90s 轮询器不夜里自己上线。被否方案与理由全文见 `.autopilot/runtime/requirements/20260905-开始实现，全程不要问/brainstorm.md` 与 state.md 设计文档。

<!-- tags: approval, security-model, capability-url, tunnel-cli, dark-launch, yagni -->

## 2026-09-06 — 零依赖 CLI 下的 YAML 编辑：手写针对性行级编辑器

<!-- tags: typescript, yaml, zero-dependency, gcli, config-editing -->

**决策**：gcli hermes 子命令改写 ~/.hermes/config.yaml 不用任何 YAML 库，自写行级编辑器 `editHermesConfig`（col-0 段表 → model 段逐键替换/缺键插入 → providers 段条目块 upsert/段尾追加 → 标量 quoting 白名单）。

**原因**：
- gcli 硬约束零 npm 依赖；python3 stdlib 无 yaml、PyYAML/yq 不保证安装
- 全量 YAML round-trip 会摧毁配置文件的注释与排版（hermes config.yaml 含 personality 文案）
- 目标文件结构实测规整（model 段 3 键、providers 为最后顶层段、2/4 空格缩进），局部编辑可行

**关键纪律**：**宁报错不猜**——段缺失/意外嵌套一律返回 {error} 零写盘（用户落回手动流程，备份永远在）；备份先行 + tmp+rename 原子写；幂等性用单测钉死（edit∘edit ≡ edit），quoting 首次会把带空格值重写为单引号形（语义等价，稳态后零漂移）。

**适用边界**：仅当目标配置文件结构规整且编辑面局部时成立；结构复杂的 YAML 仍需真 parser。
