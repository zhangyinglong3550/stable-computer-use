#!/usr/bin/env bash
# 跑全部测试：先构建，再单元 + 集成
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> 构建 scu-ax"
build() { ( cd runtime && swift build -c release ); }

if ! build; then
  # 常见于仓库目录被改名/移动：.build 里的 PCH 记着旧绝对路径，必须清掉重建
  echo "构建失败，清理 .build 后重试一次（目录移动会导致模块缓存路径失效）"
  rm -rf runtime/.build
  build || { echo "构建仍然失败，请检查 Xcode Command Line Tools"; exit 1; }
fi

fail=0

echo
echo "==> 单元测试"
python3 tests/test_unit.py || fail=1

echo
echo "==> 集成测试"
python3 tests/test_integration.py || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "✓ 全部通过"
else
  echo "✗ 有失败"
fi
exit "$fail"
