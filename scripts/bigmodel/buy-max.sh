#!/usr/bin/env bash
# ============================================================
# GLM Coding Max 套餐自动购买脚本
#
# 用法:
#   ./scripts/bigmodel/buy-max.sh              # 默认：连续包季，2s 轮询，等 10 分钟
#   ./scripts/bigmodel/buy-max.sh --dry-run    # 仅检查状态
#   ./scripts/bigmodel/buy-max.sh --period 月   # 连续包月
#   ./scripts/bigmodel/buy-max.sh --period 年   # 连续包年（8折）
#   ./scripts/bigmodel/buy-max.sh --nowait      # 不等待，直接尝试购买（如果已开售）
#
# 前置条件:
#   1. Chrome 已启动且 Browser Bridge 运行中（端口 19825）
#   2. 已在 Chrome 中登录 bigmodel.cn
#   3. opencli profile 已配置（通常是 'enu757c6'）
#
# 策略:
#   - 轮询检测 Max 套餐按钮状态
#   - 按钮从 "暂时售罄" 变为可购买时立即点击
#   - 自动处理弹窗（套餐权益变更说明、实名认证等）
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${GLM_PROFILE:-enu757c6}"
PERIOD="季"
DRY_RUN="false"
POLL_INTERVAL=2000
MAX_WAIT=600  # 默认等 10 分钟，开售后通常几秒内就会变化

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --nowait)
      MAX_WAIT=1
      shift
      ;;
    --period)
      PERIOD="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --poll-interval)
      POLL_INTERVAL="$2"
      shift 2
      ;;
    --max-wait)
      MAX_WAIT="$2"
      shift 2
      ;;
    -h|--help)
      echo "用法: $0 [选项]"
      echo ""
      echo "选项:"
      echo "  --dry-run          仅检查 Max 套餐状态，不购买"
      echo "  --nowait            不等待开售，直接尝试购买"
      echo "  --period 月|季|年    订阅周期（默认: 季，9折）"
      echo "  --profile <name>    Chrome 配置文件（默认: $PROFILE）"
      echo "  --poll-interval <ms> 轮询间隔毫秒（默认: 2000）"
      echo "  --max-wait <s>      最长等待秒数（默认: 600）"
      echo "  -h, --help          显示帮助"
      echo ""
      echo "示例:"
      echo "  $0 --dry-run                 # 检查当前状态"
      echo "  $0                            # 默认购买（等开售）"
      echo "  $0 --period 月 --max-wait 1200 # 连包月，等 20 分钟"
      exit 0
      ;;
    *)
      echo "未知参数: $1"
      exit 1
      ;;
  esac
done

# 检查 opencli 可用
if ! command -v opencli &>/dev/null; then
  echo "❌ opencli 未安装。请运行: npm install -g @jackwener/opencli"
  exit 1
fi

# 检查 adapter 是否存在
ADAPTER_PATH="$HOME/.opencli/clis/bigmodel/buy-max.js"
if [[ ! -f "$ADAPTER_PATH" ]]; then
  echo "❌ bigmodel adapter 未找到: $ADAPTER_PATH"
  echo "   请确认 adapter 已安装到 ~/.opencli/clis/bigmodel/buy-max.js"
  exit 1
fi

echo "=========================================="
echo "  GLM Coding Max 套餐购买工具"
echo "=========================================="
echo "  订阅周期: 连续包${PERIOD}"
echo "  轮询间隔: ${POLL_INTERVAL}ms"
echo "  最长等待: ${MAX_WAIT}s"
echo "  Chrome Profile: ${PROFILE}"
echo "  Dry Run: ${DRY_RUN}"
echo "=========================================="
echo ""

DRY_FLAG=""
if [[ "$DRY_RUN" == "true" ]]; then
  DRY_FLAG="--dry-run"
fi

# 执行购买
opencli --profile "$PROFILE" bigmodel buy-max \
  --period "$PERIOD" \
  --poll-interval "$POLL_INTERVAL" \
  --max-wait "$MAX_WAIT" \
  $DRY_FLAG

EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
  echo ""
  echo "✅ 脚本执行完成"
else
  echo ""
  echo "❌ 脚本执行失败 (exit code: $EXIT_CODE)"
fi

exit $EXIT_CODE
