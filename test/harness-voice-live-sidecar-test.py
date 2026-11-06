#!/usr/bin/env python3
"""A scripted sidecar for the live voice Emacs tests.

Usage: harness-voice-live-sidecar-test.py INBOX MODE

Every event the harness sends is appended to INBOX as one JSON object
per line.  MODE selects what the sidecar does after `start`:

  quiet     ready and listening; no spontaneous events
  delegate  ready, listening, one user_delta and one delegation
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
                if mode == "delegate":
                    send("user_delta", text="Add a docstring to parse.", final=True)
                    send("delegation", id="d-1", text="Add a docstring to parse.")
        elif kind == "stop":
            send("closed", reason="test sidecar")
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
