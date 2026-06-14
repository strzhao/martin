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

    例：nas_save_path("/m", {"movie":"/m","tv":"/d"}, "tv") → "/d"
    value 为绝对路径时直接使用（支持独立挂载点），相对路径则拼到 nas_internal 后。
    """
    subdir = categories.get(category, "")
    if not subdir:
        return nas_internal
    if subdir.startswith("/"):
        return subdir  # 绝对 NAS 路径（独立挂载点）
    return f"{nas_internal.rstrip('/')}/{subdir}"


def local_category_dir(local_mount: str, categories: dict[str, str],
                       category: str, local_paths: dict[str, str] | None = None) -> str:
    """构建本机挂载路径下的分类目录。

    local_paths 为按分类 key 覆盖的本地路径（用于独立挂载点）。
    例：local_category_dir("/Volumes/迅雷下载", {"movie":"/m","tv":"/d"}, "tv",
                          local_paths={"tv":"/Volumes/迅雷下载/电视剧"})
        → "/Volumes/迅雷下载/电视剧"
    """
    if local_paths and category in local_paths:
        return local_paths[category]
    subdir = categories.get(category, "")
    # 绝对路径且无 local_paths 覆盖 → 返回 local_mount 本身（/m 的 SMB 挂载点）
    if subdir.startswith("/"):
        return local_mount
    return f"{local_mount.rstrip('/')}/{subdir}" if subdir else local_mount
