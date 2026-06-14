# movie-fetcher

Hermes Agent skill：一句话从电影名到 NAS 上下好 + 字幕配齐。

## 架构

```
用户 → Hermes LLM → SKILL.md → cli.py
                                  ├── search.py     (YTS / apibay / btdig)
                                  ├── nas.py        (qBit / Transmission)
                                  ├── download.py
                                  ├── subtitle.py   (subliminal + whisper)
                                  └── paths.py
```

详细命令见 [SKILL.md](./SKILL.md)。

## 开发

```bash
PYTHON=/Users/stringzhao/workspace/martin/.venv/bin/python

# 单测：模块导入
$PYTHON -c "from scripts import cli, search, nas, subtitle, download, paths, config; print('ok')"

# CLI 帮助
$PYTHON -m scripts.cli --help

# 不依赖 NAS 的子命令
$PYTHON -m scripts.cli search "Lincoln 2012" --limit 5
$PYTHON -m scripts.cli scan-missing
```

## 安全

- `config.yaml` 已加入 `.gitignore`
- `config.py` 启动强制 `chmod 0600`，组/其他权限位会被剥掉

## v2 待办

- macOS Keychain 集成（替换明文密码）
- 中文字幕站直连（SubHD / Zimuku）—— 需评估反爬难度
- 剧集追更（季 + 集自动匹配）
