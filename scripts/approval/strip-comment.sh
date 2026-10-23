#!/bin/bash
# strip-comment.sh — 评论投递剥离逻辑单一真源（卡 t_ee058c57，2026-10-24）
#
# 背景：strip_leading_comments 原是 execute.sh 私有函数（原 :103-118）；auto-gate 放行后的
# L2-auto 评论投递若不走 execute.sh 全链（无隧道免审批路）而手工 `gh api -X POST …/comments
# -F body=@file`，头部 HTML 注释块与「## 内部备注」段原样上线（2026-10-24 实证：#140178
# 首评 6369855435 外泄 3389 字节，投递后回读抓到、PATCH 同 id 净化）。
# 修复形态：本文件 = 唯一实现；execute.sh（L2-A 隧道全链）与 post-comment.sh（L2-auto
# 免隧道薄包装）同源 source。本仓禁止出现第二份剥离实现（单测 unit/approval-strip-post.sh
# 以 inblock 单源断言 + mutation RED 电池守卫）。
#
# 用法 A（函数库）：source 本文件后调 strip_leading_comments <file>（剥离结果走 stdout）
# 用法 B（直呼剥离）：bash strip-comment.sh <draft-file>    # 同语义，供手工投递兜底
# 库文件纪律：本文件不设 shell 选项（选项归调用方）；被 source 时不产生任何 stdout；
# 重复 source 无害（仅重定义函数）。

# strip_leading_comments <file> → stdout
# 剥离头部 `<!-- ... -->` 注释块（可多块，块间空行一并跳过），其余行逐字输出（C8）；
# 并截掉「## 内部备注」起的尾部段（09-06 投递事故复盘：103568 草稿含内部备注段，
# 若不截断会随评论外泄——与审批页 payload 口径一致）
strip_leading_comments() {
  awk '
    BEGIN { scanning = 1; inblock = 0 }
    scanning {
      if ($0 ~ /^[[:space:]]*$/) next
      if (inblock) { if ($0 ~ /-->/) { inblock = 0 }; next }
      if ($0 ~ /^[[:space:]]*<!--/) {
        if ($0 ~ /-->/) next
        inblock = 1; next
      }
      scanning = 0
    }
    /^## 内部备注/ { exit }
    { print }
  ' "$1"
}

# 直呼剥离路：与函数同语义（手工投递的兜底剥离也走同一实现，绕过剥离的手投路径清零）
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if (( $# != 1 )) || [[ ! -f "$1" ]]; then
    echo "usage: bash strip-comment.sh <draft-file>" >&2
    exit 2
  fi
  strip_leading_comments "$1"
fi
