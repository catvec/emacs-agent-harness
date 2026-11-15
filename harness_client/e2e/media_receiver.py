#!/usr/bin/env python3
"""A local WebRTC receiver for the live camera and screen tracks the app sends.

It is the other end of the transport the client already speaks
(`harness_client/lib/src/services/voice_webrtc.dart`): an HTTP endpoint that
takes `{"type": "offer", "protocol": 1, "sdp": ...}`, answers with an SDP
whose two video m-lines are `sendrecv`, advertises `media.frames`, and then
receives what the app sends:

  * the video RTP of each attached source (decoded frames, counts, arrival
    times, and a PNG of the first and last frame of each source);
  * `frame` messages on the `harness-voice` data channel, the bounded stills
    the app sends for a provider whose answer says `media.frames`.

It is NOT a production receiver.  It is a local test peer: it stands in for a
sidecar that accepts a video track, so the app's real capture, encoding and
DTLS/SRTP transport can be observed end to end.  Nothing here is a claim that
a real provider accepts video; see docs/live-video-screen-share.md.

It is deliberately small and dependency-light: aiortc does the SDP, ICE, DTLS
and SRTP, and this file does the observation.

    python3 e2e/media_receiver.py --port 8099 --out /tmp/media-e2e
    python3 e2e/media_receiver.py --port 8098 --out /tmp/media-e2e --mode frames

`--mode tracks` (the default) accepts both of the app's sendonly video m-lines,
which is what a video sidecar does.  `--mode frames` answers them `inactive`
and advertises only `media.frames`, which is what an image-input provider does:
the app may then sample stills but must never show a live track.

It prints one JSON object per event on stdout and appends the same to
`<out>/receiver.jsonl`; `<out>/summary.json` holds the totals when it is asked
to stop with SIGTERM or SIGINT.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import signal
import sys
import time
from dataclasses import dataclass, field

from aiohttp import web
from aiortc import RTCPeerConnection, RTCSessionDescription, MediaStreamTrack
from aiortc.mediastreams import MediaStreamError

# One receiver, one log.  aiohttp and aiortc both log at INFO on the root
# logger; that would drown the JSON this file is read for.
import logging

logging.basicConfig(level=logging.ERROR)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + (
        ".%03dZ" % (time.time_ns() // 1_000_000 % 1000)
    )


@dataclass
class Receiver:
    out: str
    mode: str = "tracks"
    started: float = field(default_factory=time.time)
    # Every data-channel frame, in arrival order.
    frames: list[dict] = field(default_factory=list)
    # Per-source track observations.
    tracks: dict[str, dict] = field(default_factory=dict)
    # Every signalling request, so a run can show what the app asked for.
    offers: list[dict] = field(default_factory=list)
    peer_count: int = 0

    def emit(self, event: dict) -> None:
        event.setdefault("at", now_iso())
        event.setdefault("t", round(time.time() - self.started, 3))
        line = json.dumps(event, sort_keys=True)
        print(line, flush=True)
        with open(os.path.join(self.out, "receiver.jsonl"), "a") as log:
            log.write(line + "\n")

    def track(self, label: str) -> dict:
        entry = self.tracks.get(label)
        if entry is None:
            entry = {
                "label": label,
                "accepted": True,
                "frames": 0,
                "bytes": 0,
                "first_at": None,
                "last_at": None,
                "first_epoch": None,
                "last_epoch": None,
                "first_pts": None,
                "last_pts": None,
                "samples": [],
                "width": None,
                "height": None,
                "max_gap_ms": 0.0,
                "gaps": [],
                "first_png": None,
                "last_png": None,
            }
            self.tracks[label] = entry
        return entry


class CountingTrack(MediaStreamTrack):
    """Count what arrives, sample the first and last frame, measure gaps.

    aiortc hands the decoded frame here; the frames come from the app's real
    VP8 encoder over DTLS/SRTP, so a counted frame is a delivered frame.
    """

    kind = "video"

    def __init__(self, receiver: Receiver, label: str, upstream: MediaStreamTrack):
        super().__init__()
        self._receiver = receiver
        self._label = label
        self._upstream = upstream
        self._last_wall = None
        self._last_pts = None

    async def recv(self):
        frame = await self._upstream.recv()
        entry = self._receiver.track(self._label)
        wall = time.time()
        pts = float(frame.pts) if frame.pts is not None else None
        entry["frames"] += 1
        entry["width"] = frame.width
        entry["height"] = frame.height
        if len(entry["samples"]) < 400:
            entry["samples"].append(
                {"epoch": round(wall, 4), "pts": pts, "frames": entry["frames"]}
            )
        if entry["first_at"] is None:
            entry["first_at"] = now_iso()
            entry["first_epoch"] = round(wall, 4)
            entry["first_pts"] = pts
            entry["first_png"] = self._save(frame, "first")
            self._receiver.emit(
                {
                    "event": "track-first-frame",
                    "source": self._label,
                    "width": frame.width,
                    "height": frame.height,
                    "pts": pts,
                    "png": entry["first_png"],
                }
            )
        if self._last_pts is not None and pts is not None:
            # RTP timestamps are milliseconds for video; the difference in
            # presentation time is the frame interval the sender produced.
            gap_ms = abs(pts - self._last_pts)
            # A pause shows as a large gap; keep every gap over a second.
            if gap_ms > 1000:
                entry["gaps"].append({"after_frame": entry["frames"] - 1, "ms": gap_ms})
            if self._last_wall is not None:
                wall_gap = (wall - self._last_wall) * 1000.0
                entry["max_gap_ms"] = max(entry["max_gap_ms"], round(wall_gap, 1))
        entry["last_at"] = now_iso()
        entry["last_epoch"] = round(wall, 4)
        entry["last_pts"] = pts
        entry["bytes"] += frame.width * frame.height * 3 // 2
        # The last frame is kept, not encoded here: `to_image().save()` is
        # synchronous and this runs on the event loop that also answers the
        # sender's STUN consent checks.  Encoding every frame stalls those for
        # seconds, and the peer connection is then torn down as unreachable
        # minutes into a share -- a receiver bug that looks exactly like a
        # client that stopped sending.
        entry["last_frame"] = frame
        self._last_wall = wall
        self._last_pts = pts
        return frame

    def _save(self, frame, which: str) -> str:
        path = os.path.join(self._receiver.out, f"{self._label}-{which}.png")
        try:
            frame.to_image().save(path)
        except Exception:  # a codec the local PIL cannot write
            return ""
        return path


async def offer(request: web.Request) -> web.Response:
    receiver: Receiver = request.app["receiver"]
    body = await request.json()
    if body.get("type") != "offer":
        return web.json_response({"error": "expected an offer"}, status=400)
    sdp = body.get("sdp")
    if not isinstance(sdp, str) or not sdp:
        return web.json_response({"error": "expected sdp"}, status=400)
    receiver.peer_count += 1
    peer_no = receiver.peer_count
    receiver.offers.append(
        {
            "peer": peer_no,
            "at": now_iso(),
            "protocol": body.get("protocol"),
            "model": body.get("model"),
            "session": body.get("session"),
            "title": body.get("title"),
            "cwd": body.get("cwd"),
            "mode": receiver.mode,
            "video_mlines": sdp.count("m=video"),
            "audio_mlines": sdp.count("m=audio"),
            "sdp_sha256": __import__("hashlib").sha256(sdp.encode()).hexdigest(),
        }
    )
    receiver.emit(
        {
            "event": "offer",
            "peer": peer_no,
            "protocol": body.get("protocol"),
            "model": body.get("model"),
            "session": body.get("session"),
            "video_mlines": sdp.count("m=video"),
            "audio_mlines": sdp.count("m=audio"),
            "sdp_bytes": len(sdp),
        }
    )
    pc = RTCPeerConnection()
    request.app["peers"].append(pc)
    labels = ["camera", "screen"]
    counter = {"video": 0}

    @pc.on("track")
    def on_track(track: MediaStreamTrack) -> None:
        if track.kind != "video":
            receiver.emit({"event": "track-ignored", "peer": peer_no, "kind": track.kind})
            return
        label = labels[min(counter["video"], len(labels) - 1)]
        counter["video"] += 1
        receiver.emit(
            {
                "event": "track-started",
                "peer": peer_no,
                "source": label,
                "kind": track.kind,
            }
        )
        wrapped = CountingTrack(receiver, label, track)
        request.app["tasks"].append(asyncio.ensure_future(_drain(receiver, label, wrapped)))

    @pc.on("datachannel")
    def on_datachannel(channel) -> None:
        receiver.emit({"event": "data-channel", "peer": peer_no, "label": channel.label})

        @channel.on("message")
        def on_message(message: str) -> None:
            _frame_message(receiver, peer_no, message)

    await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="offer"))
    # The answer accepts both of the app's sendonly video m-lines, which is
    # the negotiation branch a real video sidecar would take.
    answer = await pc.createAnswer()
    await pc.setLocalDescription(answer)
    local = pc.localDescription
    if local is None or not local.sdp:
        return web.json_response({"error": "no answer"}, status=500)
    answer_sdp = local.sdp
    if receiver.mode == "frames":
        # An image-input provider: it takes no video.  The app reads each
        # video transceiver's current direction after the answer, so the
        # m-lines must say so, not merely the JSON.
        answer_sdp = _refuse_video(answer_sdp)
    receiver.emit(
        {
            "event": "answer",
            "peer": peer_no,
            "mode": receiver.mode,
            "sendrecv_video": answer_sdp.count("a=sendrecv"),
            "recvonly_video": answer_sdp.count("a=recvonly"),
            "inactive_video": answer_sdp.count("a=inactive"),
            "sdp_bytes": len(answer_sdp),
        }
    )
    return web.json_response(
        {
            "type": "answer",
            "sdp": answer_sdp,
            # What the client reads to decide whether it may sample stills.
            "media": {
                "tracks": receiver.mode == "tracks",
                "frames": True,
                "maxFps": 1,
            },
        }
    )


def _refuse_video(sdp: str) -> str:
    """Answer every video m-line `inactive`: this peer takes no video."""
    out = []
    inside = False
    for line in sdp.splitlines():
        if line.startswith("m="):
            inside = line.startswith("m=video")
        if inside and line in ("a=sendrecv", "a=recvonly", "a=sendonly"):
            out.append("a=inactive")
            continue
        out.append(line)
    return "\r\n".join(out) + "\r\n"


async def _drain(receiver: Receiver, label: str, track: MediaStreamTrack) -> None:
    try:
        while True:
            await track.recv()
    except (MediaStreamError, asyncio.CancelledError):
        receiver.emit({"event": "track-ended", "source": label})
    except Exception as error:  # a decode error is worth saying, not dying on
        receiver.emit({"event": "track-error", "source": label, "error": str(error)})


def _frame_message(receiver: Receiver, peer_no: int, message) -> None:
    """A `frame` data-channel message, as voice_webrtc.dart's harnessFrameMessage."""
    try:
        body = json.loads(message)
    except (TypeError, ValueError):
        receiver.emit({"event": "data-message", "peer": peer_no, "bytes": len(str(message))})
        return
    if not isinstance(body, dict) or body.get("type") != "frame":
        receiver.emit(
            {
                "event": "data-message",
                "peer": peer_no,
                "type": body.get("type") if isinstance(body, dict) else None,
            }
        )
        return
    data = body.get("data") or ""
    png = b""
    try:
        png = base64.b64decode(data, validate=False)
    except Exception:
        pass
    index = len(receiver.frames)
    path = os.path.join(receiver.out, f"frame-{index:03d}-{body.get('source')}.png")
    if png:
        with open(path, "wb") as handle:
            handle.write(png)
    entry = {
        "index": index,
        "peer": peer_no,
        "at": now_iso(),
        "source": body.get("source"),
        "mime": body.get("mimeType"),
        "width": body.get("width"),
        "height": body.get("height"),
        "captured_at": body.get("capturedAt"),
        "sequence": body.get("sequence"),
        "protocol": body.get("protocol"),
        "png_bytes": len(png),
        "png_sha256": __import__("hashlib").sha256(png).hexdigest(),
        "png_magic": png[:8].hex(),
        "path": path,
    }
    receiver.frames.append(entry)
    receiver.emit({"event": "frame", **{k: v for k, v in entry.items() if k != "path"}})


async def stats(request: web.Request) -> web.Response:
    """WebRTC's own inbound statistics for each peer, as aiortc reports them."""
    out = []
    for index, peer in enumerate(request.app["peers"]):
        try:
            report = await peer.getStats()
        except Exception as error:  # a closed peer reports nothing
            out.append({"peer": index + 1, "error": str(error)})
            continue
        inbound = []
        for entry in report.values():
            if getattr(entry, "type", "") != "inbound-rtp":
                continue
            inbound.append(
                {
                    "kind": getattr(entry, "kind", ""),
                    "packetsReceived": getattr(entry, "packets_received", None),
                    "packetsLost": getattr(entry, "packets_lost", None),
                    "jitter": getattr(entry, "jitter", None),
                    "bytesReceived": getattr(entry, "bytes_received", None),
                    "framesDecoded": getattr(entry, "frames_decoded", None),
                    "frameWidth": getattr(entry, "frame_width", None),
                    "frameHeight": getattr(entry, "frame_height", None),
                    "fps": getattr(entry, "frames_per_second", None),
                }
            )
        out.append({"peer": index + 1, "inbound": inbound})
    return web.json_response({"peers": out})


async def health(request: web.Request) -> web.Response:
    receiver: Receiver = request.app["receiver"]
    return web.json_response(summary(receiver))


def summary(receiver: Receiver) -> dict:
    # The last frame of each source is encoded here, once, when a run
    # reads the summary: the picture of what the app's encoder produced,
    # without the event loop paying for it on every frame.
    for entry in receiver.tracks.values():
        frame = entry.pop("last_frame", None)
        if frame is not None and not entry.get("last_png"):
            label = entry["label"]
            path = os.path.join(receiver.out, f"{label}-last.png")
            try:
                frame.to_image().save(path)
                entry["last_png"] = path
            except Exception:  # a codec the local PIL cannot write
                entry["last_png"] = ""
    return {
        "mode": receiver.mode,
        "started": receiver.started,
        "peers": receiver.peer_count,
        "offers": receiver.offers,
        "frames": len(receiver.frames),
        "frame_index": receiver.frames,
        "tracks": {
            label: {
                key: value
                for key, value in entry.items()
                if key not in ("samples", "last_frame")
            }
            for label, entry in receiver.tracks.items()
        },
        "track_samples": {
            label: entry["samples"] for label, entry in receiver.tracks.items()
        },
        "wall_clock": now_iso(),
    }


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--out", default="/tmp/media-e2e")
    parser.add_argument("--mode", choices=("tracks", "frames"), default="tracks")
    arguments = parser.parse_args()
    os.makedirs(arguments.out, exist_ok=True)
    receiver = Receiver(out=arguments.out, mode=arguments.mode)
    app = web.Application()
    app["receiver"] = receiver
    app["peers"] = []
    app["tasks"] = []
    # Every path a generic signalling endpoint is given: the client posts the
    # offer to whatever address its Live provider was set to, and a receiver
    # that answers only some of them turns the others into a 404 the run then
    # reads as a provider that took no video.
    for path in ("/v1/realtime", "/realtime", "/voice", "/offer", "/"):
        app.router.add_post(path, offer)
    app.router.add_get("/health", health)
    app.router.add_get("/stats", stats)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", arguments.port)
    await site.start()
    receiver.emit(
        {
            "event": "listening",
            "port": arguments.port,
            "out": arguments.out,
            "mode": arguments.mode,
        }
    )

    stopping = asyncio.Event()

    def stop(*_args) -> None:
        stopping.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop)
    await stopping.wait()

    for pc in app["peers"]:
        await pc.close()
    for task in app["tasks"]:
        task.cancel()
    await runner.cleanup()
    with open(os.path.join(arguments.out, "summary.json"), "w") as handle:
        json.dump(summary(receiver), handle, indent=2, sort_keys=True)
    receiver.emit(
        {
            "event": "stopped",
            "peers": receiver.peer_count,
            "frames": len(receiver.frames),
            "tracks": {k: v["frames"] for k, v in receiver.tracks.items()},
        }
    )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
