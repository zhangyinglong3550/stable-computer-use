#!/usr/bin/env bash
# 把 stable-computer-use 接进本机所有 Agent
#   - 构建 scu-ax
#   - 把 scu 链到 ~/.local/bin（通常已在 PATH 里）
#   - 把 SKILL.md 装进各个 Agent 的技能目录
#   - 自检
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> 构建 scu-ax"
if ! ( cd runtime && swift build -c release ); then
  echo "    构建失败，清理 .build 后重试（目录移动会让模块缓存路径失效）"
  rm -rf runtime/.build
  ( cd runtime && swift build -c release ) || { echo "构建仍然失败，检查 Xcode Command Line Tools"; exit 1; }
fi

echo "==> 链接 scu 到 ~/.local/bin"
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/cli/scu" "$HOME/.local/bin/scu"
echo "    $HOME/.local/bin/scu -> $ROOT/cli/scu"

echo "==> 安装 skill"
installed=0
for dir in "$HOME/.agents/skills" \
           "$HOME/.claude/skills" \
           "$HOME/.codex/skills" \
           "$HOME/.cursor/skills" \
           "$HOME/.config/agents/skills"; do
  # 只在「父目录存在」时装 —— 说明这台机器确实用那个 Agent
  [ -d "$(dirname "$dir")" ] || continue
  mkdir -p "$dir/stable-computer-use"
  cp skill/SKILL.md "$dir/stable-computer-use/SKILL.md"
  echo "    $dir/stable-computer-use"
  installed=$((installed + 1))
done
[ "$installed" -gt 0 ] || echo "    （没找到技能目录，跳过）"

echo "==> 自检"
if command -v scu >/dev/null 2>&1; then
  scu doctor || true
else
  echo "    ★ ~/.local/bin 不在 PATH 里，请把下面这行加到 shell 配置："
  echo '      export PATH="$HOME/.local/bin:$PATH"'
fi

cat <<TIP

装好了。以后在任何目录都能直接用：

  scu js -e 'const a = await scu.getApp("Finder"); console.log(await a.state())'

三个要点：
  1. 首次调用会自动拉起常驻 daemon（约 1 秒），之后每个动作 0.16ms
  2. 重建 scu-ax 之后 daemon 还是旧进程，deactivate 一下：
       python3 -c "import socket,os;s=socket.socket(socket.AF_UNIX);s.connect(f'/tmp/scu-{os.getuid()}.sock');s.sendall(b'{\\"cmd\\":\\"shutdown\\"}\\n')"
     下一次调用会自动起新的
  3. 授权失效时（scu doctor 的 accessibilityUsable 为 false），到
     系统设置 → 隐私与安全性 → 辅助功能，把终端关掉再打开

TIP
