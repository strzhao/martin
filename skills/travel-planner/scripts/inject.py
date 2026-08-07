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
