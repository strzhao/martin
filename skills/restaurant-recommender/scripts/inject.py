#!/usr/bin/env python3
"""restaurant_data.json → restaurant.html 注入脚本

用法: python3 scripts/inject.py output/restaurant_data.json
输出: output/restaurant.html
"""

import json
import sys
import os


def main():
    if len(sys.argv) < 2:
        print("用法: python3 scripts/inject.py <restaurant_data.json>")
        sys.exit(1)

    data_path = sys.argv[1]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    skill_root = os.path.dirname(script_dir)

    try:
        # 读取 JSON 数据
        with open(data_path, 'r', encoding='utf-8') as f:
            restaurant_data = json.load(f)
    except FileNotFoundError:
        print(f'❌ 文件不存在: {data_path}')
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f'❌ JSON 解析失败: {e}')
        sys.exit(1)

    # 读取 HTML 模板
    template_path = os.path.join(skill_root, 'assets', 'template.html')
    try:
        with open(template_path, 'r', encoding='utf-8') as f:
            template = f.read()
    except FileNotFoundError:
        print(f'❌ 模板文件不存在: {template_path}')
        sys.exit(1)

    # 替换占位符
    restaurant_json_str = json.dumps(restaurant_data, ensure_ascii=False)
    html = template.replace('__RESTAURANT_DATA__', restaurant_json_str)

    # 写入输出
    try:
        output_dir = os.path.join(skill_root, 'output')
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, 'restaurant.html')
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(html)
    except OSError as e:
        print(f'❌ 写入文件失败: {e}')
        sys.exit(1)

    print(f"✅ 已生成: {output_path}")
    print(f"   文件大小: {len(html):,} 字节")


if __name__ == '__main__':
    main()
