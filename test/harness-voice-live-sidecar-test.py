#!/usr/bin/env python3
"""A scripted sidecar for the live voice Emacs tests.

Usage: harness-voice-live-sidecar-test.py INBOX MODE

Every event the harness sends is appended to INBOX as one JSON object
per line.  MODE selects what the sidecar does after `start`:

  quiet     ready and listening; no spontaneous events
  delegate  ready, listening, one user_delta and one delegation
  pipeline  ready, listening, levels, a kept burst and a dropped one
  routing   two spoken bursts, the second only once the first turn's
            result came back, so a test can retarget between them
  notice    ready, listening, then a notice the session survives
  error     ready, then an error event
  exit      ready, a diagnostic on stderr, then a nonzero exit
  silent    no output at all, so startup times out
  bad       a line that is not JSON

No microphone, speaker, model or network is used.
"""

import json
import sys
import time


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: sidecar INBOX MODE\n")
        return 2
    inbox, mode = argv[1], argv[2]

    def record(event):
        with open(inbox, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, separators=(",", ":")) + "\n")

    def send(event, **fields):
        message = {"event": event}
        message.update(fields)
        sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
        sys.stdout.flush()

    if mode == "silent":
        time.sleep(30)
        return 0

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        record(event)
        kind = event.get("event")
        if kind == "start":
            if mode == "bad":
                sys.stdout.write("this is not json\n")
                sys.stdout.flush()
            elif mode == "error":
                send("ready")
                send("error", message="no key")
            elif mode == "exit":
                send("ready")
                sys.stderr.write("boom\n")
                sys.stderr.flush()
                return 3
            else:
                send("ready")
                send("listening")
                if mode == "notice":
                    send("notice", message="Local speech · no audio")
                elif mode == "delegate":
                    send("user_delta", text="Add a docstring to parse.", final=True)
                    send("delegation", id="d-1", text="Add a docstring to parse.")
                elif mode == "routing":
                    # A measured level, the way a real sidecar sends it.
                    send("level", input=0.03, peak=0.11, dbfs=-30.5)
                    send("speech", active=True, utterance=1, reason="onset")
                    send("segment", state="accepted", id="u-1", seconds=1.3)
                    send("transcribing", utterance=1)
                    send("user_delta", text="Add a docstring.", final=True,
                         utterance=1)
                    send("segment", state="transcribed", id="u-1")
                    send("speech", active=False, utterance=1, reason="hangover")
                    send("delegation", id="d-1", text="Add a docstring.",
                         utterance=1)
                elif mode == "pipeline":
                    send("level", input=0.56)
                    send("speech", active=True, utterance=1, reason="onset")
                    send("segment", state="accepted", id="u-1", seconds=1.4)
                    send("transcribing", utterance=1)
                    send("user_delta", text="Add a docstring.", final=True, utterance=1)
                    send("segment", state="transcribed", id="u-1")
                    send("speech", active=False, utterance=1, reason="hangover")
                    send("level", input=0.08)
                    send("segment", state="dropped", id="u-2", seconds=0.08,
                         reason="too short")
        elif mode == "routing" and kind == "delegate_result":
            # The harness finished the first turn: say the next request
            # now, which is where a retarget between the two is visible.
            send("level", input=0.03, peak=0.11, dbfs=-30.5)
            send("speech", active=True, utterance=2, reason="onset")
            send("segment", state="accepted", id="u-2", seconds=1.1)
            send("transcribing", utterance=2)
            send("user_delta", text="Now check the tests.", final=True, utterance=2)
            send("segment", state="transcribed", id="u-2")
            send("speech", active=False, utterance=2, reason="hangover")
            send("delegation", id="d-2", text="Now check the tests.", utterance=2)
        elif kind == "stop":
            send("closed", reason="test sidecar")
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
