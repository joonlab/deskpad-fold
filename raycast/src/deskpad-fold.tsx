import {
  Action,
  ActionPanel,
  Clipboard,
  Color,
  Icon,
  List,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import {
  connectPhone,
  isRunning,
  orientationLabel,
  quit,
  readStatus,
  send,
  Status,
  ensureRunning,
  waitForStatus,
} from "./deskpad";

export default function Command() {
  const [status, setStatus] = useState<Status | null>(null);
  const [running, setRunning] = useState<boolean | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const refresh = useCallback(async () => {
    setIsLoading(true);
    const alive = await isRunning();
    setRunning(alive);
    if (alive) {
      // Ask the app to re-read Deskreen's device list, then take the fresh snapshot.
      const since = new Date();
      await send("status");
      setStatus(
        (await waitForStatus(() => true, { since, timeoutMs: 3000 })) ??
          (await readStatus()),
      );
    } else {
      setStatus(null);
    }
    setIsLoading(false);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function perform(title: string, action: () => Promise<void>) {
    const toast = await showToast({ style: Toast.Style.Animated, title });
    try {
      await action();
      await toast.hide();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = `${title} 실패`;
      toast.message = error instanceof Error ? error.message : String(error);
    }
    await refresh();
  }

  if (running === false) {
    return (
      <List isLoading={isLoading}>
        <List.Item
          title="DeskPad Fold 켜기"
          subtitle="꺼져 있음"
          icon={{ source: Icon.Power, tintColor: Color.SecondaryText }}
          actions={
            <ActionPanel>
              <Action
                title="켜기"
                icon={Icon.Power}
                onAction={() => perform("DeskPad Fold 켜는 중…", ensureRunning)}
              />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  const device = status?.devices[0];
  const armed =
    !!status?.armedUntil && new Date(status.armedUntil) > new Date();
  const isPortrait = status?.orientation === "portrait";

  return (
    <List isLoading={isLoading} searchBarPlaceholder="동작·해상도 검색">
      <List.Section title="상태">
        <List.Item
          title={
            device
              ? "폰 연결됨"
              : armed
                ? "폰 접속 대기 중"
                : "연결된 기기 없음"
          }
          subtitle={
            device
              ? `${device.ip} · ${device.os} · ${device.width}×${device.height}`
              : (status?.link ?? "")
          }
          icon={{
            source: device
              ? Icon.CheckCircle
              : armed
                ? Icon.Clock
                : Icon.Circle,
            tintColor: device
              ? Color.Green
              : armed
                ? Color.Orange
                : Color.SecondaryText,
          }}
          accessories={[
            {
              text: status
                ? `${orientationLabel(status.orientation)} · ${status.modeTitle}`
                : "",
            },
          ]}
          actions={
            <ActionPanel>
              <Action
                title="새로고침"
                icon={Icon.ArrowClockwise}
                onAction={refresh}
              />
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section title="동작">
        <List.Item
          title={device ? "폰 다시 연결" : "폰 연결"}
          subtitle={
            device ? "지금 연결을 끊고 새 링크" : "링크 복사 + 3분간 자동 수락"
          }
          icon={Icon.Mobile}
          actions={
            <ActionPanel>
              <Action
                title="폰 연결"
                icon={Icon.Mobile}
                onAction={() =>
                  perform("Deskreen 준비 중…", async () => {
                    const link = await connectPhone();
                    await showHUD(`📋 ${link} 복사됨 — 3분 안에 폰에서 여세요`);
                  })
                }
              />
            </ActionPanel>
          }
        />
        <List.Item
          title={isPortrait ? "가로로 전환" : "세로로 전환"}
          subtitle="폰 연결 유지"
          icon={isPortrait ? Icon.Monitor : Icon.Mobile}
          actions={
            <ActionPanel>
              <Action
                title={isPortrait ? "가로로 전환" : "세로로 전환"}
                icon={Icon.RotateClockwise}
                onAction={() =>
                  perform("방향 전환 중…", async () => {
                    const target = isPortrait ? "landscape" : "portrait";
                    const since = new Date();
                    await send(target);
                    await waitForStatus(
                      (s) =>
                        s.orientation === target &&
                        s.modes.some((m) => m.current),
                      {
                        since,
                        timeoutMs: 5000,
                      },
                    );
                  })
                }
              />
            </ActionPanel>
          }
        />
        {status?.link && (
          <List.Item
            title="링크 다시 복사"
            subtitle={status.link}
            icon={Icon.Link}
            actions={
              <ActionPanel>
                <Action.CopyToClipboard
                  title="링크 복사"
                  content={status.link}
                />
              </ActionPanel>
            }
          />
        )}
        {device && (
          <List.Item
            title="연결 끊기"
            icon={Icon.XMarkCircle}
            actions={
              <ActionPanel>
                <Action
                  title="연결 끊기"
                  icon={Icon.XMarkCircle}
                  style={Action.Style.Destructive}
                  onAction={() =>
                    perform("연결 끊는 중…", () => send("disconnect"))
                  }
                />
              </ActionPanel>
            }
          />
        )}
        <List.Item
          title="DeskPad Fold 종료"
          subtitle="가상 화면이 사라지고 폰 연결도 끊깁니다"
          icon={Icon.Power}
          actions={
            <ActionPanel>
              <Action
                title="종료"
                icon={Icon.Power}
                style={Action.Style.Destructive}
                onAction={() => perform("종료 중…", quit)}
              />
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section
        title={`해상도 (${status ? orientationLabel(status.orientation) : ""})`}
      >
        {status?.modes.map((mode) => (
          <List.Item
            key={mode.key}
            title={mode.title}
            icon={
              mode.current
                ? { source: Icon.CheckCircle, tintColor: Color.Green }
                : Icon.Circle
            }
            actions={
              <ActionPanel>
                <Action
                  title="이 해상도로"
                  icon={Icon.Checkmark}
                  onAction={() =>
                    perform("해상도 변경 중…", async () => {
                      const since = new Date();
                      await send(`mode:${mode.key}`);
                      await waitForStatus((s) => s.mode === mode.key, {
                        since,
                        timeoutMs: 3000,
                      });
                    })
                  }
                />
                <Action
                  title="키 복사"
                  icon={Icon.Clipboard}
                  onAction={() => Clipboard.copy(mode.key)}
                  shortcut={{ modifiers: ["cmd"], key: "c" }}
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );
}
