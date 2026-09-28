import { showHUD, showToast, Toast } from "@raycast/api";
import {
  ensureRunning,
  orientationLabel,
  readStatus,
  send,
  waitForStatus,
} from "./deskpad";

export default async function Command() {
  try {
    await ensureRunning();
    const before = await readStatus();
    const target =
      before?.orientation === "portrait" ? "landscape" : "portrait";
    const since = new Date();
    await send(target);
    // The app picks the saved/preferred mode about a second after rotating.
    const after = await waitForStatus(
      (s) => s.orientation === target && s.modes.some((m) => m.current),
      {
        since,
        timeoutMs: 5000,
      },
    );
    await showHUD(
      `${orientationLabel(target)} · ${after?.modeTitle ?? ""}`.trim(),
    );
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "방향 전환 실패",
      message: error instanceof Error ? error.message : String(error),
    });
  }
}
