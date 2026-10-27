#!/usr/bin/env bash
# 构建 Swift 助手并把 skill 装到常见 Agent 目录
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> 构建 smac-ax"
( cd runtime && swift build -c release )

echo "==> 自检"
./cli/smac doctor || {
  echo "!! 权限没给全，先到 系统设置 → 隐私与安全性 → 辅助功能 勾选终端"
}

echo "==> 装 skill"
for dir in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.cursor/skills" "$HOME/.agents/skills"; do
  [ -d "$(dirname "$dir")" ] || continue
  mkdir -p "$dir/stable-mac"
  cp skill/SKILL.md "$dir/stable-mac/SKILL.md"
  echo "    $dir/stable-mac"
done

cat <<TIP

用起来（当前会话）：

  export PATH="\$PATH:$ROOT/cli"
  smac doctor
  smac snapshot --app Finder

TIP
