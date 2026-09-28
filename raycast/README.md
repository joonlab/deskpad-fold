# DeskPad Fold — Raycast 확장

메뉴바 앱 `DeskPad Fold`(`/Applications/DeskPad Fold.app`)를 Raycast에서 조종합니다. 앱 설명은 레포 루트의 `README.md`에 있습니다.

| 명령 | 모드 | 동작 |
|---|---|---|
| DeskPad Fold | view | 상태(연결 기기·방향·해상도) + 폰 연결·방향 전환·링크 복사·연결 끊기·종료 + 해상도 목록 |
| DeskPad 폰 연결 | no-view | 링크를 클립보드에 + 3분간 자동 수락. 이미 대기 중이면 같은 링크 |
| DeskPad 가로/세로 전환 | no-view | 폰 연결 유지 |

앱이 꺼져 있으면 모든 명령이 먼저 앱을 켭니다.

## 구조
- 앱 → 확장: `~/Library/Application Support/DeskPad Fold/status.json` (상태가 바뀔 때마다 앱이 씀, updatedAt 밀리초)
- 확장 → 앱: DistributedNotification `com.joonlab.DeskPadFold.command` (object = `arm|copy|disconnect|portrait|landscape|status|quit|mode:<WxH@scale>`), `tools/deskpad-ctl`과 같은 채널
- 폰 연결 판정: 앱이 먼저 `Deskreen 준비 중…`을 쓰고, 이어 `복사됨: <링크>`(armedUntil 설정) 또는 오류 메시지

## 설치
이 폴더를 TCC 보호 폴더(Desktop·Documents·Downloads) 밖, 예를 들어 `~/Developer/raycast/deskpad-fold`에 두는 것을 권합니다. launchd로 띄운 node는 cwd가 보호 폴더면 멈춥니다.

```bash
npm install
npx ray build -e dist             # Raycast 안정판
RAY_Target=x npx ray build        # Raycast Beta (~/.config/raycast-x/extensions/ 에 설치)
RAY_Target=x npx ray develop      # 새 확장을 Beta 에 처음 등록할 때 한 번 (ready 뜨면 Ctrl+C)
```

Raycast에는 안정판과 Beta 두 종류가 있고, Beta는 `RAY_Target=x`가 있어야 그쪽에 설치됩니다. 틀리면 빌드는 성공하는데 화면이 안 바뀝니다.

## "No enabled command"가 뜨면
로컬 확장이 `ray develop` 상주를 요구하는 경우입니다. 이 머신의 경로로 채운 LaunchAgent를 설치합니다.
```bash
scripts/install-dev-agent.sh            # 템플릿(.plist.template)을 채워 ~/Library/LaunchAgents 에 설치 + load
scripts/install-dev-agent.sh --unload   # 내리기
```
