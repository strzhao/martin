"""NAS 内部路径 ↔ 本地 SMB 挂载路径互转。"""

from __future__ import annotations

from pathlib import PurePosixPath


def to_local(nas_path: str, nas_internal: str, local_mount: str) -> str:
    """NAS 视角下的绝对路径转本地挂载路径。

    例：
        to_local("/volume1/迅雷下载/电影/Lincoln/",
                 "/volume1/迅雷下载/电影",
                 "/Volumes/x/迅雷下载/电影")
        -> "/Volumes/x/迅雷下载/电影/Lincoln/"
    """
    nas_p = PurePosixPath(nas_path)
    base = PurePosixPath(nas_internal)
    try:
        rel = nas_p.relative_to(base)
    except ValueError:
        return nas_path  # 不在映射范围内则原样返回
    return str(PurePosixPath(local_mount) / rel)


def to_nas(local_path: str, nas_internal: str, local_mount: str) -> str:
    local_p = PurePosixPath(local_path)
    base = PurePosixPath(local_mount)
    try:
        rel = local_p.relative_to(base)
    except ValueError:
        return local_path
    return str(PurePosixPath(nas_internal) / rel)


def nas_save_path(nas_internal: str, categories: dict[str, str], category: str) -> str:
    """构建 qBit 视角的分类下载目录。

    例：nas_save_path("/m", {"movie":"电影","tv":"剧集"}, "tv") → "/m/剧集"
    未匹配的 category 返回 nas_internal 本身。
    """
    subdir = categories.get(category, "")
    return f"{nas_internal.rstrip('/')}/{subdir}" if subdir else nas_internal


def local_category_dir(local_mount: str, categories: dict[str, str], category: str) -> str:
    """构建本机挂载路径下的分类目录。

    例：local_category_dir("/Volumes/迅雷下载", {"tv":"剧集"}, "tv") → "/Volumes/迅雷下载/剧集"
    """
    subdir = categories.get(category, "")
    return f"{local_mount.rstrip('/')}/{subdir}" if subdir else local_mount
