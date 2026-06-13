# Vision API 用法

## 环境

- 服务: llama.cpp llama-server
- 端口: `http://127.0.0.1:8001`
- 模型: `qwen3.6-35b`
- 多模态: mmproj-F16.gguf 已加载
- 认证: `Authorization: Bearer qwen-local-key`

## API 端点

```
POST /v1/chat/completions
```

## 关键约束

1. **仅支持 base64 传图**，URL 模式不可用（llama-server 不支持远程下载）
2. **max_tokens 必须 ≥ 2000**：Qwen3.6 是 thinking 模型，推理链消耗 ~1500 tokens
3. **单张耗时 ~2 min**（35B MoE on M4 Max）
4. 适合选 3-5 张关键图片，不适合批量

## 调用示例

```bash
# 下载图片
curl -sL -o /tmp/img.jpg "<image_url>"

# base64 编码
IMG_B64=$(base64 -i /tmp/img.jpg | tr -d '\n')

# 调用
curl -s --max-time 180 http://127.0.0.1:8001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer qwen-local-key" \
  -d "{
    \"model\": \"qwen3.6-35b\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"描述图片内容，中文，30字\"},
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/jpeg;base64,$IMG_B64\"}}
      ]
    }],
    \"max_tokens\": 2000
  }"
```

## 适用场景

| 场景 | 提示词 | 价值 |
|------|--------|------|
| 菜品识别 | "识别图片中的菜品名称和类型" | 验证餐厅照片真实性 |
| 环境判断 | "判断餐厅环境：苍蝇馆子/网红装修/高档餐厅" | 辅助餐厅分类 |
| 照骗验证 | "对比图片内容与文字描述是否一致: <文字描述>" | 过滤虚假宣传 |

## 健康检查

```bash
curl -s http://127.0.0.1:8001/health
# {"status":"ok"}
```
