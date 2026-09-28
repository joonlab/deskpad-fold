"""Deskreen 메인 렌더러에 JS 식을 평가한다: echo 'document.title' | python3 cdp_eval.py"""
import json, os, sys, urllib.request, websocket
PORT = int(os.environ.get("DESKREEN_DEBUG_PORT", "9333"))
def page_ws():
    for t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json")):
        if t["type"] == "page" and t["url"].endswith("/renderer/index.html"):
            return t["webSocketDebuggerUrl"]
def ev(expr):
    ws = websocket.create_connection(page_ws(), timeout=40)
    ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr, "awaitPromise": True, "returnByValue": True}}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == 1:
            ws.close(); return r["result"]
if __name__ == "__main__":
    print(json.dumps(ev(sys.stdin.read()), ensure_ascii=False, indent=1)[:6000])
