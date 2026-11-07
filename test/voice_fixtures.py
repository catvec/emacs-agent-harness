"""Deterministic synthetic audio for the voice gate tests.

These are fixtures, not recordings: a voiced speech-like signal is a
glottal harmonic series under a syllabic envelope, and the noise cases are
generated from a fixed seed.  They exercise the detector's decisions and
the gate's timing without a microphone, a speech model or a network.  Live
microphone and speaker behaviour is a separate, manual check (see
docs/voice-turn-taking.md); it is not claimed by these fixtures.
"""

from __future__ import annotations

import io
import math
import random
import struct
import wave

RATE = 16000


def pcm(samples):
    """Pack an iterable of floats in [-1, 1] as mono PCM16 bytes."""
    return b"".join(struct.pack("<h", max(-32768, min(32767, int(round(value * 32767)))))
                    for value in samples)


def unpack(data):
    """Return PCM16 bytes as a tuple of floats in [-1, 1]."""
    count = len(data) // 2
    return tuple(sample / 32768.0 for sample in struct.unpack("<%dh" % count, data))


def silence(seconds, rate=RATE):
    """Return SECONDS of digital silence."""
    return pcm([0.0] * int(seconds * rate))


def tone(seconds, frequency=120.0, amplitude=0.2, rate=RATE):
    """Return one sine tone."""
    count = int(seconds * rate)
    return pcm(amplitude * math.sin(2.0 * math.pi * frequency * index / rate)
               for index in range(count))


def voiced(seconds, rate=RATE, fundamental=120.0, amplitude=0.22,
           syllable=0.28, pause=0.06, harmonics=5):
    """Return a speech-like harmonic signal with a syllabic envelope.

    A real voice is not a tone: several harmonics and an envelope that
    opens and closes make the high-frequency change and zero-crossing
    features behave like voiced speech rather than like a 50 Hz hum.
    """
    count = int(seconds * rate)
    values = []
    period = syllable + pause
    for index in range(count):
        moment = index / rate
        phase = moment % period
        if phase < syllable:
            envelope = math.sin(math.pi * phase / syllable) ** 0.6
        else:
            envelope = 0.0
        sample = 0.0
        for harmonic in range(1, harmonics + 1):
            sample += (math.sin(2.0 * math.pi * fundamental * harmonic * moment)
                       / harmonic)
        values.append(amplitude * envelope * sample / 2.0)
    return pcm(values)


def white_noise(seconds, amplitude=0.03, rate=RATE, seed=7):
    """Return fixed-seed white noise, a fan or a room without speech."""
    generator = random.Random(seed)
    count = int(seconds * rate)
    return pcm(generator.uniform(-amplitude, amplitude) for _ in range(count))


def hum(seconds, frequency=50.0, amplitude=0.04, rate=RATE):
    """Return a steady low hum, the case energy alone gets wrong."""
    return tone(seconds, frequency=frequency, amplitude=amplitude, rate=rate)


def click(seconds=0.006, amplitude=0.8, rate=RATE):
    """Return one short transient: a tap, a door, a cough."""
    count = int(seconds * rate)
    return pcm(amplitude * (1.0 - index / count) for index in range(count))


def echo(data, gain=0.32, delay=0.06, rate=RATE):
    """Return microphone-like echo: the assistant's own audio, attenuated."""
    delay_samples = int(delay * rate)
    source = unpack(data)
    output = [0.0] * (len(source) + delay_samples)
    for index, value in enumerate(source):
        output[index + delay_samples] += value * gain
    return pcm(output)


def concat(*parts):
    """Concatenate PCM fragments."""
    return b"".join(parts)


def with_pauses(speech_seconds=1.2, pauses=(0.4, 1.2), rate=RATE):
    """Return a long dictation with a natural pause and a longer one."""
    chunks = [voiced(speech_seconds, rate=rate)]
    for pause in pauses:
        chunks.append(silence(pause, rate=rate))
        chunks.append(voiced(speech_seconds, rate=rate))
    return concat(*chunks)


def wav_bytes(data, rate=RATE):
    """Wrap PCM16 mono in a WAV container, for a listening fixture."""
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(data)
    return buffer.getvalue()


def write_fixtures(directory):
    """Write the representative fixtures to DIRECTORY, returning their paths."""
    from pathlib import Path

    root = Path(directory)
    root.mkdir(parents=True, exist_ok=True)
    cases = {
        "speech.wav": voiced(2.0),
        "silence.wav": silence(2.0),
        "noise.wav": white_noise(2.0),
        "hum.wav": hum(2.0),
        "click.wav": concat(silence(0.5), click(), silence(0.5)),
        "echo.wav": echo(voiced(2.0), gain=0.32),
        "dictation.wav": with_pauses(),
    }
    paths = {}
    for name, data in cases.items():
        path = root / name
        path.write_bytes(wav_bytes(data))
        paths[name] = path
    return paths


if __name__ == "__main__":
    # A bounded local check: write the same fixtures the tests use, so they
    # can be played, inspected or fed to a detector by hand.
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="directory for the WAV files")
    options = parser.parse_args()
    for name, path in write_fixtures(options.out).items():
        print("%s %d bytes" % (name, path.stat().st_size))
