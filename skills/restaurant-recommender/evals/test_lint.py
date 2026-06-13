#!/usr/bin/env python3
"""验收测试：restaurant-recommender lint.py 行为验证

用法: python3 evals/test_lint.py
退出码: 0=全部通过, 1=存在失败用例

设计契约来源: SKILL.md 关键行为契约 + restaurant-schema.md
"""

import subprocess
import sys
import os
import json

# 脚本路径 — 指向 restaurant-recommender 的 lint.py
EVALS_DIR = os.path.dirname(os.path.abspath(__file__))
SKILL_ROOT = os.path.dirname(EVALS_DIR)
LINT_SCRIPT = os.path.join(SKILL_ROOT, 'scripts', 'lint.py')

# 测试数据文件
VALID_DATA = os.path.join(EVALS_DIR, 'test_data_valid.json')
INVALID_DATA = os.path.join(EVALS_DIR, 'test_data_invalid.json')
MISSING_FILE = os.path.join(EVALS_DIR, 'nonexistent.json')

results = {'passed': 0, 'failed': 0, 'skipped': 0}


def run_lint(data_path):
    """运行 lint.py 并返回 (exit_code, stdout)"""
    proc = subprocess.run(
        [sys.executable, LINT_SCRIPT, data_path],
        capture_output=True, text=True, timeout=10
    )
    return proc.returncode, proc.stdout


def check(name, condition, detail=''):
    """断言工具"""
    if condition:
        results['passed'] += 1
        print(f'  ✅ {name}')
    else:
        results['failed'] += 1
        print(f'  ❌ {name}' + (f' — {detail}' if detail else ''))


def test_valid_data():
    """有效数据应通过 lint（0 errors）"""
    print('\n📋 测试: 有效数据通过 lint')
    if not os.path.exists(VALID_DATA):
        print('  ⏭️  跳过 — test_data_valid.json 不存在')
        results['skipped'] += 1
        return

    exit_code, stdout = run_lint(VALID_DATA)
    check('退出码 = 0', exit_code == 0, f'实际退出码: {exit_code}')
    check('输出包含「校验通过」', '校验通过' in stdout)
    check('输出不包含 error 计数「0 个错误」',
          '0 个错误' in stdout or '✅' in stdout and '❌' not in stdout.split('✅')[0] if '✅' in stdout else True)
    check('检测到 6 家餐厅',
          '6 家' in stdout or '餐厅: 6' in stdout, f'实际输出: {stdout[-300:]}')


def test_invalid_data():
    """无效数据应检测出 errors"""
    print('\n📋 测试: 无效数据检测错误')
    if not os.path.exists(INVALID_DATA):
        print('  ⏭️  跳过 — test_data_invalid.json 不存在')
        results['skipped'] += 1
        return

    exit_code, stdout = run_lint(INVALID_DATA)

    check('退出码 = 1（校验失败）', exit_code == 1, f'实际退出码: {exit_code}')
    check('输出包含「❌」错误标记', '❌' in stdout)

    # 根据设计契约，以下错误应被 lint.py 检出
    expected_errors = {
        'title 缺失': ['title', '缺失'],
        'budget 缺失': ['budget', '缺失'],
        'confidence 缺失': ['confidence', '缺失'],
        'confidence 非法值': ['confidence', 'very_high'],
        '餐厅数不足 5 家': ['3 家'],
        '高置信度不足 3 家': ['high'],
    }

    for label, keywords in expected_errors.items():
        matched = all(kw.lower() in stdout.lower() for kw in keywords)
        check(f'检出错误: {label}', matched,
              f'关键词 {keywords} 未在输出中找到' if not matched else '')


def test_missing_file():
    """不存在的文件应报错"""
    print('\n📋 测试: 文件不存在时的行为')
    exit_code, stdout = run_lint(MISSING_FILE)
    # 不存在的文件应导致非零退出码
    check('不存在的文件退出码 != 0', exit_code != 0, f'实际退出码: {exit_code}')
    check('输出包含错误信息',
          any(kw in stdout.lower() for kw in ['不存在', 'not found', '无法', 'no such file', 'error']),
          f'实际输出: {stdout[:200]}')


def test_lint_script_exists():
    """验证 lint.py 脚本存在且可执行"""
    print('\n📋 测试: lint.py 脚本可发现')
    exists = os.path.exists(LINT_SCRIPT)
    check('scripts/lint.py 存在', exists)
    if not exists:
        print('  ⚠️  lint.py 尚未创建 — 部分测试将跳过（这是蓝队的实现任务）')
    return exists


if __name__ == '__main__':
    print('=' * 60)
    print('restaurant-recommender lint.py 验收测试')
    print('=' * 60)

    script_exists = test_lint_script_exists()

    if script_exists:
        test_valid_data()
        test_invalid_data()
        test_missing_file()
    else:
        print('\n  ⏭️  lint.py 尚未创建，跳过所有依赖脚本的测试')
        results['skipped'] += 3

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
