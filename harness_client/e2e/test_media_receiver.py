#!/usr/bin/env python3
"""Check the local receiver against a peer that offers like the app does.

The app (`voice_webrtc.dart`) offers one audio m-line, two *sendonly* video
m-lines with no track attached, and a `harness-voice` data channel.  It then
reads `getCurrentDirection()` on each video transceiver and offers video only
when that is sendonly or sendrecv.  So the receiver's answer is the thing that
decides whether the app ever attaches a camera.

This is a fast check of that one contract, with aiortc on both ends: it does
not stand in for the emulator run, it keeps a wrong answer from costing one.
It also delivers a real track on the first m-line and a real still on the data
channel, and reads the receiver's own log for both.

    python3 e2e/test_media_receiver.py
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import io
import json
import os
import struct
import sys
import tempfile
import urllib.request
import zlib

import aiohttp
from aiortc import (
    RTCConfiguration,
    RTCPeerConnection,
    RTCSessionDescription,
    VideoStreamTrack,
)

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 8111


def sdp_direction(sdp: str, media: str) -> list[str]:
    """The direction attribute of each m-line of a kind, in order."""
    found = []
    inside = False
    for line in sdp.splitlines():
        if line.startswith("m="):
            inside = line.startswith(f"m={media}")
        elif inside and line in ("a=sendrecv", "a=sendonly", "a=recvonly", "a=inactive"):
            found.append(line[2:])
    return found


def png_bytes() -> bytes:
    """A small real PNG, so the receiver's decision to write it is exercised."""
    width, height = 64, 36
    raw = b"".join(
        b"\x00" + b"".join(bytes([(x * 4) % 256, (y * 7) % 256, 128]) for x in range(width))
        for y in range(height)
    )

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


class PatternTrack(VideoStreamTrack):
    """A moving pattern, so a decoded frame is visibly a picture, not noise.

    It runs on its own clock (aiortc's VideoStreamTrack paces at the frame
    rate) and stops when the peer goes away.
    """

    def __init__(self) -> None:
        super().__init__()

    async def recv(self):
        from PIL import Image

        from aiortc.mediastreams import VideoFrame

        pts, time_base = await self.next_timestamp()
        step = (pts // 3) % 64
        image = Image.new("RGB", (320, 180))
        pixels = image.load()
        for y in range(0, 180, 4):
            for x in range(0, 320, 4):
                shade = 255 if (x + step) % 64 < 32 else 40
                for dy in range(4):
                    for dx in range(4):
                        pixels[x + dx, y + dy] = (shade, 60, 255 - shade)
        frame = VideoFrame.from_ndarray(
            __import__("numpy").array(image), format="rgb24"
        )
        frame.pts = pts
        frame.time_base = time_base
        return frame


async def main() -> int:
    out = tempfile.mkdtemp(prefix="receiver-check-")
    server = await asyncio.create_subprocess_exec(
        sys.executable,
        os.path.join(HERE, "media_receiver.py"),
        "--port",
        str(PORT),
        "--out",
        out,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    await asyncio.sleep(2.0)
    failures: list[str] = []
    result: dict = {}
    peer = None
    try:
        peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        for _ in range(2):
            peer.addTransceiver("video", direction="sendonly")
        channel = peer.createDataChannel("harness-voice")
        offer = await peer.createOffer()
        await peer.setLocalDescription(offer)
        offered = peer.localDescription.sdp
        if sdp_direction(offered, "video") != ["sendonly", "sendonly"]:
            failures.append("the app side did not offer two sendonly video m-lines")

        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"http://127.0.0.1:{PORT}/v1/realtime",
                json={
                    "type": "offer",
                    "protocol": 1,
                    "sdp": offered,
                    "model": "local-test-receiver",
                    "session": "s-1",
                },
            ) as response:
                body = await response.json()
                if response.status != 200:
                    failures.append(f"the receiver refused the offer: {body}")
                    return 1
        answer = body["sdp"]
        directions = sdp_direction(answer, "video")
        if len(directions) != 2:
            failures.append(f"the answer has {len(directions)} video m-lines, not 2")
        if any(direction not in ("recvonly", "sendrecv") for direction in directions):
            failures.append(f"the answer does not take video: {directions}")
        if body.get("media", {}).get("frames") is not True:
            failures.append("the answer does not advertise media.frames")

        # The client posts the offer to whatever address its Live provider was
        # set to, and the driver uses `/voice`.  A receiver that answers only
        # some paths turns the others into a 404, which a run then reads as a
        # provider that took no video.  Every documented path is asked here.
        async with aiohttp.ClientSession() as session:
            for path in ("/voice", "/offer", "/"):
                async with session.post(
                    f"http://127.0.0.1:{PORT}{path}",
                    json={"type": "offer", "protocol": 1, "sdp": offered},
                ) as probe:
                    if probe.status != 200:
                        failures.append(
                            f"the receiver answers {path} with {probe.status}"
                        )
                    else:
                        answered = await probe.json()
                        if not answered.get("sdp"):
                            failures.append(f"{path} got no answer sdp")

        await peer.setRemoteDescription(RTCSessionDescription(sdp=answer, type="answer"))
        await asyncio.sleep(0.5)
        video = []
        for index, transceiver in enumerate(peer.getTransceivers()):
            if transceiver.kind != "video":
                continue
            current = transceiver.currentDirection
            name = "None" if current is None else str(current)
            if "sendonly" not in name.lower() and "sendrecv" not in name.lower():
                failures.append(f"video transceiver {index} reads {name}, not sendonly")
            video.append(transceiver)

        # A track on the first video m-line (attachVideo's replaceTrack) and a
        # still on the data channel (a sampled frame).  A receiver that only
        # negotiates would pass above and fail here.
        track = PatternTrack()
        for _ in range(120):
            if channel.readyState == "open" and str(peer.connectionState) == "connected":
                break
            await asyncio.sleep(0.25)
        if str(peer.connectionState) != "connected":
            failures.append(f"the peer is {peer.connectionState}, not connected")
        video[0].sender.replaceTrack(track)
        for _ in range(60):
            if channel.readyState == "open":
                break
            await asyncio.sleep(0.25)
        if channel.readyState != "open":
            failures.append(f"the data channel is {channel.readyState}, not open")
        else:
            channel.send(
                json.dumps(
                    {
                        "type": "frame",
                        "protocol": 1,
                        "source": "camera",
                        "mimeType": "image/png",
                        "data": base64.b64encode(png_bytes()).decode(),
                        "width": 64,
                        "height": 36,
                        "capturedAt": "2026-01-01T00:00:00.000Z",
                        "sequence": 1,
                    }
                )
            )
        await asyncio.sleep(6)
        track.stop()

        summary = json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health"))
        camera = summary.get("tracks", {}).get("camera") or {}
        if camera.get("frames", 0) < 3:
            failures.append(
                f"the receiver counted {camera.get('frames', 0)} video frames, not ≥3"
            )
        if not camera.get("first_png") or not os.path.exists(camera["first_png"]):
            failures.append("the receiver saved no decoded frame")
        if summary.get("frames") != 1:
            failures.append(f"the receiver took {summary.get('frames')} stills, not 1")
        else:
            still = summary["frame_index"][0]
            if still["png_magic"] != "89504e470d0a1a0a":
                failures.append(f"the still is not a PNG: {still['png_magic']}")
            if still["png_sha256"] != hashlib.sha256(png_bytes()).hexdigest():
                failures.append("the still's bytes are not the ones sent")
        result = {
            "video_directions": directions,
            "media": body.get("media"),
            "track_frames": camera.get("frames"),
            "track_size": [camera.get("width"), camera.get("height")],
            "stills": summary.get("frames"),
            "stills_sha256": (summary.get("frame_index") or [{}])[0].get("png_sha256"),
            "offer_bytes": len(offered),
            "answer_bytes": len(answer),
        }
    finally:
        if peer is not None:
            await peer.close()
        server.terminate()
        await server.wait()
    if failures:
        for failure in failures:
            print("FAIL:", failure)
        return 1
    print(json.dumps({"ok": True, **result}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
