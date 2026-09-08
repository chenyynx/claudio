#!/bin/bash
set -euo pipefail

# sim-preview.sh — シミュレーターでアプリ起動 + TrollVNC でリモートプレビュー
#
# Usage: bash .claude/skills/sim-preview/scripts/sim-preview.sh [vnc-only]
#
# "vnc-only" を指定すると flutter run をスキップして VNC サーバーのみ起動する

MODE="${1:-full}"
TROLLVNC_BIN="$HOME/bin/trollvncserver"
TROLLVNC_WEBCLIENTS="$HOME/bin/trollvnc-webclients"
VNC_PORT=5901
HTTP_PORT=5801
SCALE=0.75

# ---------- 前提チェック ----------
if [ ! -x "$TROLLVNC_BIN" ]; then
  echo "ERROR: trollvncserver not found at $TROLLVNC_BIN"
  echo "TrollVNC をビルドしてインストールしてください"
  exit 1
fi

# ---------- シミュレーター起動 ----------
echo "=== Checking simulator ==="
BOOTED_SIM=$(xcrun simctl list devices booted -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if d.get('state') == 'Booted':
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || true)

if [ -z "$BOOTED_SIM" ]; then
  echo "No booted simulator found. Booting first available iPhone..."
  SIM_UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for d in devices:
        if 'iPhone' in d.get('name', '') and d.get('isAvailable', False):
            print(d['udid'])
            sys.exit(0)
  ")
  if [ -z "$SIM_UDID" ]; then
    echo "ERROR: No available iPhone simulator found"
    exit 1
  fi
  xcrun simctl boot "$SIM_UDID"
  BOOTED_SIM="$SIM_UDID"
  echo "Booted simulator: $SIM_UDID"
  sleep 3
else
  echo "Simulator already booted: $BOOTED_SIM"
fi

SIM_DATA="$HOME/Library/Developer/CoreSimulator/Devices/$BOOTED_SIM/data"

# ---------- trollvncserver をシミュレーターに配置 ----------
echo "=== Setting up TrollVNC ==="
cp "$TROLLVNC_BIN" "$SIM_DATA/trollvncserver"
chmod +x "$SIM_DATA/trollvncserver"

# noVNC webclients をセットアップ（あれば）
if [ -d "$TROLLVNC_WEBCLIENTS" ]; then
  WEBCLIENTS_DIR="$HOME/Library/Developer/CoreSimulator/Devices/$BOOTED_SIM/share/trollvnc/webclients"
  mkdir -p "$WEBCLIENTS_DIR"
  cp -R "$TROLLVNC_WEBCLIENTS/"* "$WEBCLIENTS_DIR/" 2>/dev/null || true
fi

# ---------- 既存の trollvncserver を停止 ----------
# ポートを掴んでいるプロセスを確実に kill
lsof -i :"$VNC_PORT" -t 2>/dev/null | xargs kill -9 2>/dev/null || true
lsof -i :"$HTTP_PORT" -t 2>/dev/null | xargs kill -9 2>/dev/null || true
pkill -9 -f trollvncserver 2>/dev/null || true
sleep 2

# ---------- TrollVNC 起動 ----------
echo "=== Starting TrollVNC ==="
xcrun simctl spawn booted "$SIM_DATA/trollvncserver" \
  -p "$VNC_PORT" \
  -H "$HTTP_PORT" \
  -n "ccpocket Simulator" \
  -s "$SCALE" \
  -N \
  -U on \
  > /tmp/trollvnc-sim-preview.log 2>&1 &

# 起動待ち（最大10秒）
echo "Waiting for VNC server..."
for i in $(seq 1 10); do
  if lsof -i :"$VNC_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

# VNC サーバーの起動確認
if lsof -i :"$VNC_PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  echo "VNC server started on port $VNC_PORT"
else
  echo "ERROR: VNC server failed to start"
  echo "Log:"
  cat /tmp/trollvnc-sim-preview.log 2>/dev/null
  exit 1
fi

# ---------- Tailscale IP 取得 ----------
TAILSCALE_CMD="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if [ -x "$TAILSCALE_CMD" ]; then
  TAILSCALE_IP=$("$TAILSCALE_CMD" ip -4 2>/dev/null || true)
elif command -v tailscale &>/dev/null; then
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
else
  TAILSCALE_IP=""
fi
LOCAL_IP="127.0.0.1"

# ---------- 結果出力 ----------
echo ""
echo "==========================================="
echo "  sim-preview ready"
echo "==========================================="
echo ""
echo "SIMULATOR: $BOOTED_SIM"
echo "VNC_PORT: $VNC_PORT"
echo "LOCAL_VNC: vnc://${LOCAL_IP}:${VNC_PORT}"

if [ -n "$TAILSCALE_IP" ]; then
  echo "TAILSCALE_VNC: vnc://${TAILSCALE_IP}:${VNC_PORT}"
  echo "NOVNC_URL: http://${TAILSCALE_IP}:${HTTP_PORT}/novnc/vnc_lite.html?host=${TAILSCALE_IP}&port=${VNC_PORT}&path=&autoconnect=true"
fi

echo ""
echo "LOG: /tmp/trollvnc-sim-preview.log"
