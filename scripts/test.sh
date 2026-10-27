#!/usr/bin/env bash
# 跑全部测试：先构建，再单元 + 集成
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> 构建 scu-ax"
( cd runtime && swift build -c release ) || { echo "构建失败"; exit 1; }

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
