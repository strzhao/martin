#!/usr/bin/env python3
"""验收测试：restaurant-recommender inject.py 行为验证

用法: python3 evals/test_inject.py
退出码: 0=全部通过, 1=存在失败用例

设计契约: inject.py 读取 JSON + HTML 模板，替换占位符，输出完整 HTML。
"""

import subprocess
import sys
import os
import json
import tempfile

# 脚本路径 — 指向 restaurant-recommender 的 inject.py
EVALS_DIR = os.path.dirname(os.path.abspath(__file__))
SKILL_ROOT = os.path.dirname(EVALS_DIR)
INJECT_SCRIPT = os.path.join(SKILL_ROOT, 'scripts', 'inject.py')

# 测试数据
VALID_DATA = os.path.join(EVALS_DIR, 'test_data_valid.json')

# 占位符名称（应被替换掉）
PLACEHOLDER = '__RESTAURANT_DATA__'

results = {'passed': 0, 'failed': 0, 'skipped': 0}


def check(name, condition, detail=''):
    """断言工具"""
    if condition:
        results['passed'] += 1
        print(f'  ✅ {name}')
    else:
        results['failed'] += 1
        print(f'  ❌ {name}' + (f' — {detail}' if detail else ''))


def test_inject_script_exists():
    """验证 inject.py 脚本存在"""
    print('\n📋 测试: inject.py 脚本可发现')
    exists = os.path.exists(INJECT_SCRIPT)
    check('scripts/inject.py 存在', exists)
    if not exists:
        print('  ⚠️  inject.py 尚未创建 — 后续测试将跳过')
    return exists


def test_inject_valid_data():
    """输入有效的 restaurant_data.json → 输出 restaurant.html"""
    print('\n📋 测试: 有效数据注入生成 HTML')
    if not os.path.exists(VALID_DATA):
        print('  ⏭️  跳过 — test_data_valid.json 不存在')
        results['skipped'] += 1
        return None

    proc = subprocess.run(
        [sys.executable, INJECT_SCRIPT, VALID_DATA],
        capture_output=True, text=True, timeout=10
    )

    exit_ok = proc.returncode == 0
    check('注入命令退出码 = 0', exit_ok,
          f'实际退出码: {proc.returncode}, stderr: {proc.stderr[:200]}')

    # 查找输出文件路径
    stdout = proc.stdout
    # inject.py 会打印 "已生成: <output_path>"
    output_path = None
    for line in stdout.split('\n'):
        if '已生成' in line or 'Generated' in line.lower():
            # 尝试提取路径
            import re
            match = re.search(r'[/\w.-]+\.html', line)
            if match:
                output_path = match.group(0)
                if not os.path.isabs(output_path):
                    output_path = os.path.join(SKILL_ROOT, 'output',
                                                os.path.basename(output_path))

    # 回退：猜测路径
    if output_path is None:
        output_path = os.path.join(SKILL_ROOT, 'output', 'restaurant.html')

    check('输出文件存在', os.path.exists(output_path),
          f'预期路径: {output_path}')

    if not os.path.exists(output_path):
        print(f'  ⚠️  inject.py 输出: {stdout[:300]}')
        return None

    return output_path


def test_html_is_valid(output_path):
    """输出文件是有效的 HTML"""
    print('\n📋 测试: 输出文件是有效 HTML')
    if not output_path or not os.path.exists(output_path):
        print('  ⏭️  跳过 — 输出文件不存在')
        results['skipped'] += 1
        return

    with open(output_path, 'r', encoding='utf-8') as f:
        content = f.read()

    check('包含 <!DOCTYPE html>', '<!DOCTYPE html>' in content)
    check('包含 <html> 标签', '<html' in content)
    check('包含 </html> 闭合标签', '</html>' in content)
    check('文件非空', len(content) > 100,
          f'实际大小: {len(content)} 字节')


def test_placeholder_replaced(output_path):
    """占位符已被替换为实际数据"""
    print('\n📋 测试: 占位符替换完成')
    if not output_path or not os.path.exists(output_path):
        print('  ⏭️  跳过 — 输出文件不存在')
        results['skipped'] += 1
        return

    with open(output_path, 'r', encoding='utf-8') as f:
        content = f.read()

    check(f'占位符 {PLACEHOLDER} 已替换',
          PLACEHOLDER not in content,
          f'占位符仍存在于输出中')

    # 验证 JSON 数据确实被注入了
    with open(VALID_DATA, 'r', encoding='utf-8') as f:
        valid_data = json.load(f)

    # 关键字段应出现在 HTML 中（作为 JSON 字符串嵌入）
    first_restaurant = valid_data['restaurants'][0]['name']
    check(f'首餐厅名称「{first_restaurant}」存在于 HTML',
          first_restaurant in content,
          f'未找到餐厅名称')


def test_inject_missing_input():
    """缺少输入参数时应提示用法"""
    print('\n📋 测试: 缺少参数时提示用法')
    proc = subprocess.run(
        [sys.executable, INJECT_SCRIPT],
        capture_output=True, text=True, timeout=10
    )
    # 预期：退出码非零，且提示用法
    check('缺少参数退出码 != 0', proc.returncode != 0,
          f'实际退出码: {proc.returncode}')
    check('输出包含用法提示',
          any(kw in (proc.stdout + proc.stderr).lower()
              for kw in ['用法', 'usage', 'inject', 'json']),
          f'实际输出: {(proc.stdout + proc.stderr)[:200]}')


if __name__ == '__main__':
    print('=' * 60)
    print('restaurant-recommender inject.py 验收测试')
    print('=' * 60)

    script_exists = test_inject_script_exists()

    if script_exists:
        output_path = test_inject_valid_data()
        if output_path:
            test_html_is_valid(output_path)
            test_placeholder_replaced(output_path)
        test_inject_missing_input()
    else:
        print('\n  ⏭️  inject.py 尚未创建，跳过所有依赖脚本的测试')
        results['skipped'] += 4

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
