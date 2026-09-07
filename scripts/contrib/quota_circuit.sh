#!/bin/zsh
# quota_circuit.sh — LLM 配额断路器（09-06 八连 429 空烧事故沉淀）
#
# 问题：claude -p 因配额（429/周月上限）失败时，scan 每小时空烧一次、深检每小时
# 重试晋升空烧一次，直到人工发现。内容类失败值得重试，配额类失败重试只会刷屏。
#
# 方案：任一调用方在 claude -p 失败后 trip（检测日志签名）→ 跳闸写冷却旗标；
# 闸门类脚本（run-watch/deep_check_gate/deep-check）起步先 check，开闸期跳过一切
# LLM 步骤；冷却到期（日志里的重置时间，缺省 6h）自动闭合，放一次真实尝试，
# 仍配额死则再次跳闸——把「每小时空烧」降为「每冷却周期一次探测」。
#
# 用法：
#   quota_circuit.sh trip <logfile>   # 检测日志尾部配额签名，命中则跳闸（exit 0=已跳闸 1=未命中）
#   quota_circuit.sh check            # exit 0=闭合（可跑 LLM） 1=打开（冷却中，stdout 打剩余秒数）
#   quota_circuit.sh clear            # 手动/成功时闭合
#   quota_circuit.sh status           # 人读状态
#
# seam：QUOTA_CIRCUIT_FILE（旗标路径）、QUOTA_CIRCUIT_DEFAULT_COOLDOWN（缺省冷却秒数）
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
FLAG="${QUOTA_CIRCUIT_FILE:-$CONTRIB/.quota-circuit}"
DEFAULT_COOLDOWN="${QUOTA_CIRCUIT_DEFAULT_COOLDOWN:-21600}"   # 6h

now() { date +%s; }

# 从日志解析「将在 YYYY-MM-DD HH:MM:SS 重置」→ epoch；失败输出空
parse_reset_epoch() {
  local log="$1" dt ep
  dt="$(tail -80 "$log" 2>/dev/null | grep -oE '将在 [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} 重置' | tail -1 | sed -E 's/^将在 (.*) 重置$/\1/')"
  [[ -n "$dt" ]] || return 1
  ep="$(date -j -f "%Y-%m-%d %H:%M:%S" "$dt" +%s 2>/dev/null)" || return 1
  [[ -n "$ep" ]] && echo "$ep"
}

cmd="${1:-help}"
case "$cmd" in
  trip)
    log="${2:-}"
    [[ -n "$log" && -f "$log" ]] || { echo "trip 用法: trip <logfile>" >&2; exit 2; }
    if tail -80 "$log" 2>/dev/null | grep -qE '(Request rejected \(429\)|已达到每|使用上限|rate[_ ]limit|usage limit|quota exceeded)'; then
      until="$(parse_reset_epoch "$log")"
      [[ -n "${until:-}" ]] || until=$(( $(now) + DEFAULT_COOLDOWN ))
      # 已有更晚的冷却则保留更晚者（多次跳闸不缩短冷却）
      if [[ -f "$FLAG" ]]; then
        old="$(cat "$FLAG" 2>/dev/null)"
        [[ "$old" =~ ^[0-9]+$ && "$old" -gt "$until" ]] && until="$old"
      fi
      echo "$until" > "$FLAG"
      echo "TRIPPED until=$(date -j -f %s "$until" '+%F %T' 2>/dev/null || echo "$until")"
      exit 0
    fi
    exit 1
    ;;
  check)
    [[ -f "$FLAG" ]] || exit 0
    until="$(cat "$FLAG" 2>/dev/null)"
    if [[ ! "$until" =~ ^[0-9]+$ ]]; then
      rm -f "$FLAG"; exit 0          # 旗标损坏 → 闭合自愈
    fi
    remain=$(( until - $(now) ))
    if (( remain <= 0 )); then
      rm -f "$FLAG"; exit 0          # 冷却到期 → 自动闭合，放一次真实尝试
    fi
    echo "$remain"
    exit 1
    ;;
  clear)
    rm -f "$FLAG"; echo "OK"
    ;;
  status)
    if [[ -f "$FLAG" ]]; then
      until="$(cat "$FLAG" 2>/dev/null)"
      remain=$(( ${until:-0} - $(now) ))
      if (( remain > 0 )); then
        echo "OPEN（冷却剩余 ${remain}s，至 $(date -j -f %s "$until" '+%F %T' 2>/dev/null || echo "$until")）"
      else
        echo "CLOSED（旗标已到期，下次 check 自动清除）"
      fi
    else
      echo "CLOSED（无旗标）"
    fi
    ;;
  help|*)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
