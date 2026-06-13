# B站探店视频 ASR 分析策略

## 核心理念

B站自带字幕是 AI 生成的，会丢失语气、停顿、重音等关键信号。真正可靠的方案是**下载视频 → 提取音轨 → 本地 whisper ASR 转写 → AI 分析**。

## 工具链

| 工具 | 用途 | 路径 |
|------|------|------|
| yt-dlp | 下载 B站视频 | `/opt/homebrew/bin/yt-dlp` |
| ffmpeg | 提取音轨为 16kHz wav | `/opt/homebrew/bin/ffmpeg` |
| mlx-whisper | ASR 转写（M4 Max Metal 加速） | `.venv/bin/activate` |
| 模型 | large-v3-turbo（精度/速度平衡） | `mlx-community/whisper-large-v3-turbo` |

## 完整管线

```bash
# 1. 搜索 + 筛选
opencli bilibili search "<城市> <菜系> 探店" --window background
opencli bilibili video "<bvid>" --window background

# 2. 下载视频（低画质+音频，节省带宽）
yt-dlp -f "best[height<=480]+bestaudio/best[height<=480]" \
  -o "/tmp/bilibili_%(id)s.%(ext)s" \
  "https://www.bilibili.com/video/<bvid>"

# 3. 提取音轨
ffmpeg -i "/tmp/bilibili_<bvid>.mp4" \
  -ac 1 -ar 16000 -sample_fmt s16 \
  "/tmp/bilibili_<bvid>.wav" -y

# 4. ASR 转写
source /Users/stringzhao/workspace/martin/.venv/bin/activate
python3 -c "
import mlx_whisper, json
result = mlx_whisper.transcribe(
    '/tmp/bilibili_<bvid>.wav',
    path_or_hf_repo='mlx-community/whisper-large-v3-turbo',
    language='zh'
)
print(json.dumps({
    'text': result['text'],
    'segments': [{'start': s['start'], 'end': s['end'], 'text': s['text']} for s in result['segments']]
}, ensure_ascii=False, indent=2))
"

# 5. 清理临时文件
rm /tmp/bilibili_<bvid>.mp4 /tmp/bilibili_<bvid>.wav
```

## AI 分析要点

### 语气信号（只有真人语音转写才能捕捉）

| 信号类型 | 转写特征 | 可信度 |
|----------|----------|--------|
| 真情实感好评 | 语气词、「真的」「这个」「我跟你说」、重复强调 | 高 |
| 无功无过 | 「还行」「还可以」「就那样」+ 快速切换话题 | 弱 |
| 犹豫/敷衍 | 「嗯…」「怎么说呢…」、长停顿 | 差评软信号 |
| 商业推广 | 「必点」「绝绝子」「姐妹们冲」「赶紧收藏」 | 可信度打折 |

### 关键信息提取

- 具体餐厅名和菜品名
- 价格信息（「这一顿花了 130」「人均 80」）
- 对比评价（「比 XX 店好吃」「跟总店没法比」）
- 回头意愿（「下次还会来」「不会再来第二次」）

### 视频筛选优先级

1. 专业厨子探店（如 真探唐仁杰）— 技术角度评价，诚实客观
2. 本地美食博主日常 vlog — 真实消费，非商业合作
3. 播放量 > 50K 的大 UP — 评价更客观
4. **排除**：商业合作视频（标题含「广告」「合作」）
5. **排除**：纯画面+BGM 无解说视频

### 耗时估算

| 视频时长 | 下载+提取 | ASR 转写 | 总计 |
|----------|----------|----------|------|
| 5 min | ~10s | ~2 min | ~2.5 min |
| 10 min | ~15s | ~4 min | ~4.5 min |
| 20 min | ~25s | ~8 min | ~8.5 min |

建议每个任务转写 3-5 个精选视频，总耗时约 10-20 分钟。
