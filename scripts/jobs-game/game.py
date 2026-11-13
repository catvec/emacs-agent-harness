#!/usr/bin/env python3
"""A tiny game a playtest drives from outside its own process.

It is deliberately small, and deliberately a real one: it keeps a world
in memory, draws a frame of it to a PNG, and moves the player when a
control file changes.  What it is here for is the shape of the workflow
around it, not the game.

  game.py --dir DIR --port PORT

The world lives in DIR/world.json, so a frame drawn by one process can be
read by another.  A frame is drawn to DIR/frame.png.  The controls are in
DIR/control.json: a list of keys, each applied once per tick and cleared.
A tick happens every TICK seconds, and a frame every FRAME_EVERY ticks.
DIR/status.txt says what the game is doing, and DIR/hiscore.txt is what a
playtest leaves behind after a session is over.

It also answers HTTP on PORT: GET /status says how many ticks it has run
and where the player is, so a caller can tell the game is alive without
reading a file the game writes.
"""

import argparse
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image, ImageDraw

WIDTH, HEIGHT = 320, 200
TICK = 0.05
FRAME_EVERY = 4

KEYS = {"left": (-6, 0), "right": (6, 0), "up": (0, -6), "down": (0, 6)}

SPRITES = [
    ("fox", (250, 150, 90)),
    ("owl", (140, 190, 240)),
    ("frog", (140, 220, 140)),
]


class World:
    def __init__(self, directory):
        self.directory = directory
        self.x, self.y = WIDTH // 2, HEIGHT // 2
        self.ticks = 0
        self.score = 0
        self.caught = []
        self.lock = threading.Lock()
        self.sprites = [
            {"name": name, "colour": colour, "x": 40 + 90 * i, "y": 40 + 40 * i}
            for i, (name, colour) in enumerate(SPRITES)
        ]

    # -- the world -----------------------------------------------------

    def step(self, keys):
        with self.lock:
            self.ticks += 1
            for key in keys:
                dx, dy = KEYS.get(key, (0, 0))
                self.x = min(max(0, self.x + dx), WIDTH - 16)
                self.y = min(max(0, self.y + dy), HEIGHT - 16)
            for sprite in self.sprites:
                if sprite in self.caught:
                    continue
                if abs(sprite["x"] - self.x) < 20 and abs(sprite["y"] - self.y) < 20:
                    self.caught.append(sprite)
                    self.score += 10
            self.save()

    def save(self):
        state = {
            "x": self.x,
            "y": self.y,
            "ticks": self.ticks,
            "score": self.score,
            "caught": [s["name"] for s in self.caught],
            "sprites": self.sprites,
        }
        _write_json(os.path.join(self.directory, "world.json"), state)
        _write_text(
            os.path.join(self.directory, "status.txt"),
            "tick %d · score %d · at %d,%d · caught %s\n"
            % (self.ticks, self.score, self.x, self.y,
               ",".join(state["caught"]) or "nothing"),
        )

    def draw(self):
        image = Image.new("RGB", (WIDTH, HEIGHT), (18, 24, 38))
        draw = ImageDraw.Draw(image)
        for y in range(0, HEIGHT, 16):
            draw.line([(0, y), (WIDTH, y)], fill=(24, 32, 50))
        for sprite in self.sprites:
            if sprite in self.caught:
                continue
            draw.rectangle(
                [sprite["x"], sprite["y"], sprite["x"] + 14, sprite["y"] + 14],
                fill=sprite["colour"],
            )
            draw.text((sprite["x"], sprite["y"] - 10), sprite["name"], fill=(230, 230, 230))
        draw.rectangle([self.x, self.y, self.x + 14, self.y + 14], fill=(250, 240, 120))
        draw.text((6, 6), "score %d" % self.score, fill=(255, 255, 255))
        draw.text((6, HEIGHT - 14), "tick %d" % self.ticks, fill=(180, 200, 220))
        # Written beside the frame and moved onto it, as the world and the
        # status are: a later call copies the frame while the game draws
        # the next one, and a copy taken mid-write is a truncated PNG.
        frame = os.path.join(self.directory, "frame.png")
        temporary = frame + ".tmp"
        # The format is named because the temporary file's name does not
        # end in .png: Pillow reads the format from the extension.
        image.save(temporary, format="PNG")
        os.replace(temporary, frame)


def _write_text(path, text):
    temporary = path + ".tmp"
    with open(temporary, "w") as handle:
        handle.write(text)
    os.replace(temporary, path)


def _write_json(path, value):
    _write_text(path, json.dumps(value))


def _read_keys(directory):
    path = os.path.join(directory, "control.json")
    try:
        with open(path) as handle:
            keys = json.load(handle).get("keys") or []
    except (OSError, ValueError):
        return []
    if keys:
        # Cleared, so a key pressed once is applied once.
        _write_json(path, {"keys": []})
    return [k for k in keys if not isinstance(k, (list, tuple))]


def _serve(world, port):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps(
                {"ticks": world.ticks, "score": world.score, "x": world.x, "y": world.y}
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()

    os.makedirs(args.dir, exist_ok=True)
    world = World(args.dir)
    world.save()
    world.draw()
    _serve(world, args.port)

    while True:
        import time

        world.step(_read_keys(args.dir))
        if world.ticks % FRAME_EVERY == 0:
            world.draw()
        time.sleep(TICK)


if __name__ == "__main__":
    main()
