#!/usr/bin/env python3
"""A warm JSON-lines server over the fine-tuned thread-continuation model.

Emacs keeps one of these running (`harness-thread-model.el`).  It loads the
encoder once, then answers each request with one line:

    {"id": N, "prob": P}

P is the probability that the message continues the current thread.  A
request is

    {"id": N, "text": "..."}

and a failure is `{"id": N, "error": "why"}`; the server stays up for the
next call, because a malformed request is not a reason to make the next
one wait for the weights again.

Why a server and not a program per call: loading a 22M-parameter encoder
takes about a second, and a routing decision happens while the person is
typing.  The module starts this once, keeps it warm, and starts it again
when it dies.

`--check` loads the model, answers one probe and exits, which is what
`harness-thread-model-status` runs to say whether a model is usable.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

# The probe a --check run answers: it must be a text the model can read,
# not the empty string, or a model that fails on everything would pass.
PROBE = ("Task: check\nCurrent thread: check\nThread so far:\n- user: hello\n"
         "Message to place:\n- hello again")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Answer thread continuation as JSON lines.")
    ap.add_argument("--model", required=True, help="the fine-tuned model directory")
    ap.add_argument("--threads", type=int, default=4,
                    help="torch threads; more than the machine has slows it down")
    ap.add_argument("--max-tokens", type=int, default=384)
    ap.add_argument("--check", action="store_true",
                    help="load the model, answer one probe and exit")
    args = ap.parse_args()

    # Imported here, not at the top: --help and a bad --model should not
    # wait for torch, which takes a second to import on its own.
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    torch.set_num_threads(args.threads)
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model)
    model.eval()

    # The temperature the evaluation fitted, when it left one beside the
    # model.  Without it the answer is the head's raw number, which is
    # what a model trained and never evaluated gives.
    temperature = 1.0
    calibration_path = os.path.join(args.model, "calibration.json")
    if os.path.exists(calibration_path):
        try:
            with open(calibration_path, encoding="utf-8") as f:
                temperature = float(json.load(f).get("temperature") or 1.0)
        except (OSError, ValueError, TypeError) as err:
            print(json.dumps({"warn": f"unreadable calibration: {err}"}),
                  file=sys.stderr, flush=True)
    print(json.dumps({"ready": True, "temperature": temperature}),
          file=sys.stderr, flush=True)

    def answer(text):
        enc = tokenizer([text], truncation=True, max_length=args.max_tokens,
                        padding=True, return_tensors="pt")
        with torch.no_grad():
            logit = model(**enc).logits.squeeze(-1).float()
        if temperature and temperature != 1.0:
            logit = logit / temperature
        return float(torch.sigmoid(logit)[0])

    if args.check:
        print(json.dumps({"id": 0, "prob": answer(PROBE)}), flush=True)
        return 0

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        reply = {}
        try:
            request = json.loads(line)
            reply = {"id": request.get("id"),
                     "prob": answer(str(request.get("text") or ""))}
        except Exception as err:              # a bad line is not a dead server
            reply = {"id": reply.get("id"), "error": f"{type(err).__name__}: {err}"}
        print(json.dumps(reply), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
