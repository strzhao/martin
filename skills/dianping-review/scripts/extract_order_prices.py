"""
extract_order_prices.py — 从 vision.json 中检测订单/收据截图，用 Qwen API 单独 OCR 提取价格。

用法：
  python3 extract_order_prices.py <vision_json_path> <output_json_path> [--folder <dir>]

输入：dianping-vision CLI 产出的 vision.json
      --folder: 可选，当 vision.json 中的路径失效时（如文件夹已改名），用此路径覆盖图片所在目录
输出：prices.json
"""

import json
import sys
import os
import base64
import urllib.request
import urllib.error
from typing import Optional

# ============================================================
# 配置
# ============================================================
QWEN_API_URL = os.environ.get("AI_BASE_URL", "http://127.0.0.1:8001/v1/chat/completions")
QWEN_API_KEY = os.environ.get("AI_API_KEY", "qwen-local-key")
QWEN_MODEL = os.environ.get("AI_VISION_MODEL", "qwen3.6-35b")

ORDER_KEYWORDS = [
    "订单", "收据", "结账", "小计", "电子订单", "菜单明细",
    "点单", "消费清单", "结算单", "小票", "账单",
]

OCR_PROMPT = """请仔细阅读这张餐厅电子订单/收据截图，逐行输出所有能读到的信息。

输出格式：菜名 | 规格(如原味/孜然等，没有则留空) | 数量 | 价格(¥)
如果某一行没有价格，也请写出菜名和规格。

注意：
- 价格列可能是"小计"或"单价"，请按实际标注输出
- 不要遗漏任何一行
- 只需要输出订单内容，不要分析菜品做法，不要做任何其他解释

示例输出格式：
呼伦贝尔羊肉串（一打） | 原味 | x1 | 66
烤鳗鱼 | | x2 | 17.6
..."""


def is_order_image(analysis_text: str) -> bool:
    """通过关键词检测图片是否为订单/收据截图"""
    return any(kw in analysis_text for kw in ORDER_KEYWORDS)


def read_image_base64(filepath: str) -> str:
    """读取图片文件并转为 base64"""
    with open(filepath, "rb") as f:
        return base64.b64encode(f.read()).decode()


def ocr_order_image(image_path: str) -> str:
    """调用 Qwen API OCR 提取订单价格"""
    b64 = read_image_base64(image_path)

    body = json.dumps(
        {
            "model": QWEN_MODEL,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": OCR_PROMPT},
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/png;base64,{b64}"},
                        },
                    ],
                }
            ],
            "max_tokens": 4096,
            "temperature": 0.1,
        }
    ).encode()

    req = urllib.request.Request(
        QWEN_API_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {QWEN_API_KEY}",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            result = json.loads(resp.read())
            content = result["choices"][0]["message"].get("content", "")
            reasoning = result["choices"][0]["message"].get("reasoning_content", "")
            return content if content else reasoning
    except urllib.error.URLError as e:
        raise RuntimeError(f"Qwen API 调用失败: {e}")


def parse_ocr_text(text: str) -> tuple:
    """解析 OCR 输出为结构化数据。返回 (items, total)"""
    items = []
    total = 0.0
    for line in text.strip().split("\n"):
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("输出"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 4:
            name = parts[0]
            note = parts[1] if parts[1] else ""
            qty = parts[2]
            try:
                price = float(parts[3].replace("¥", "").replace("元", "").strip())
                total += price
                items.append({"name": name, "qty": qty, "price": price, "note": note})
            except ValueError:
                items.append({"name": name, "qty": qty, "note": note})
        elif len(parts) >= 3:
            name = parts[0]
            qty = parts[1]
            try:
                price = float(parts[2].replace("¥", "").replace("元", "").strip())
                total += price
                items.append({"name": name, "qty": qty, "price": price, "note": ""})
            except ValueError:
                items.append({"name": name, "qty": qty, "note": ""})
    return items, round(total, 2)


def resolve_image_path(img_path: str, folder: Optional[str]) -> str:
    """解析图片路径。如果原始路径不存在，尝试从 folder 中查找同名文件"""
    if os.path.exists(img_path):
        return img_path
    if folder:
        basename = os.path.basename(img_path)
        alt = os.path.join(folder, basename)
        if os.path.exists(alt):
            return alt
    raise FileNotFoundError(f"找不到图片: {img_path} (folder={folder})")


def main():
    # 解析 --folder 参数
    folder_override = None
    positional = []
    skip_next = False
    for i, a in enumerate(sys.argv[1:]):
        if skip_next:
            skip_next = False
            continue
        if a == "--folder":
            if i + 1 < len(sys.argv[1:]):
                folder_override = sys.argv[i + 2]  # +2 because argv[1:]
                skip_next = True
        else:
            positional.append(a)

    if len(positional) < 2:
        print("用法: python3 extract_order_prices.py <vision.json> <output.json> [--folder <dir>]", file=sys.stderr)
        sys.exit(1)

    vision_path = positional[0]
    output_path = positional[1]

    with open(vision_path) as f:
        vision_data = json.load(f)

    # 检测订单图片
    order_images = []
    for r in vision_data.get("results", []):
        if r.get("analysis") and is_order_image(r["analysis"]):
            order_images.append(r["image"])
            print(f"[extract_order_prices] 检测到订单截图: {os.path.basename(r['image'])}", file=sys.stderr)

    if not order_images:
        result = {"order_found": False, "images_processed": 0, "items": [], "total": 0}
        with open(output_path, "w") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
        print("[extract_order_prices] 未检测到订单截图，跳过", file=sys.stderr)
        sys.exit(0)

    # OCR 每张订单图片
    all_items = []
    total = 0.0
    raw_texts = []

    for img_path in order_images:
        real_path = resolve_image_path(img_path, folder_override)
        print(f"[extract_order_prices] OCR: {os.path.basename(real_path)} ...", file=sys.stderr)
        raw = ocr_order_image(real_path)
        raw_texts.append(raw)
        items, t = parse_ocr_text(raw)
        all_items.extend(items)
        total += t
        print(f"[extract_order_prices]   提取 {len(items)} 项, 小计 ¥{t}", file=sys.stderr)

    # 合并去重（按菜名+价格）
    seen = set()
    merged = []
    for item in all_items:
        key = (item.get("name", ""), item.get("price", 0))
        if key not in seen:
            seen.add(key)
            merged.append(item)

    result = {
        "order_found": True,
        "images_processed": len(order_images),
        "items": merged,
        "total": round(total, 2),
        "raw_text": "\n\n".join(raw_texts),
    }

    with open(output_path, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(
        f"[extract_order_prices] 完成: {len(merged)} 项, 总价 ¥{result['total']}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
