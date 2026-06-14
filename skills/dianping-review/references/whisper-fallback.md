# Whisper 安装故障回退流程

当音频转录不可用时（whisper 未安装 / pip install 超时 / 网络不可达），遵循本流程。

## 适用场景

- `whisper` CLI 未找到（command not found）
- `faster_whisper` Python 包未安装
- `pip3 install faster-whisper` 超时（>120s，常见于慢速网络）
- HuggingFace 模型下载失败（代理/防火墙阻断）

## 已知失败模式（来自 2026-05-03 session）

| 尝试 | 方法 | 失败原因 |
|------|------|---------|
| `pip3 install faster-whisper` | 直接安装 | 超时（>120s），ctranslate2 编译慢 |
| `pip3 install --no-deps faster-whisper` | 跳过依赖 | faster-whisper 装好但缺 av/ctranslate2 |
| `pip3 install av ctranslate2 tokenizers` | 分步安装依赖 | ctranslate2 哈希校验不匹配 |
| `pip3 install --only-binary :all: ctranslate2` | 强制二进制 | av/ctranslate2/tokenizers 装好，但 onnxruntime 缺失 |
| 以上 + `pip3 install socksio` | 修复 SOCKS 代理 | 模型下载阶段 SSL 错误 |

**模型下载阶段失败**（所有 5 种以上方法均失败）：

| 尝试 | 代理/网络配置 | 错误 |
|------|-------------|------|
| 默认环境 | ALL_PROXY=socks5://127.0.0.1:7890 | `httpx` SOCKS 隧道 SSL 断开 |
| `unset ALL_PROXY` | HTTP_PROXY=http://127.0.0.1:7890 | SSL EOF（公司中间人证书） |
| `NO_PROXY=huggingface.co` | 直连 | 连接拒绝（公司防火墙拦截出站） |
| `curl -k https://huggingface.co/...` | 忽略证书 | 连接拒绝 |
| monkey-patch httpx verify=False | HTTP 代理 | 仍然 SSL EOF（httpcore 层问题） |

**根因**：公司代理对 HTTPS 做 SSL 中间人检查，Python 的 SSL 库不信任代理证书。直连 HuggingFace 被防火墙拦截。

## 回退流程

### 1. 快速检测

```bash
python3 -c "from faster_whisper import WhisperModel; print('OK')" 2>&1
```

如果输出 `OK`，正常使用。如果报错，进入回退。

### 2. 跳过一次转录尝试

不要反复尝试安装 whisper。pip install 超时后不要再 retry（每轮浪费 2-5 分钟）。

### 3. 结构调整

在 Step 2c 结构化分析中：
- 语音核心记录区域填写：
  ```
  ⚠️ 语音转录未完成（whisper 未安装 / 网络不可达）
     → 用户真实评价待补充，当前基于图片数据做客观描述
  ```
- 新增「❓ 用户观点（待补充）」区域

### 4. 评价调整

- 所有菜品评分写「（待用户补充）」
- 所有口味描述标注来源：「从图片看，无法确认实际口感」
- 整体评分 / 推荐指数写「（待用户补充）」
- 评价末尾加 `⚠️ 语音转录未完成，用户真实口味评价待补充`

### 5. 质量评审预期

- 真实性维度通常最高（4-5分，因为诚实标注缺口）
- 生动性维度偏低（2-3分，仅视觉一感）
- 实用性维度偏低（2-3分，无口味指导）
- 总分预期 12-15（刚好通过或接近阈值）

### 6. 恢复

当 whisper 可用后：
1. 删除文件夹中的 `.reviewed` 标记文件
2. 重新触发 skill
3. 完整流水线用语音+图片重新生成
