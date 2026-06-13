#!/usr/bin/env python3
"""restaurant_data.json 质量校验工具

用法: python3 scripts/lint.py output/restaurant_data.json
退出码: 0=通过, 1=校验失败
"""

import json
import sys
import os


def lint(data_path):
    errors = []
    warnings = []

    # 读取
    try:
        with open(data_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f'❌ 无法读取 JSON: {e}')
        return 1

    # === recommendation ===
    rec = data.get('recommendation', {})
    if not rec.get('title'):
        errors.append('recommendation.title 缺失')
    if not rec.get('date'):
        errors.append('recommendation.date 缺失')
    if not rec.get('city'):
        warnings.append('recommendation.city 缺失')
    if not rec.get('cuisine'):
        warnings.append('recommendation.cuisine 缺失')

    # budget — 必须含 economy/standard/premium 三档
    bg = rec.get('budget', {})
    budget_keys = set(bg.keys())
    required_budget_keys = {'economy', 'standard', 'premium'}
    if not required_budget_keys.issubset(budget_keys):
        missing = required_budget_keys - budget_keys
        errors.append(f'budget 缺少必填字段: {sorted(missing)}，当前: {sorted(budget_keys)}')

    # === restaurants ===
    restaurants = data.get('restaurants', [])
    if not isinstance(restaurants, list):
        errors.append('restaurants 必须是数组')
        restaurants = []

    if not restaurants:
        errors.append('restaurants 为空')
    elif len(restaurants) < 5:
        warnings.append(f'restaurants 仅 {len(restaurants)} 家，建议 ≥ 5（推荐 8-10 家）')

    high_confidence_count = 0
    source_fields = ('dianping', 'amap', 'bangdan_rank', 'bangdan_score', 'bilibili', 'xhs_likes', 'weixin')

    for i, r in enumerate(restaurants):
        prefix = f'restaurants[{i}]'
        rname = r.get('name', '')
        if rname:
            prefix += f' ({rname})'

        # 必填字段
        if not r.get('name'):
            errors.append(f'restaurants[{i}] name 缺失')
        if not r.get('confidence'):
            errors.append(f'{prefix} confidence 缺失')
        if r.get('confidence') and r['confidence'] not in ('high', 'medium', 'low'):
            c = r['confidence']
            errors.append(f'{prefix} confidence="{c}" 非 high/medium/low')

        # 置信度计数
        if r.get('confidence') == 'high':
            high_confidence_count += 1

        # scoring 数据源数量
        scoring = r.get('scoring', {})
        if not scoring:
            warnings.append(f'{prefix} scoring 缺失')
        else:
            source_count = 0
            if scoring.get('dianping'):
                source_count += 1
            if scoring.get('amap'):
                source_count += 1
            if scoring.get('bangdan_rank') or scoring.get('bangdan_score'):
                source_count += 1
            bilibili_data = scoring.get('bilibili')
            if isinstance(bilibili_data, dict) and scoring.get('bilibili'):
                source_count += 1
            if scoring.get('xhs_likes'):
                source_count += 1
            if scoring.get('weixin'):
                source_count += 1

            if source_count < 2:
                warnings.append(f'{prefix} scoring 仅 {source_count} 个数据源，建议 ≥ 2')

        # 链接一致性检查
        links = r.get('links') or {}
        scoring = r.get('scoring') or {}

        # 有 dianping 评分必须含 dianping 链接
        if scoring.get('dianping') and not links.get('dianping'):
            warnings.append(f'{prefix} scoring 含 dianping 评分但 links.dianping 缺失')

        # 有 bilibili.bvid 必须含 bilibili 链接
        bilibili_data = scoring.get('bilibili')
        if isinstance(bilibili_data, dict) and bilibili_data.get('bvid'):
            if not links.get('bilibili'):
                warnings.append(f'{prefix} scoring.bilibili.bvid 存在但 links.bilibili 缺失')

        # must_try
        if not r.get('must_try') or (isinstance(r.get('must_try'), list) and len(r.get('must_try', [])) == 0):
            warnings.append(f'{prefix} must_try 缺失或为空')

    # 高置信度数量检查
    if high_confidence_count < 3:
        errors.append(f'高置信度餐厅仅 {high_confidence_count} 家，要求 ≥ 3')

    # === sources ===
    if not data.get('sources'):
        warnings.append('sources 缺失')

    # === 输出 ===
    print(f'📋 校验: {data_path}')
    print(f'   推荐城市: {rec.get("city", "-")} | 菜系: {rec.get("cuisine", "-")} | 餐厅: {len(restaurants)} 家')
    print(f'   高置信度: {high_confidence_count} 家')

    if errors:
        print(f'\n❌ {len(errors)} 个错误:')
        for e in errors:
            print(f'   ❌ {e}')

    if warnings:
        print(f'\n⚠️  {len(warnings)} 个警告:')
        for w in warnings:
            print(f'   ⚠️  {w}')

    if not errors:
        print(f'\n✅ 校验通过' + (f' ({len(warnings)} 个警告)' if warnings else ''))
        return 0
    else:
        print(f'\n❌ 校验失败，请修复后重试')
        return 1


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('用法: python3 scripts/lint.py <restaurant_data.json>')
        sys.exit(1)
    sys.exit(lint(sys.argv[1]))
