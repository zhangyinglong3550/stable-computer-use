#!/usr/bin/env bash
# 只读自检：验证 stable-computer-use 在这台机器上真的能用，且速度达标。
# 不会改任何界面状态，随时可以跑。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCU="${SCU_BIN:-$ROOT/cli/scu}"
[ -x "$SCU" ] || SCU="$(command -v scu)"
pass=0; fail=0; skip=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; pass=$((pass+1)); }
ng()   { printf "  \033[31m✗\033[0m %s\n" "$1"; [ -n "${2:-}" ] && printf "      %s\n" "$2"; fail=$((fail+1)); }
sk()   { printf "  \033[33m–\033[0m %s\n" "$1"; skip=$((skip+1)); }
head_() { printf "\n\033[1m%s\033[0m\n" "$1"; }

j() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

echo "stable-computer-use 自检"
echo "CLI: $SCU"

# ---------------------------------------------------------------- 基础
head_ "1. 环境与权限"
D=$("$SCU" doctor 2>/dev/null)
if [ "$(echo "$D" | j "d.get('accessibilityUsable')")" = "True" ]; then
  ok "辅助功能可用"
else
  ng "辅助功能不可用" "$(echo "$D" | j "d.get('hint','')" | head -1)"
fi
if [ "$(echo "$D" | j "d.get('windowUsable')")" = "True" ]; then
  ok "能拿到真实窗口"
else
  ng "所有 app 的窗口都是代理" "唤醒屏幕后重试"
fi
if [ "$("$SCU" daemon status 2>/dev/null | j "d.get('running')")" = "True" ]; then
  ok "daemon 在跑"
else
  ng "daemon 没起来"
fi

# ---------------------------------------------------------------- 读
head_ "2. 读取（不改界面）"
APP="com.apple.finder"
SNAP=$("$SCU" snapshot --app "$APP" --json 2>/dev/null)
N=$(echo "$SNAP" | j "len(d.get('elements',[]))")
WALK=$(echo "$SNAP" | j "d.get('walkMs','?')")
if [ "${N:-0}" -gt 10 ] 2>/dev/null; then
  ok "Finder 读到 $N 个元素（遍历 ${WALK}ms）"
else
  ng "Finder 读不到内容" "是不是没有打开的窗口？"
fi

# ref 稳定性
R1=$("$SCU" snapshot --app "$APP" --json 2>/dev/null | j "'|'.join(e['ref'] for e in d.get('elements',[])[:50])")
R2=$("$SCU" snapshot --app "$APP" --json 2>/dev/null | j "'|'.join(e['ref'] for e in d.get('elements',[])[:50])")
if [ -n "$R1" ] && [ "$R1" = "$R2" ]; then
  ok "两次快照 ref 一致（稳定引用）"
else
  ng "ref 不稳定" "界面在动？或两次之间内容变了"
fi

# ---------------------------------------------------------------- 速度
head_ "3. 速度"
WALK_T=$("$SCU" js -e 'const a=await scu.getApp("com.apple.finder"); const st=await a.state({json:true}); console.log(st.walkMs)' 2>/dev/null | tail -1)
if [ "${WALK_T:-9999}" -lt 200 ] 2>/dev/null; then
  ok "快照遍历 ${WALK_T}ms（阈值 200ms）"
else
  ng "快照遍历 ${WALK_T}ms 偏慢"
fi

PING_T=$(python3 - <<'PY' 2>/dev/null
import socket, json, time, os
p=f"/tmp/scu-{os.getuid()}.sock"
def call(req):
    s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(p)
    s.sendall((json.dumps(req)+"\n").encode()); b=b""
    while not b.endswith(b"\n"):
        d=s.recv(65536)
        if not d: break
        b+=d
    s.close(); return json.loads(b)
call({"cmd":"ping"})
t=time.perf_counter()
for _ in range(50): call({"cmd":"ping"})
print(round((time.perf_counter()-t)/50*1000, 2))
PY
)
if [ -n "${PING_T:-}" ]; then
  ok "daemon 往返 ${PING_T}ms/次"
fi

# 变化检测语义
CH=$("$SCU" js -e '
const a = await scu.getApp("com.apple.finder");
const s = await a.state({json:true});
const t = s.elements.find(e => e.actions && e.actions.includes("AXPress"));
console.log(t ? "HAS" : "NONE");
' 2>/dev/null | tail -1)
if [ "$CH" = "HAS" ]; then
  ok "能找到可按压元素（actAndWait 可用）"
else
  sk "当前窗口没有可按压元素，跳过变化检测"
fi

# ---------------------------------------------------------------- 安全契约
head_ "4. 安全契约"
"$SCU" click --app "$APP" --xy "10,10" --via mouse >/dev/null 2>&1
C=$?
if [ "$C" -eq 11 ]; then
  ok "真鼠标未授权时被拒绝（exit 11）"
else
  ng "真鼠标没有要求授权（exit=$C）"
fi

K=$("$SCU" key --app "$APP" --key "super+alt+shift+z" 2>/dev/null)
KVIA=$(printf '%s' "$K" | j 'd.get("via")')
if [ "$KVIA" = "pid" ]; then
  ok "非菜单组合键定向投递，不抢焦点（via=pid）"
else
  ng "组合键没有走定向投递（via=${KVIA:-none}）"
fi

"$SCU" key --app "$APP" --key "super+alt+shift+z" --via mouse >/dev/null 2>&1
C=$?
if [ "$C" -eq 11 ]; then
  ok "系统级键盘未授权时被拒绝（exit 11）"
else
  ng "系统级键盘没有要求授权（exit=$C）"
fi

"$SCU" verify --app "$APP" --ref zzzzzz >/dev/null 2>&1
C=$?
if [ "$C" -eq 5 ]; then
  ok "过期 ref 报 stale_ref（exit 5）"
else
  ng "过期 ref 返回了 exit=$C"
fi

# ---------------------------------------------------------------- 截图
head_ "5. 截图"
TMPD=$(mktemp -d)
if "$SCU" shot --app "$APP" --out "$TMPD/a.png" >/dev/null 2>&1 && [ -f "$TMPD/a.png" ]; then
  FULL=$(stat -f%z "$TMPD/a.png" 2>/dev/null || echo 0)
  ok "整窗截图 $((FULL/1024)) KB"
  if "$SCU" shot --app "$APP" --out "$TMPD/b.png" --crop 200,30,600,80 >/dev/null 2>&1; then
    CROP=$(stat -f%z "$TMPD/b.png" 2>/dev/null || echo 0)
    ok "裁剪截图 $((CROP/1024)) KB"
  fi
else
  ng "截图失败"
fi
rm -rf "$TMPD"

# ---------------------------------------------------------------- 汇总
printf "\n\033[1m结果\033[0m: %d 通过" "$pass"
[ "$fail" -gt 0 ] && printf "，\033[31m%d 失败\033[0m" "$fail"
[ "$skip" -gt 0 ] && printf "，%d 跳过" "$skip"
printf "\n"
[ "$fail" -eq 0 ] || exit 1
