#!/usr/bin/env python3
"""Compare a frame the receiver decoded with a screenshot of the device.

The screen-share run takes a frame from the WebRTC track and a `screencap` of
the same device at nearly the same moment.  Both show the same screen -- the
app itself, since this app does not hide its own window from its own share --
so the two pictures should agree.  That is what makes "the receiver got the
phone's screen" a measurement rather than a label: the picture that arrived is
the picture the device was showing.

    python3 e2e/compare_frames.py received.png device.png

It prints one JSON object: the two sizes, the mean absolute difference of the
greyscale pixels at a common small size, the correlation, and whether they
agree.  It is deliberately crude -- no image library beyond PIL, no alignment
search -- because a coarse agreement is all the claim needs: the same screen,
not a pixel-perfect copy (the two were encoded and captured at different
instants, at different sizes).
"""

from __future__ import annotations

import json
import sys

from PIL import Image, ImageChops, ImageStat


def grey(path: str, size: tuple[int, int]) -> Image.Image:
    image = Image.open(path).convert("L")
    return image.resize(size, Image.BILINEAR)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[0])
        return 2
    received_path, device_path = argv[1], argv[2]
    received = Image.open(received_path)
    device = Image.open(device_path)
    size = (64, 64)
    left = grey(received_path, size)
    right = grey(device_path, size)
    difference = ImageChops.difference(left, right)
    mean = ImageStat.Stat(difference).mean[0]
    left_pixels = list(left.getdata())
    right_pixels = list(right.getdata())
    left_mean = sum(left_pixels) / len(left_pixels)
    right_mean = sum(right_pixels) / len(right_pixels)
    covariance = sum(
        (a - left_mean) * (b - right_mean)
        for a, b in zip(left_pixels, right_pixels)
    ) / len(left_pixels)
    left_variance = sum((a - left_mean) ** 2 for a in left_pixels) / len(left_pixels)
    right_variance = sum((b - right_mean) ** 2 for b in right_pixels) / len(right_pixels)
    denominator = (left_variance * right_variance) ** 0.5
    correlation = covariance / denominator if denominator else 0.0
    print(
        json.dumps(
            {
                "compared": True,
                "received": {
                    "path": received_path,
                    "size": list(received.size),
                },
                "device": {
                    "path": device_path,
                    "size": list(device.size),
                },
                # 0 is identical, 255 is opposite; a flat pair is near 0 too,
                # which is why the correlation is reported beside it.
                "mean_abs_difference": round(mean, 2),
                "correlation": round(correlation, 4),
                "same_screen": correlation >= 0.5 and mean <= 60,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
