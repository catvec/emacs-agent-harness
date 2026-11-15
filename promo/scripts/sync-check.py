#!/usr/bin/env python3
"""Does the picture hit when the sound hits?

Reads the finished MP4 (the video and the audio exactly as muxed), finds for every impact (a module's
UI landing on the Emacs frame) the frame where the picture flashes and the frame where the sound
jumps, and prints how far apart they are.  The film's clock is src/timeline.ts: build/cues.json
(`npm run cues` writes it) is its export.

    python3 -I scripts/sync-check.py [output/emacs-agent-harness-promo.mp4]

Exit status 1 when an impact is more than one frame off, or the file has not got the shape the
film should have (1920x1080, 30 fps, the frames the timeline says, audio from the first frame).
Only the standard library and ffmpeg are used.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
mp4 = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "output", "emacs-agent-harness-promo.mp4")
cues = json.load(open(os.path.join(ROOT, "build", "cues.json")))
FPS = cues["fps"]


def run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    return r.stdout + r.stderr


# --- the shape of the file ---------------------------------------------------------------
probe = json.loads(
    run(["ffprobe", "-v", "error", "-count_frames", "-show_entries",
         "stream=codec_type,codec_name,width,height,r_frame_rate,nb_read_frames,start_time,duration",
         "-of", "json", mp4])
)
video = next(s for s in probe["streams"] if s["codec_type"] == "video")
audio = next(s for s in probe["streams"] if s["codec_type"] == "audio")
problems = []
print(f"video: {video['codec_name']} {video['width']}x{video['height']} {video['r_frame_rate']} fps, "
      f"{video['nb_read_frames']} frames, {float(video['duration']):.3f} s")
print(f"audio: {audio['codec_name']}, starts at {float(audio['start_time']):.3f} s, {float(audio['duration']):.3f} s")
if (video["width"], video["height"]) != (1920, 1080):
    problems.append("not 1920x1080")
if video["r_frame_rate"] != "30/1":
    problems.append("not 30 fps")
if int(video["nb_read_frames"]) != cues["durationFrames"]:
    problems.append(f"{video['nb_read_frames']} frames, expected {cues['durationFrames']}")
if abs(float(audio["start_time"]) - float(video["start_time"])) > 0.05:
    problems.append("audio and video do not start together")

# --- mean luma of every frame ------------------------------------------------------------
out = run(["ffmpeg", "-v", "error", "-i", mp4, "-an", "-vf",
           "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-", "-f", "null", "-"])
luma = [float(m) for m in re.findall(r"lavfi\.signalstats\.YAVG=([0-9.]+)", out)]
print(f"{len(luma)} frames measured")

# --- audio level of every frame period (1600 samples at 48 kHz) --------------------------
out = run(["ffmpeg", "-v", "error", "-i", mp4, "-vn", "-ac", "1", "-af",
           "aresample=48000,asetnsamples=n=1600:p=0,astats=metadata=1:reset=1,"
           "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-", "-f", "null", "-"])
rms = []
for m in re.findall(r"lavfi\.astats\.Overall\.RMS_level=(-?[0-9.]+|-inf|inf)", out):
    rms.append(-120.0 if "inf" in m else max(-120.0, float(m)))
print(f"{len(rms)} audio periods measured")


def jump(series, frame, radius=4, floor=None):
    """The frame near `frame` where the series rises most from the frame before."""
    best, best_d = None, 0.0
    for f in range(max(1, frame - radius), min(len(series) - 1, frame + radius) + 1):
        d = series[f] - series[f - 1]
        if d > best_d:
            best, best_d = f, d
    return best, best_d


targets = [(c["frame"], f"impact: {c.get('label', '')}") for c in cues["cues"] if c["kind"] == "impact"]

print("\n target                          frame   flash   sound   picture-sound")
worst = 0
for frame, name in sorted(targets):
    v, vd = jump(luma, frame, 3)
    a, ad = jump(rms, frame, 3)
    if v is None or a is None:
        print(f" {name:32s}{frame:5d}   (no clear flash or onset)")
        continue
    delta = v - a
    worst = max(worst, abs(delta))
    flag = "" if abs(delta) <= 1 else "   <-- off"
    print(f" {name:32s}{frame:5d}   {v:5d}   {a:5d}   {delta:+d} frame(s){flag}")
    if abs(delta) > 1:
        problems.append(f"{name}: picture {v}, sound {a}")

print(f"\nworst difference: {worst} frame(s) of {len(targets)} impact(s)")
if problems:
    print("PROBLEMS:\n  " + "\n  ".join(problems))
    sys.exit(1)
print("OK: the picture and the sound hit together.")
