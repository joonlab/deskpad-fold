#!/bin/bash
# 로컬 확장이 `ray develop` 상주를 요구할 때 쓰는 LaunchAgent 를 이 머신 경로로 채워 설치한다.
#   raycast/scripts/install-dev-agent.sh          # 설치 + load
#   raycast/scripts/install-dev-agent.sh --unload # 내리기
set -eu
LABEL=com.joonlab.raycast-deskpad-fold-dev
DST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [ "${1:-}" = "--unload" ]; then launchctl unload -w "$DST" 2>/dev/null || true; echo "내렸습니다"; exit 0; fi
EXT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NODE="$(command -v node || true)"
[ -n "$NODE" ] || { echo "node 를 찾지 못했습니다"; exit 1; }
case "$EXT_DIR" in "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*)
  echo "주의: $EXT_DIR 는 TCC 보호 폴더라 launchd 의 node 가 멈출 수 있습니다. ~/Developer 등으로 옮기세요." ;; esac
sed -e "s|__NODE__|$NODE|g" -e "s|__EXT_DIR__|$EXT_DIR|g" -e "s|__HOME__|$HOME|g" \
  "$EXT_DIR/scripts/$LABEL.plist.template" > "$DST"
launchctl unload "$DST" 2>/dev/null || true
launchctl load -w "$DST"
echo "설치: $DST"; launchctl list | grep "$LABEL" || true
