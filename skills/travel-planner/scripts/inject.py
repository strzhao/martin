#!/usr/bin/env python3
"""trip_data.json → trip.html 注入脚本

用法: python3 scripts/inject.py output/trip_data.json
输出: output/trip.html
"""

import json
import sys
import os

def main():
    if len(sys.argv) < 2:
        print("用法: python3 scripts/inject.py <trip_data.json>")
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

    # 写入输出
    output_dir = os.path.join(skill_root, 'output')
    os.makedirs(output_dir, exist_ok=True)
    output_path = os.path.join(output_dir, 'trip.html')
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(html)

    print(f"✅ 已生成: {output_path}")
    print(f"   文件大小: {len(html):,} 字节")

if __name__ == '__main__':
    main()
