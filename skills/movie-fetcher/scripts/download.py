"""推送 magnet 到下载客户端 + 轮询完成。"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Callable

from . import nas, paths


@dataclass
class DownloadResult:
    hash_: str
    task: nas.Task | None
    completed: bool
    elapsed_s: float


def push_magnet(cfg: dict[str, Any], magnet: str, category: str = "movie") -> tuple[Any, str]:
    """推送 magnet。返回 (client, hash)。

    category 对应 config paths.categories 的 key，决定下载到哪个子目录。
    例：category="tv" → save_path="/m/剧集"
    """
    client = nas.build_client(cfg)
    nas_internal = cfg["paths"]["nas_internal"]
    if not nas_internal:
        raise RuntimeError("paths.nas_internal 未配置，请先运行 setup")
    categories = cfg["paths"].get("categories", {})
    save_path = paths.nas_save_path(nas_internal, categories, category)
    hash_ = client.add_magnet(magnet, save_path)
    return client, hash_


def wait_for_completion(
    client: Any,
    hash_: str,
    poll_interval: int = 30,
    timeout: int = 86400,
    on_tick: Callable[[nas.Task], None] | None = None,
) -> DownloadResult:
    start = time.time()
    while True:
        info = client.info(hash_)
        if on_tick and info:
            on_tick(info)
        if info and info.progress >= 0.999:
            return DownloadResult(hash_=hash_, task=info, completed=True,
                                  elapsed_s=time.time() - start)
        if time.time() - start > timeout:
            return DownloadResult(hash_=hash_, task=info, completed=False,
                                  elapsed_s=time.time() - start)
        time.sleep(poll_interval)


# qBit "未拿到 metadata" 期间的状态
_METADATA_PENDING_STATES = {"metaDL", "forcedMetaDL", "checkingResumeData", "unknown", ""}


def wait_for_metadata(
    client: Any,
    hash_: str,
    poll_interval: int = 3,
    timeout: int = 600,
    on_tick: Callable[[nas.Task], None] | None = None,
) -> nas.Task | None:
    """等到 qBit 拉到 metadata（state ≠ metaDL 且 name 不空）。

    拿到 metadata 后任务进入 downloading/queued/paused 等，此时 task.name 是真实文件名，
    本地挂载点上 qBit 会创建对应文件/目录占位，subliminal 已经可以按文件名查字幕。
    """
    start = time.time()
    while True:
        info = client.info(hash_)
        if on_tick and info:
            on_tick(info)
        if info and info.name and info.state not in _METADATA_PENDING_STATES:
            return info
        if time.time() - start > timeout:
            return info
        time.sleep(poll_interval)
