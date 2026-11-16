#!/usr/bin/env python3
# """A warm JSON-lines server over the fine-tuned classifier."""
#
# Emacs keeps one of these running.  It loads the encoder once, then
# answers each request with one line: {"id": N, "prob": P}, P the
# probability that the call being decided is safe work.  A request is
# {"id": N, "text": "..."}; a failure is {"id": N, "error": "why"},
# and the server stays up for the next call.
#
# Why a server and not a program per call: loading a 22M-parameter
# encoder takes about a second, and a permission decision waits on the
# answer.  The module starts this once, keeps it warm, and restarts it
# when it dies.

from __future__ import annotations

import argparse
import json
import os
import sys

BASE = "sentence-transformers/all-MiniLM-L6-v2"


def main() -> int:
    ap = argparse.ArgumentParser(description="Answer tool-call safety as JSON lines.")
    ap.add_argument("--model", required=True, help="the fine-tuned model directory")
    ap.add_argument("--threads", type=int, default=4,
                    help="torch threads; more than the machine has slows it down")
    ap.add_argument("--max-tokens", type=int, default=256)
    args = ap.parse_args()

    # Imported here, not at the top: --help and a bad --model should not
    # wait for torch, which takes a second to import on its own.
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    torch.set_num_threads(args.threads)
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model)
    model.eval()
    print(json.dumps({"ready": True}), file=sys.stderr, flush=True)

    def answer(text):
        enc = tokenizer([text], truncation=True, max_length=args.max_tokens,
                        padding=True, return_tensors="pt")
        with torch.no_grad():
            logit = model(**enc).logits.squeeze(-1).float()
        return float(torch.sigmoid(logit)[0])

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
