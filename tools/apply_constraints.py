"""살아 있는 Deskreen 스트림의 캡처 상한을 바꾼다: python3 apply_constraints.py <maxW> <maxH>"""
import json, sys
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "webrtc_stats.py")).read().split("proto =")[0])
proto = call("Runtime.evaluate", {"expression": "RTCPeerConnection.prototype"})["result"]["objectId"]
arr = call("Runtime.queryObjects", {"prototypeObjectId": proto})["objects"]["objectId"]
fn = """async function(w,h){ const out=[]; for (const pc of this) { if (pc.connectionState!=='connected') continue;
  for (const se of pc.getSenders()) { if (!se.track) continue;
    await se.track.applyConstraints({width:{min:Math.round(w/2),max:w},height:{min:Math.round(h/2),max:h},frameRate:{min:15,max:60}});
    out.push(se.track.getSettings()); } } return out; }"""
r = call("Runtime.callFunctionOn", {"objectId": arr, "functionDeclaration": fn, "arguments": [{"value": int(sys.argv[1])}, {"value": int(sys.argv[2])}], "awaitPromise": True, "returnByValue": True})
print(json.dumps(r["result"].get("value", r), indent=1))
