#!/usr/bin/env python3
"""验收测试：restaurant-recommender server.js 行为验证

用法: python3 evals/test_server.py
退出码: 0=全部通过, 1=存在失败用例

设计契约:
  - /health 端点返回 200 + JSON (status: ok)
  - / 路由返回 HTML (200 + text/html Content-Type)
  - 服务器可优雅退出 (SIGINT/SIGTERM)
  - 默认端口通过 PORT 环境变量配置
"""

import subprocess
import sys
import os
import json
import time
import signal
import urllib.request
import urllib.error
import socket

# 脚本路径 — 指向 restaurant-recommender 的 server.js
EVALS_DIR = os.path.dirname(os.path.abspath(__file__))
SKILL_ROOT = os.path.dirname(EVALS_DIR)
SERVER_SCRIPT = os.path.join(SKILL_ROOT, 'scripts', 'server.js')

# 使用随机高位端口避免冲突
TEST_PORT = 19876

results = {'passed': 0, 'failed': 0, 'skipped': 0}


def check(name, condition, detail=''):
    """断言工具"""
    if condition:
        results['passed'] += 1
        print(f'  ✅ {name}')
    else:
        results['failed'] += 1
        print(f'  ❌ {name}' + (f' — {detail}' if detail else ''))


def port_in_use(port):
    """检查端口是否被占用"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(('127.0.0.1', port))
            return False
        except OSError:
            return True


def wait_for_server(url, timeout=5.0):
    """轮询等待服务器就绪"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            resp = urllib.request.urlopen(url, timeout=1.0)
            return resp
        except (urllib.error.URLError, OSError):
            time.sleep(0.2)
    return None


def test_server_script_exists():
    """验证 server.js 脚本存在"""
    print('\n📋 测试: server.js 脚本可发现')
    exists = os.path.exists(SERVER_SCRIPT)
    check('scripts/server.js 存在', exists)
    if not exists:
        print('  ⚠️  server.js 尚未创建 — 后续测试将跳过')
    return exists


def test_health_endpoint():
    """/health 端点返回 200 + JSON"""
    print(f'\n📋 测试: /health 端点 (端口 {TEST_PORT})')

    # 确保端口空闲
    if port_in_use(TEST_PORT):
        print(f'  ⚠️  端口 {TEST_PORT} 被占用，跳过')
        results['skipped'] += 3  # 跳过3个检查
        return None

    # 启动服务器
    env = os.environ.copy()
    env['PORT'] = str(TEST_PORT)
    proc = subprocess.Popen(
        ['node', SERVER_SCRIPT],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    try:
        # 等待服务器就绪
        health_url = f'http://127.0.0.1:{TEST_PORT}/health'
        resp = wait_for_server(health_url, timeout=5.0)
        check('服务器在 5s 内就绪', resp is not None,
              '无法连接 health 端点')

        if resp is None:
            # 尝试读取服务器输出诊断
            try:
                proc.poll()
                out, err = proc.communicate(timeout=1)
                print(f'    服务器 stdout: {out[-200:]}')
                print(f'    服务器 stderr: {err[-200:]}')
            except subprocess.TimeoutExpired:
                pass
            return None

        # 检查响应
        status = resp.status
        body = json.loads(resp.read().decode('utf-8'))

        check('HTTP 状态码 200', status == 200, f'实际: {status}')
        check('Content-Type 为 application/json',
              'application/json' in resp.headers.get('Content-Type', ''),
              f'实际: {resp.headers.get("Content-Type", "N/A")}')
        check('JSON body.status = ok',
              body.get('status') == 'ok',
              f'实际 body: {json.dumps(body, ensure_ascii=False)}')

        return proc

    except Exception as e:
        check('health 端点异常', False, str(e))
        return None


def test_root_route(server_proc):
    """/ 路由返回 HTML"""
    print('\n📋 测试: / 根路由返回 HTML')
    if server_proc is None:
        print('  ⏭️  跳过 — 服务器未启动')
        results['skipped'] += 3
        return

    try:
        url = f'http://127.0.0.1:{TEST_PORT}/'
        req = urllib.request.Request(url)
        resp = urllib.request.urlopen(req, timeout=5.0)

        status = resp.status
        content_type = resp.headers.get('Content-Type', '')
        body = resp.read().decode('utf-8')

        check('HTTP 状态码 200', status == 200, f'实际: {status}')
        check('Content-Type 为 text/html',
              'text/html' in content_type,
              f'实际: {content_type}')
        check('响应体包含 <!DOCTYPE html>',
              '<!DOCTYPE html>' in body,
              f'响应体前100字符: {body[:100]}')
        check('响应体包含 </html>',
              '</html>' in body)

    except Exception as e:
        check('根路由请求异常', False, str(e))


def test_graceful_shutdown(server_proc):
    """服务器可优雅退出"""
    print('\n📋 测试: 优雅退出 (SIGTERM)')
    if server_proc is None:
        print('  ⏭️  跳过 — 服务器未启动')
        results['skipped'] += 1
        return

    # 发送 SIGTERM
    server_proc.terminate()
    try:
        server_proc.wait(timeout=5.0)
        exit_code = server_proc.returncode
        check('SIGTERM 后进程退出码正常',
              exit_code is not None and exit_code >= 0,
              f'实际退出码: {exit_code}')
    except subprocess.TimeoutExpired:
        server_proc.kill()
        server_proc.wait()
        check('SIGTERM 超时需 kill',
              False, '进程需 kill 才能终止')

    # 验证端口释放
    time.sleep(0.5)
    port_freed = not port_in_use(TEST_PORT)
    check('退出后端口释放', port_freed, f'端口 {TEST_PORT} 仍占用')


if __name__ == '__main__':
    print('=' * 60)
    print('restaurant-recommender server.js 验收测试')
    print('=' * 60)

    # 检查 Node.js 可用
    try:
        node_check = subprocess.run(
            ['node', '--version'], capture_output=True, text=True, timeout=5
        )
        node_version = node_check.stdout.strip()
        print(f'  Node.js 版本: {node_version}')
    except (FileNotFoundError, subprocess.TimeoutExpired):
        print('  ❌ Node.js 不可用 — 所有测试跳过')
        print('\n❌ 请安装 Node.js 后重试')
        sys.exit(1)

    script_exists = test_server_script_exists()

    if script_exists:
        server_proc = test_health_endpoint()

        if server_proc:
            test_root_route(server_proc)
            test_graceful_shutdown(server_proc)
        else:
            # 清理可能残留的进程
            test_graceful_shutdown(None)
    else:
        print('\n  ⏭️  server.js 尚未创建，跳过所有依赖脚本的测试')
        results['skipped'] += 10

    # 汇总
    print('\n' + '=' * 60)
    total = results['passed'] + results['failed'] + results['skipped']
    print(f'结果: {results["passed"]} 通过 / {results["failed"]} 失败 / {results["skipped"]} 跳过 (共 {total})')
    print('=' * 60)

    if results['failed'] > 0:
        print('\n❌ 存在失败用例 — 蓝队请修复后重新验证')
        sys.exit(1)
    else:
        print('\n✅ 所有用例通过')
        sys.exit(0)
