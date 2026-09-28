"""Deskreen 헬퍼 렌더러의 살아 있는 RTCPeerConnection 들에서 송신 영상 해상도·비트레이트를 읽는다 (읽기 전용)."""
import json, os, urllib.request, websocket, time
PORT = int(os.environ.get("DESKREEN_DEBUG_PORT", "9333"))
t = [x for x in json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json")) if "peerConnectionHelper" in x["url"]][0]
ws = websocket.create_connection(t["webSocketDebuggerUrl"], timeout=30)
n = 0
def call(method, params):
    global n; n += 1; ws.send(json.dumps({"id": n, "method": method, "params": params}))
    while True:
        r = json.loads(ws.recv())
        if r.get("id") == n: return r.get("result", r)
proto = call("Runtime.evaluate", {"expression": "RTCPeerConnection.prototype"})["result"]["objectId"]
arr = call("Runtime.queryObjects", {"prototypeObjectId": proto})["objects"]["objectId"]
fn = """async function(){
  const out=[];
  for (const pc of this) {
    if (pc.connectionState !== 'connected') continue;
    const s = await pc.getStats(); const r = {};
    s.forEach(x => {
      if (x.type==='outbound-rtp' && x.kind==='video') Object.assign(r,{frameWidth:x.frameWidth,frameHeight:x.frameHeight,fps:x.framesPerSecond,bytesSent:x.bytesSent,qualityLimitationReason:x.qualityLimitationReason,encoder:x.encoderImplementation, targetBitrate:x.targetBitrate});
      if (x.type==='media-source' && x.kind==='video') Object.assign(r,{sourceWidth:x.width,sourceHeight:x.height});
    });
    const tr = pc.getSenders().map(se=>se.track).filter(Boolean)[0];
    if (tr) { r.trackSettings = tr.getSettings(); r.constraints = tr.getConstraints(); }
    out.push(r);
  }
  return out;
}"""
res = call("Runtime.callFunctionOn", {"objectId": arr, "functionDeclaration": fn, "awaitPromise": True, "returnByValue": True})
print(json.dumps(res.get("result", res).get("value", res), ensure_ascii=False, indent=1))
