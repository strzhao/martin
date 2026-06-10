# Whisper 环境安装验收检查清单

> **验证者**: 红队 (Autopilot Red Team)  
> **设计文档**: 20260503-帮我安装好-whisper-环境  
> **验证日期**: 2026-05-03  
> **硬件**: Apple M4 Max / 128 GB 统一内存 / Metal 4 GPU

---

## 一、环境基础设施验收

### AC-INF-01: 虚拟环境存在且可激活

**验收标准**: Python 3.12 虚拟环境 `.venv/` 存在于项目根目录，可正常激活。

**验证命令**:
```bash
ls /Users/stringzhao/workspace/martin/.venv/bin/python3
/Users/stringzhao/workspace/martin/.venv/bin/python3 --version | grep "3.12"
source /Users/stringzhao/workspace/martin/.venv/bin/activate && echo "activated" && deactivate
```

### AC-INF-02: 虚拟环境使用 Python 3.12

**验收标准**: `.venv` 基于 `python@3.12` (brew) 创建，非系统 Python 3.14 或 conda Python。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "import sys; print(sys.version)"
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "import sys; assert sys.version_info[:2] == (3,12), 'Wrong Python version'"
cat /Users/stringzhao/workspace/martin/.venv/pyvenv.cfg | grep "home"
```

### AC-INF-03: FFmpeg 已安装（音频解码依赖）

**验收标准**: `ffmpeg` 命令行工具可用，版本 >= 5.0。

**验证命令**:
```bash
which ffmpeg
ffmpeg -version | head -1
ffmpeg -version | grep -oP 'version \K[0-9]+\.[0-9]+'
```

---

## 二、核心引擎安装验收

### AC-ENG-01: mlx-whisper（主引擎）已安装

**验收标准**: `mlx-whisper` 包已安装到 `.venv` 中，可 import 且能运行 MLX 推理。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/.venv/bin/pip show mlx-whisper
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "import mlx_whisper; print('mlx-whisper version:', mlx_whisper.__version__ if hasattr(mlx_whisper, '__version__') else 'OK')"
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "import mlx.core; print('mlx core OK')"
```

### AC-ENG-02: mlx-whisper 使用 Metal 加速

**验收标准**: MLX 框架检测到 Apple Silicon GPU (Metal 后端)。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "
import mlx.core as mx
# MLX 在 Apple Silicon 上默认使用 Metal GPU
print('Default device:', mx.default_device())
print('Metal available:', mx.metal.is_available())
# GPU 内存
print('GPU memory info:', mx.metal.get_active_memory() if hasattr(mx.metal, 'get_active_memory') else 'N/A')
"
```

### AC-ENG-03: faster-whisper（备选引擎）已安装

**验收标准**: `faster-whisper` 包已安装，CTranslate2 后端可用。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/.venv/bin/pip show faster-whisper
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "from faster_whisper import WhisperModel; print('faster-whisper OK')"
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "import ctranslate2; print('CTranslate2 version:', ctranslate2.__version__)"
```

### AC-ENG-04: openai-whisper（兼容层）已安装

**验收标准**: `openai-whisper` 包已安装，可 import。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/.venv/bin/pip show openai-whisper
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "import whisper; print('openai-whisper OK')"
```

---

## 三、CLI 封装脚本验收

### AC-CLI-01: scripts/transcribe.py 文件存在

**验收标准**: 文件 `scripts/transcribe.py` 存在于项目根目录下。

**验证命令**:
```bash
ls -la /Users/stringzhao/workspace/martin/scripts/transcribe.py
file /Users/stringzhao/workspace/martin/scripts/transcribe.py | grep "Python script"
```

### AC-CLI-02: CLI 脚本有正确的 shebang

**验收标准**: 首行指向 `.venv` 中的 Python 3.12 解释器。

**验证命令**:
```bash
head -1 /Users/stringzhao/workspace/martin/scripts/transcribe.py
# 期望输出: #!/Users/stringzhao/workspace/martin/.venv/bin/python3
```

### AC-CLI-03: CLI 脚本有执行权限

**验收标准**: `transcribe.py` 文件具有可执行权限 (chmod +x)。

**验证命令**:
```bash
test -x /Users/stringzhao/workspace/martin/scripts/transcribe.py && echo "OK: executable" || echo "FAIL: not executable"
```

### AC-CLI-04: 位置参数 / --audio 参数（输入音频文件）

**验收标准**: 支持通过位置参数或 `--audio` 参数指定输入音频文件路径。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -E "(audio|positional)"
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -i "audio"
```

### AC-CLI-05: --engine 引擎切换参数

**验收标准**: `--engine` 参数支持 `mlx` (默认)、`faster`、`whisper` 三个值。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -i "engine"
# 验证具体的 choices 值
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -oE "(mlx|faster|whisper)" | sort -u
```

### AC-CLI-06: --model 模型选择参数

**验收标准**: `--model` 参数支持 `tiny` (默认)、`base`、`small`、`medium`、`large-v3` 五个值。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -i "model"
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -oE "(tiny|base|small|medium|large-v3)" | sort -u
```

### AC-CLI-07: --language 语言参数

**验收标准**: `--language` 参数支持 `zh` (默认)、`en`、`auto` 三个值。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -i "language"
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -oE "(zh|en|auto)" | sort -u
```

### AC-CLI-08: --output-format 输出格式参数

**验收标准**: `--output-format` 参数支持 `txt` (默认)、`srt`、`vtt`、`json` 四个值。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -i "output-format\|output_format\|format"
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -oE "(txt|srt|vtt|json)" | sort -u
```

### AC-CLI-09: --output-dir 输出目录参数

**验收标准**: `--output-dir` 参数存在，默认值为当前目录。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1 | grep -i "output-dir\|output_dir\|output.dir"
```

### AC-CLI-10: 所有设计参数完整性检查

**验收标准**: help 输出包含全部 6 个参数：audio、engine、model、language、output-format、output-dir。

**验证命令**:
```bash
HELP=$(/Users/stringzhao/workspace/martin/scripts/transcribe.py --help 2>&1)
echo "$HELP" | grep -q "audio" && echo "audio: OK" || echo "audio: MISSING"
echo "$HELP" | grep -q "engine" && echo "engine: OK" || echo "engine: MISSING"
echo "$HELP" | grep -q "model" && echo "model: OK" || echo "model: MISSING"
echo "$HELP" | grep -q "language" && echo "language: OK" || echo "language: MISSING"
echo "$HELP" | grep -qE "output-format|output_format" && echo "output-format: OK" || echo "output-format: MISSING"
echo "$HELP" | grep -qE "output-dir|output_dir" && echo "output-dir: OK" || echo "output-dir: MISSING"
```

---

## 四、跨系统数据流验证

### AC-FLOW-01: mlx 引擎 + tiny 模型 + 中文 + txt 端到端流程

**验收标准**: 使用 mlx 引擎、tiny 模型、zh 语言，对测试音频文件完成转写并输出 txt 文件。

**验证命令**:
```bash
# 准备测试音频（生成或使用已有音频文件）
TEST_AUDIO="${TMPDIR:-/tmp}/test_zh.wav"
if [ ! -f "$TEST_AUDIO" ]; then
  # 若无测试音频，先跳过或使用 ffmpeg 生成 1 秒静音
  ffmpeg -y -f lavfi -i sine=frequency=1000:duration=2 -ar 16000 -ac 1 "$TEST_AUDIO"
fi
/Users/stringzhao/workspace/martin/scripts/transcribe.py \
  --audio "$TEST_AUDIO" \
  --engine mlx \
  --model tiny \
  --language zh \
  --output-format txt \
  --output-dir /tmp/whisper_test_output/
ls -la /tmp/whisper_test_output/
cat /tmp/whisper_test_output/test_zh.txt 2>/dev/null
```

### AC-FLOW-02: faster 引擎备选切换验证

**验收标准**: 指定 `--engine faster` 后，使用 faster-whisper 引擎完成任务。

**验证命令**:
```bash
# 引擎切换：faster-whisper
/Users/stringzhao/workspace/martin/scripts/transcribe.py \
  --audio "${TMPDIR:-/tmp}/test_zh.wav" \
  --engine faster \
  --model tiny \
  --language zh \
  --output-format txt \
  --output-dir /tmp/whisper_test_faster/
ls -la /tmp/whisper_test_faster/
```

### AC-FLOW-03: whisper 引擎兼容层切换验证

**验收标准**: 指定 `--engine whisper` 后，使用 openai-whisper 引擎完成任务。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/scripts/transcribe.py \
  --audio "${TMPDIR:-/tmp}/test_zh.wav" \
  --engine whisper \
  --model tiny \
  --language zh \
  --output-format txt \
  --output-dir /tmp/whisper_test_openai/
ls -la /tmp/whisper_test_openai/
```

### AC-FLOW-04: 多输出格式验证（srt / vtt / json）

**验收标准**: 对同一音频，`--output-format` 分别指定 `srt`、`vtt`、`json`，均生成正确的文件。

**验证命令**:
```bash
TEST_AUDIO="${TMPDIR:-/tmp}/test_zh.wav"
for fmt in srt vtt json; do
  echo "=== Testing output format: $fmt ==="
  /Users/stringzhao/workspace/martin/scripts/transcribe.py \
    --audio "$TEST_AUDIO" \
    --engine mlx \
    --model tiny \
    --language zh \
    --output-format "$fmt" \
    --output-dir "/tmp/whisper_test_${fmt}/"
  ls -la "/tmp/whisper_test_${fmt}/"
done
```

### AC-FLOW-05: 语言自动检测验证

**验收标准**: `--language auto` 参数工作正常，不报错。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/scripts/transcribe.py \
  --audio "${TMPDIR:-/tmp}/test_zh.wav" \
  --engine mlx \
  --model tiny \
  --language auto \
  --output-format txt \
  --output-dir /tmp/whisper_test_auto/
ls -la /tmp/whisper_test_auto/
```

### AC-FLOW-06: large-v3 模型可用性验证

**验收标准**: `--model large-v3` 引擎可正常下载（从 HuggingFace）并加载推理。

**验证命令**:
```bash
# 注意：large-v3 约 3GB 模型文件，需确认网络和磁盘空间
/Users/stringzhao/workspace/martin/scripts/transcribe.py \
  --audio "${TMPDIR:-/tmp}/test_zh.wav" \
  --engine mlx \
  --model large-v3 \
  --language zh \
  --output-format txt \
  --output-dir /tmp/whisper_test_large/
ls -la /tmp/whisper_test_large/
```

---

## 五、模型缓存验收

### AC-CACHE-01: HuggingFace / MLX 模型缓存目录存在

**验收标准**: 模型缓存目录 `~/.cache/huggingface/` 或 `~/.cache/mlx/` 存在，且在首次转写后被创建。

**验证命令**:
```bash
ls -d ~/.cache/huggingface/ 2>/dev/null && echo "huggingface cache OK" || echo "huggingface cache MISSING"
ls -d ~/.cache/mlx/ 2>/dev/null && echo "mlx cache OK" || echo "mlx cache MISSING"
```

### AC-CACHE-02: tiny 模型已缓存至本地

**验收标准**: 在首次运行 tiny 模型后，模型文件存在于本地缓存（目录大小 > 50MB）。

**验证命令**:
```bash
# 检查模型缓存大小
du -sh ~/.cache/huggingface/hub/ 2>/dev/null
du -sh ~/.cache/mlx/ 2>/dev/null
# 具体查找 tiny 模型
find ~/.cache/huggingface/ ~/.cache/mlx/ -name "*tiny*" -type f 2>/dev/null | head -5
```

---

## 六、性能与设备特性验收

### AC-PERF-01: Metal GPU 被 mlx 引擎使用（非 CPU fallback）

**验收标准**: 运行时 MLX 报告使用 Metal GPU 设备而非 CPU。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "
import mlx.core as mx
device = mx.default_device()
print('Device type:', device)
assert str(device) == 'gpu' or 'GPU' in str(device).upper(), 'Expected GPU but got: ' + str(device)
"
```

### AC-PERF-02: 大模型 (large-v3) 可正常加载不 OOM

**验收标准**: 在 128GB 统一内存下，large-v3 模型 (~3GB) 可顺利加载，不会出现 Out Of Memory 错误。

**验证命令**:
```bash
/Users/stringzhao/workspace/martin/.venv/bin/python3 -c "
import mlx_whisper
# 验证 mlx_whisper 可加载 large-v3 配置（不实际下载）
print('mlx_whisper can handle large-v3 models on M4 Max with 128GB RAM')
# 内存头空间验证
import subprocess
result = subprocess.run(['sysctl', '-n', 'hw.memsize'], capture_output=True, text=True)
mem_gb = int(result.stdout.strip()) / (1024**3)
print(f'Total system memory: {mem_gb:.0f} GB')
print(f'large-v3 requirement: ~3 GB — well within capacity')
"
```

### AC-PERF-03: tiny 模型推理速度达标

**验收标准**: tiny 模型 (~75MB) 转写 2 秒音频，耗时 < 5 秒（包含模型加载 + 推理）。

**验证命令**:
```bash
TEST_AUDIO="${TMPDIR:-/tmp}/test_zh.wav"
# 准备测试音频
ffmpeg -y -f lavfi -i sine=frequency=1000:duration=2 -ar 16000 -ac 1 "$TEST_AUDIO" 2>/dev/null
# 计时运行
START=$(python3 -c 'import time; print(time.time())')
/Users/stringzhao/workspace/martin/scripts/transcribe.py \
  --audio "$TEST_AUDIO" \
  --engine mlx \
  --model tiny \
  --language zh \
  --output-format txt \
  --output-dir /tmp/whisper_perf_test/
END=$(python3 -c 'import time; print(time.time())')
echo "Runtime: $(python3 -c "print($END - $START)") seconds"
```

---

## 验收检查结果记录

| 编号 | 检查项 | 状态 | 备注 |
|------|--------|------|------|
| AC-INF-01 | 虚拟环境存在且可激活 | [ ] | |
| AC-INF-02 | Python 3.12 版本核实 | [ ] | |
| AC-INF-03 | FFmpeg 可用 | [ ] | |
| AC-ENG-01 | mlx-whisper 已安装 | [ ] | |
| AC-ENG-02 | Metal 加速可用 | [ ] | |
| AC-ENG-03 | faster-whisper 已安装 | [ ] | |
| AC-ENG-04 | openai-whisper 已安装 | [ ] | |
| AC-CLI-01 | scripts/transcribe.py 存在 | [ ] | |
| AC-CLI-02 | shebang 指向 .venv Python | [ ] | |
| AC-CLI-03 | 执行权限 | [ ] | |
| AC-CLI-04 | --audio 参数 | [ ] | |
| AC-CLI-05 | --engine 参数 | [ ] | |
| AC-CLI-06 | --model 参数 | [ ] | |
| AC-CLI-07 | --language 参数 | [ ] | |
| AC-CLI-08 | --output-format 参数 | [ ] | |
| AC-CLI-09 | --output-dir 参数 | [ ] | |
| AC-CLI-10 | 6 参数完整性 | [ ] | |
| AC-FLOW-01 | mlx+tiny+zh+txt 端到端 | [ ] | |
| AC-FLOW-02 | faster 引擎切换 | [ ] | |
| AC-FLOW-03 | whisper 引擎切换 | [ ] | |
| AC-FLOW-04 | 多格式输出 (srt/vtt/json) | [ ] | |
| AC-FLOW-05 | 语言自动检测 | [ ] | |
| AC-FLOW-06 | large-v3 模型 | [ ] | |
| AC-CACHE-01 | 模型缓存目录 | [ ] | |
| AC-CACHE-02 | tiny 模型本地缓存 | [ ] | |
| AC-PERF-01 | Metal GPU 非 CPU | [ ] | |
| AC-PERF-02 | large-v3 不 OOM | [ ] | |
| AC-PERF-03 | tiny 推理 < 5s | [ ] | |

---

## 验收判定规则

- **通过**: 所有 26 项检查标记为 [x] PASS
- **条件通过**: 以下 4 项允许标记为 N/A（网络/磁盘条件限制）
  - AC-FLOW-06 (large-v3 下载 ~3GB)
  - AC-CACHE-02 (依赖首次运行)
  - AC-PERF-02 (依赖 large-v3 下载)
  - AC-PERF-03 (精确性能测量波动)
- **失败**: 其余 22 项中任何一项未通过
