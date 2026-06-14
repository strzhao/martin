"""NAS 上的下载客户端封装。

支持 qBittorrent 与 Transmission，提供统一接口：
- probe(host): 探测可用客户端，返回 (kind, url, [hint])
- Client.add_magnet(magnet, save_path) -> hash
- Client.list() -> list[Task]
- Client.info(hash_) -> Task | None
"""

from __future__ import annotations

import ipaddress
import os
import socket
from dataclasses import dataclass
from typing import Any, Iterable


def _bypass_proxy_for(host: str) -> None:
    """局域网 IP 自动加入 NO_PROXY，避免 requests/urllib 走全局 socks/http 代理。"""
    try:
        ip = ipaddress.ip_address(host)
        if not ip.is_private:
            return
    except ValueError:
        # 域名形式不动
        return
    cur = os.environ.get("NO_PROXY", "") or os.environ.get("no_proxy", "")
    parts = [p.strip() for p in cur.split(",") if p.strip()]
    if host not in parts:
        parts.append(host)
        os.environ["NO_PROXY"] = ",".join(parts)
        os.environ["no_proxy"] = ",".join(parts)


@dataclass
class Task:
    hash_: str
    name: str
    progress: float  # 0.0 ~ 1.0
    state: str
    save_path: str
    size: int


# 端口候选：qBittorrent 默认 8080；Transmission 默认 9091；
# 绿联 UGOS 主面板占 8080，所以这里把 qBit 常见替代端口都加上。
QBIT_PORTS = [8080, 8081, 8090, 9080, 10095]
TRANSMISSION_PORTS = [9091, 9092]


def _tcp_alive(host: str, port: int, timeout: float = 1.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def probe(host: str) -> list[tuple[str, int]]:
    """快速端口存活探测，返回 [(kind, port), ...]。"""
    hits: list[tuple[str, int]] = []
    for p in QBIT_PORTS:
        if _tcp_alive(host, p):
            hits.append(("qbittorrent", p))
    for p in TRANSMISSION_PORTS:
        if _tcp_alive(host, p):
            hits.append(("transmission", p))
    return hits


def try_qbit(url: str, user: str, password: str) -> tuple[bool, str]:
    """尝试登录 qBit。返回 (ok, message)。"""
    try:
        import qbittorrentapi  # type: ignore
        from urllib.parse import urlparse

        h = urlparse(url).hostname
        if h:
            _bypass_proxy_for(h)
        client = qbittorrentapi.Client(host=url, username=user, password=password,
                                       VERIFY_WEBUI_CERTIFICATE=False, REQUESTS_ARGS={"timeout": 5})
        client.auth_log_in()
        ver = client.app.version
        client.auth_log_out()
        return True, f"qBittorrent {ver}"
    except Exception as e:  # noqa: BLE001
        return False, f"qBit 握手失败：{e}"


def try_transmission(host: str, port: int, user: str, password: str) -> tuple[bool, str]:
    try:
        from transmission_rpc import Client  # type: ignore

        _bypass_proxy_for(host)
        c = Client(host=host, port=port, username=user or None, password=password or None, timeout=5)
        ver = c.get_session().version
        return True, f"Transmission {ver}"
    except Exception as e:  # noqa: BLE001
        return False, f"Transmission 握手失败：{e}"


class QbitClient:
    def __init__(self, url: str, user: str, password: str) -> None:
        import qbittorrentapi  # type: ignore
        from urllib.parse import urlparse

        h = urlparse(url).hostname
        if h:
            _bypass_proxy_for(h)
        self._c = qbittorrentapi.Client(host=url, username=user, password=password,
                                        VERIFY_WEBUI_CERTIFICATE=False,
                                        REQUESTS_ARGS={"timeout": 10})
        self._c.auth_log_in()

    def add_magnet(self, magnet: str, save_path: str, category: str = "movies") -> str:
        before = {t.hash for t in self._c.torrents_info()}
        self._c.torrents_add(urls=magnet, save_path=save_path, category=category)
        # qBit add 不直接返回 hash；用差集找新加入的
        import time

        for _ in range(20):
            after = self._c.torrents_info()
            new = [t for t in after if t.hash not in before]
            if new:
                return new[0].hash
            time.sleep(0.25)
        # 兜底：解析 magnet 取 btih
        return _magnet_hash(magnet) or ""

    def info(self, hash_: str) -> Task | None:
        items = self._c.torrents_info(torrent_hashes=hash_)
        if not items:
            return None
        t = items[0]
        return Task(hash_=t.hash, name=t.name, progress=float(t.progress),
                    state=str(t.state), save_path=str(t.save_path), size=int(t.size))

    def list(self) -> list[Task]:
        return [Task(hash_=t.hash, name=t.name, progress=float(t.progress),
                     state=str(t.state), save_path=str(t.save_path), size=int(t.size))
                for t in self._c.torrents_info()]


class TransmissionClient:
    def __init__(self, host: str, port: int, user: str, password: str) -> None:
        from transmission_rpc import Client  # type: ignore

        _bypass_proxy_for(host)
        self._c = Client(host=host, port=port, username=user or None, password=password or None, timeout=10)

    def add_magnet(self, magnet: str, save_path: str, category: str = "movies") -> str:
        torrent = self._c.add_torrent(magnet, download_dir=save_path)
        return torrent.hashString

    def info(self, hash_: str) -> Task | None:
        try:
            t = self._c.get_torrent(hash_)
        except Exception:  # noqa: BLE001
            return None
        return Task(hash_=t.hashString, name=t.name, progress=t.progress / 100.0,
                    state=t.status, save_path=str(t.download_dir), size=int(t.total_size))

    def list(self) -> list[Task]:
        out = []
        for t in self._c.get_torrents():
            out.append(Task(hash_=t.hashString, name=t.name, progress=t.progress / 100.0,
                            state=t.status, save_path=str(t.download_dir), size=int(t.total_size)))
        return out


def build_client(cfg: dict[str, Any]):
    kind = cfg["client"]["kind"]
    if kind == "qbittorrent":
        return QbitClient(cfg["client"]["url"], cfg["client"]["user"], cfg["client"]["password"])
    if kind == "transmission":
        # 从 url 解析 host:port
        from urllib.parse import urlparse

        u = urlparse(cfg["client"]["url"])
        port = u.port or 9091
        return TransmissionClient(u.hostname or cfg["nas"]["host"], port,
                                  cfg["client"]["user"], cfg["client"]["password"])
    raise ValueError(f"未知 client.kind: {kind}")


def _magnet_hash(magnet: str) -> str | None:
    import re

    m = re.search(r"xt=urn:btih:([a-fA-F0-9]{40}|[A-Z2-7]{32})", magnet)
    return m.group(1).lower() if m else None
