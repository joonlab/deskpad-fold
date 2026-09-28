import { showHUD, showToast, Toast } from "@raycast/api";
import { connectPhone } from "./deskpad";

export default async function Command() {
  const toast = await showToast({
    style: Toast.Style.Animated,
    title: "Deskreen 준비 중…",
  });
  try {
    const link = await connectPhone();
    await toast.hide();
    await showHUD(`📋 ${link} 복사됨 — 3분 안에 폰에서 여세요`);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "폰 연결 실패";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
