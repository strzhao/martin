#!/usr/bin/env python3
"""trip_data.json → trip.html 注入脚本

用法: python3 scripts/inject.py <trip_data.json> [output.html]
输出: 默认 output/trip.html；可用第二参数指定（多路线时各自指定独立输出文件，
      再由 tunnel deploy 分别部署成独立 drop）。
"""

import json
import sys
import os

def main():
    if len(sys.argv) < 2:
        print("用法: python3 scripts/inject.py <trip_data.json> [output.html]")
        print("     默认输出: output/trip.html")
        sys.exit(1)

    data_path = sys.argv[1]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    skill_root = os.path.dirname(script_dir)

    # 读取 JSON 数据
    with open(data_path, 'r', encoding='utf-8') as f:
        trip_data = json.load(f)

    # ── 09-06 产品审查修复：管线保证，不靠生成方自觉 ──
    from datetime import datetime, timezone, timedelta
    from urllib.parse import quote

    # ① 烙入真实生成时间（页脚「数据采集于」——修掉 fmtNow() 每次打开印当下时间的信任 bug）；
    #    取数据文件 mtime（采集完成时刻），而非 inject 当下（重注入不会谎称数据新鲜度）
    if not trip_data.get('generated_at'):
        tz = timezone(timedelta(hours=8))
        mtime = os.path.getmtime(data_path)
        trip_data['generated_at'] = datetime.fromtimestamp(mtime, tz).strftime('%Y-%m-%d %H:%M')

    # ② 导航链接自动补全：有 location 但无 navi_url → 从坐标生成高德 URI（真实实例 2/7 缺失）
    auto_navi = 0
    for item in trip_data.get('timeline', []):
        loc = item.get('location') or {}
        links = item.get('links') or {}
        has_navi = item.get('navi_url') or links.get('amap_navi')
        if not has_navi and loc.get('lng') and loc.get('lat'):
            name = loc.get('name') or item.get('title', '')
            item['navi_url'] = (
                f"https://uri.amap.com/marker?position={loc['lng']},{loc['lat']}"
                f"&name={quote(str(name)[:30])}&coordinate=gaode&callnative=1"
            )
            auto_navi += 1
    if auto_navi:
        print(f"   🧭 自动补导航链接: {auto_navi} 项（uri.amap.com/marker 从坐标生成）")

    # 读取 HTML 模板
    template_path = os.path.join(skill_root, 'assets', 'template.html')
    with open(template_path, 'r', encoding='utf-8') as f:
        template = f.read()

    # 替换占位符
    trip_json_str = json.dumps(trip_data, ensure_ascii=False)
    html = template.replace('__TRIP_DATA__', trip_json_str)

    # 写入输出：默认 output/trip.html，可用第二参数覆盖（多路线时各自指定独立文件）
    if len(sys.argv) >= 3:
        output_path = sys.argv[2]
    else:
        output_path = os.path.join(skill_root, 'output', 'trip.html')
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f"✅ 已生成: {output_path}")
    print(f"   文件大小: {len(html):,} 字节")

if __name__ == '__main__':
    main()
