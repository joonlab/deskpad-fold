import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

/** Written by the DeskPad Fold menu bar app on every state change. */
export const STATUS_PATH = join(
  homedir(),
  "Library/Application Support/DeskPad Fold/status.json",
);
const APP_NAME = "DeskPad Fold";
const NOTIFICATION = "com.joonlab.DeskPadFold.command";

export interface Mode {
  key: string;
  title: string;
  current: boolean;
}

export interface Device {
  ip: string;
  os: string;
  browser: string;
  width: number;
  height: number;
}

export interface Status {
  orientation: "portrait" | "landscape";
  mode: string;
  modeTitle: string;
  modes: Mode[];
  devices: Device[];
  armedUntil: string | null;
  deskreenRunning: boolean;
  link: string | null;
  message: string | null;
  updatedAt: string;
}

export async function isRunning(): Promise<boolean> {
  try {
    await run("/usr/bin/pgrep", ["-x", APP_NAME]);
    return true;
  } catch {
    return false;
  }
}

export async function readStatus(): Promise<Status | null> {
  try {
    return JSON.parse(await readFile(STATUS_PATH, "utf8")) as Status;
  } catch {
    return null;
  }
}

/** Same channel as `deskpad-ctl`: arm | copy | disconnect | portrait | landscape | status | quit | mode:<key> */
export async function send(command: string): Promise<void> {
  const script =
    "ObjC.import('Foundation');" +
    "$.NSDistributedNotificationCenter.defaultCenter" +
    `.postNotificationNameObjectUserInfoDeliverImmediately(${JSON.stringify(NOTIFICATION)}, ${JSON.stringify(command)}, $(), true)`;
  await run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script]);
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** Polls the status file until `predicate` holds for a snapshot written after `since`. */
export async function waitForStatus(
  predicate: (status: Status) => boolean,
  { since = new Date(0), timeoutMs = 15000 } = {},
): Promise<Status | null> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const status = await readStatus();
    if (status && new Date(status.updatedAt) >= since && predicate(status))
      return status;
    await sleep(300);
  }
  return null;
}

/** Launches the menu bar app if needed and waits until it has published its state. */
export async function ensureRunning(): Promise<void> {
  if (await isRunning()) return;
  const since = new Date(Date.now() - 1000);
  await run("/usr/bin/open", ["-a", APP_NAME]);
  if (
    !(await waitForStatus((s) => s.modes.some((m) => m.current), {
      since,
      timeoutMs: 10000,
    }))
  ) {
    throw new Error(`${APP_NAME} 이 응답하지 않습니다`);
  }
}

export async function quit(): Promise<void> {
  await send("quit");
}

export const PREPARING = "Deskreen 준비 중…";

/** Arms auto accept and resolves with the copied viewer link. */
export async function connectPhone(): Promise<string> {
  await ensureRunning();
  const armed = (s: Status | null) =>
    !!s?.armedUntil &&
    new Date(s.armedUntil) > new Date() &&
    !!s.link &&
    !!s.message?.startsWith("복사됨");
  // Already waiting for a phone: the app ignores a second arm, so hand back the same link.
  const current = await readStatus();
  if (armed(current)) return current!.link!;

  const since = new Date(Date.now() - 500);
  await send("arm");
  // The app first publishes PREPARING, then either "복사됨: <link>" (armed) or an error message.
  let sawPreparing = false;
  const status = await waitForStatus(
    (s) => {
      if (s.message === PREPARING) sawPreparing = true;
      return armed(s) || (sawPreparing && s.message !== PREPARING);
    },
    { since, timeoutMs: 40000 },
  );
  if (armed(status)) return status!.link!;
  throw new Error(status?.message ?? "Deskreen 링크를 받지 못했습니다");
}

export function orientationLabel(orientation: Status["orientation"]): string {
  return orientation === "portrait" ? "세로" : "가로";
}
