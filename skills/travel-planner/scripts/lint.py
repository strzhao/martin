#!/usr/bin/env python3
"""trip_data.json 质量校验工具

用法: python3 scripts/lint.py output/trip_data.json
退出码: 0=通过, 1=校验失败
"""

import json
import sys
import os
import math

# 近似距离常量（北纬30度附近）
_M_PER_DEG_LNG = 85000
_M_PER_DEG_LAT = 111000


def _approx_distance_m(lng1, lat1, lng2, lat2):
    """两点间近似距离（米），使用平面近似替代 Haversine"""
    dx = (lng1 - lng2) * _M_PER_DEG_LNG
    dy = (lat1 - lat2) * _M_PER_DEG_LAT
    return math.sqrt(dx * dx + dy * dy)


def _to_min(time_str):
    """将 HH:MM 字符串转为分钟数"""
    sp = time_str.split(':')
    return int(sp[0]) * 60 + int(sp[1])


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

    # === trip ===
    t = data.get('trip', {})
    if not t.get('title'):
        errors.append('trip.title 缺失')
    if not t.get('date'):
        errors.append('trip.date 缺失')

    # weather
    w = t.get('weather', {})
    if not w:
        errors.append('trip.weather 缺失')
    elif not w.get('temp_high') or not w.get('temp_low'):
        warnings.append('weather 缺少温度信息')

    # transport
    tr = t.get('transport', {})
    if not tr.get('distance_km'):
        warnings.append('transport.distance_km 缺失')
    if not tr.get('duration_min'):
        warnings.append('transport.duration_min 缺失')

    # budget — 检查字段一致性
    bg = t.get('budget', {})
    budget_keys = set(bg.keys())
    known_patterns = [
        {'food_per_person', 'economy', 'standard', 'premium'},
        {'food_per_person_tight', 'food_per_person_comfort', 'food_per_person_premium'},
        {'per_person_total'},
    ]
    has_valid = any(budget_keys & p for p in known_patterns)
    if not has_valid:
        errors.append(f'budget 字段不匹配已知模式，当前: {sorted(budget_keys)}')

    # === route_map ===
    rm = data.get('route_map', {})
    if not rm.get('navi_url'):
        warnings.append('route_map.navi_url 缺失，页面无导航按钮')

    # === timeline ===
    tl = data.get('timeline', [])
    if not tl:
        errors.append('timeline 为空')
    if len(tl) < 3:
        warnings.append(f'timeline 只有 {len(tl)} 项，建议 ≥5')

    for i, item in enumerate(tl):
        prefix = f'timeline[{i}] ({item.get("time", "?")})'
        if not item.get('title'):
            errors.append(f'{prefix} title 缺失')
        if not item.get('time'):
            errors.append(f'{prefix} time 缺失')
        if not item.get('type'):
            warnings.append(f'{prefix} type 缺失')

        # 导航链接 — 有 location 就应有 navi
        loc = item.get('location', {})
        if loc and loc.get('lng'):
            links = item.get('links') or {}
            has_navi = item.get('navi_url') or links.get('amap_navi')
            if not has_navi:
                warnings.append(f'{prefix} 有坐标但无导航链接')

        # 聚合数据一致性
        agg = item.get('aggregation', {})
        links = item.get('links') or {}
        if agg.get('bilibili_bvid') and not links.get('bilibili'):
            warnings.append(f'{prefix} aggregation 含 bilibili_bvid 但 links.bilibili 缺失')
        if agg.get('dianping') and not links.get('dianping'):
            item_name = agg['dianping'].get('name', '') if isinstance(agg.get('dianping'), dict) else ''
            if not any(k.startswith('dianping') for k in links):
                warnings.append(f'{prefix} aggregation 含点评数据但 links 无点评链接')

        # 类型字段
        if item.get('type') and item['type'] not in ('transport', 'food', 'sight', 'break'):
            t = item['type']
            warnings.append(prefix + ' type="' + t + '" 非标准值')

    # === 新增检查：起点正确（规则 7）===
    first_non_transport = None
    for item in tl:
        if item.get('type') != 'transport':
            first_non_transport = item
            break
    if first_non_transport:
        loc = first_non_transport.get('location', {})
        lng = loc.get('lng')
        lat = loc.get('lat')
        # 默认起点: 120.241, 30.210（龙湖春江天玺/兴议站）
        home_lng, home_lat = 120.241, 30.210
        if lng and lat:
            dist = _approx_distance_m(lng, lat, home_lng, home_lat)
            if dist > 5000:
                warnings.append(f'第一个游玩点距默认起点 {dist/1000:.1f}km，确认起点正确？')

    # === 新增检查：流转时间（规则 8）===
    for i, (a, b) in enumerate(zip(tl, tl[1:])):
        # 相邻两个非 transport 项之间应插入 transport
        if a.get('type') != 'transport' and b.get('type') != 'transport':
            la = a.get('location', {})
            lb = b.get('location', {})
            if la.get('lng') and lb.get('lng'):
                dist = _approx_distance_m(la['lng'], la['lat'], lb['lng'], lb['lat'])
                if dist > 500:
                    pa_time = a.get("time", "?")
                    pb_time = b.get("time", "?")
                    warnings.append(f'timeline[{i}] ({pa_time}) → timeline[{i+1}] ({pb_time}) 间距 {dist/1000:.2f}km 但中间无 transport 项')

    # === 新增检查：行程不赶 + 用餐时长（规则 9-10）===
    type_min_duration = {
        'sight': 60,   # 景点最低 60min（博物馆等≥90，但至少 60）
        'food': 60,    # 用餐最低 60min
        'break': 30,   # 休息最低 30min
    }
    for i, item in enumerate(tl):
        t = item.get('type', '')
        if t not in type_min_duration:
            continue
        time_str = item.get('time', '')
        parts = time_str.replace('-', ' ').replace('—', ' ').split()
        if len(parts) >= 2:
            try:
                start = _to_min(parts[0])
                end = _to_min(parts[1])
                duration = end - start if end > start else end + 24*60 - start
                min_dur = type_min_duration[t]
                item_time = item.get("time", "?")
                if duration < min_dur:
                    warnings.append(f'timeline[{i}] ({item_time}) {t} 类型仅 {duration}min，建议 ≥{min_dur}min')
            except:
                pass

    # === restaurants ===
    rs = data.get('restaurants', [])
    if not rs and not any(i.get('type') == 'food' for i in tl):
        warnings.append('无 restaurants 数组且 timeline 无 food 类型项')

    for i, r in enumerate(rs):
        prefix = f'restaurants[{i}]'
        if not r.get('name'):
            errors.append(f'{prefix} name 缺失')
        if not r.get('confidence'):
            warnings.append(f'{prefix} confidence 缺失')
        if r.get('confidence') and r['confidence'] not in ('high', 'medium', 'low'):
            c = r['confidence']
            errors.append(prefix + ' confidence="' + c + '" 非 high/medium/low')

    # === 输出 ===
    print(f'📋 校验: {data_path}')
    print(f'   时间线: {len(tl)} 项 | 餐厅: {len(rs)} 家')

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
        print('用法: python3 scripts/lint.py <trip_data.json>')
        sys.exit(1)
    sys.exit(lint(sys.argv[1]))
