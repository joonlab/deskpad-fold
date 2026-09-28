"""송신 성능 표본: 5초 간격 두 번 읽어 구간 fps·인코딩 ms/프레임·비트레이트·RTT·손실을 낸다 (읽기 전용)."""
import json, time
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "webrtc_stats.py")).read().split("proto =")[0])
proto = call("Runtime.evaluate", {"expression": "RTCPeerConnection.prototype"})["result"]["objectId"]
arr = call("Runtime.queryObjects", {"prototypeObjectId": proto})["objects"]["objectId"]
fn = """async function(){ const out=[]; for (const pc of this) { if (pc.connectionState!=='connected') continue;
 const s=await pc.getStats(); const r={};
 s.forEach(x=>{
  if(x.type==='outbound-rtp'&&x.kind==='video') Object.assign(r,{w:x.frameWidth,h:x.frameHeight,framesEncoded:x.framesEncoded,totalEncodeTime:x.totalEncodeTime,bytesSent:x.bytesSent,qlr:x.qualityLimitationReason,qld:x.qualityLimitationDurations,pli:x.pliCount,nack:x.nackCount,encoder:x.encoderImplementation,targetBitrate:x.targetBitrate,retransmitted:x.retransmittedBytesSent});
  if(x.type==='remote-inbound-rtp'&&x.kind==='video') Object.assign(r,{rtt:x.roundTripTime,lost:x.packetsLost,fractionLost:x.fractionLost,jitter:x.jitter});
  if(x.type==='candidate-pair'&&x.nominated&&x.state==='succeeded') Object.assign(r,{pairRtt:x.currentRoundTripTime,availOut:x.availableOutgoingBitrate});
 }); r.t=performance.now(); out.push(r);} return out;}"""
def sample():
    return call("Runtime.callFunctionOn", {"objectId": arr, "functionDeclaration": fn, "awaitPromise": True, "returnByValue": True})["result"]["value"]
a = sample(); time.sleep(5); b = sample()
for x, y in zip(a, b):
    dt = (y["t"] - x["t"]) / 1000; fr = y["framesEncoded"] - x["framesEncoded"]
    print(f'{y["w"]}x{y["h"]} {y["encoder"]}  fps={fr/dt:.1f}  encode={1000*(y["totalEncodeTime"]-x["totalEncodeTime"])/max(fr,1):.1f}ms/frame  '
          f'bitrate={8*(y["bytesSent"]-x["bytesSent"])/dt/1e6:.1f}Mbps  target={y["targetBitrate"]/1e6:.1f}Mbps  avail={(y.get("availOut") or 0)/1e6:.1f}Mbps')
    print(f'  limit={y["qlr"]} {y["qld"]}  rtt={y.get("rtt")} pairRtt={y.get("pairRtt")} lostTotal={y.get("lost")} fractionLost={y.get("fractionLost")} jitter={y.get("jitter")}')
    print(f'  nack+={y["nack"]-x["nack"]} pli+={y["pli"]-x["pli"]} retransMB+={(y["retransmitted"]-x["retransmitted"])/1e6:.2f}')
