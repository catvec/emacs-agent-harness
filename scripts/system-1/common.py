"""The parts a System 1 reflex has whatever it is deciding.

Two decisions now run on the same small encoder: whether a tool call is
safe work (`scripts/system-one/`) and whether a workspace message
continues its thread (`scripts/thread-model/`).  They differ in what they
read, what their labels mean and how their probabilities are fitted --
and they do not differ in the arithmetic that turns a model and a list of
texts into probabilities, or that says how well a list of probabilities
fits a list of labels.

That arithmetic is here, once, so a third reflex gets it by importing it
rather than by copying it a third time.  What is *not* here is anything
about a decision: no schema, no label, no rendering, no threshold.  Those
are the model's own, and they stay in its directory, which is what keeps
two decisions with one arithmetic from becoming one decision.

The functions take plain lists and numpy arrays and know nothing about a
case, a workflow or a workspace.
"""

from __future__ import annotations

import json


def read_jsonl(path: str) -> list[dict]:
    """Return the JSON objects in PATH, one per line; a blank line is skipped."""
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def predict(model, tokenizer, texts, batch: int = 32, max_tokens: int = 384,
            threads: int = 8) -> list[float]:
    """Return the model's probability for each of TEXTS.

    One logit per text, sigmoided.  The caller applies whatever
    calibration its own model carries; this is the head's raw number.
    """
    import torch

    torch.set_num_threads(threads)
    model.eval()
    out = []
    with torch.no_grad():
        for i in range(0, len(texts), batch):
            enc = tokenizer(texts[i:i + batch], truncation=True,
                            max_length=max_tokens, padding=True,
                            return_tensors="pt")
            logits = model(**enc).logits.squeeze(-1).float()
            out.extend(torch.sigmoid(logits).tolist())
    return out


def auc(probs, labels) -> float:
    """Return the area under the ROC curve, by rank, ties sharing a rank.

    NaN when a split holds one label only: a curve through one class is
    not a curve, and a caller that reports a number there reports
    nothing.
    """
    import numpy as np

    order = np.argsort(probs, kind="mergesort")
    ranks = np.empty(len(probs), dtype=float)
    sorted_probs = np.array(probs)[order]
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and sorted_probs[j + 1] == sorted_probs[i]:
            j += 1
        ranks[order[i:j + 1]] = (i + j) / 2.0 + 1
        i = j + 1
    labels = np.array(labels)
    positive = labels >= 0.5
    n_pos, n_neg = positive.sum(), (~positive).sum()
    if n_pos == 0 or n_neg == 0:
        return float("nan")
    return float((ranks[positive].sum() - n_pos * (n_pos + 1) / 2) / (n_pos * n_neg))


def log_loss(probs, labels, eps: float = 1e-6) -> float:
    """Return the mean binary log loss of PROBS against LABELS."""
    import numpy as np

    p = np.clip(np.array(probs, dtype=float), eps, 1 - eps)
    y = np.array(labels, dtype=float)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


def brier(probs, labels) -> float:
    """Return the Brier score of PROBS against LABELS."""
    import numpy as np

    p = np.array(probs, dtype=float)
    y = np.array(labels, dtype=float)
    return float(np.mean((p - y) ** 2))


def accuracy(probs, labels, threshold: float = 0.5) -> float:
    """Return the share of PROBS that read the same way as LABELS."""
    import numpy as np

    predicted = (np.array(probs, dtype=float) >= threshold).astype(int)
    return float((predicted == np.array(labels, dtype=float)).mean())


def fit_temperature(probs, labels, low: float = 0.25, high: float = 64.0,
                    steps: int = 120) -> float:
    """Return the temperature that makes PROBS best calibrated on LABELS.

    A head trained on balanced classes answers too near 0.5 for the real
    ratio, and its numbers are compressed: the ranking is right and the
    probability is not.  One parameter fixes that -- dividing the logit
    by T before the sigmoid -- and T is fitted on the validation split,
    never on the test one.

    The fit is a grid search rather than a gradient: one parameter, a
    bounded range, and a search that cannot wander off.  A fit that runs
    to `high' is itself a reading: the head's numbers carry little more
    than their order, and a caller should say so.
    """
    import numpy as np

    probs = np.clip(np.array(probs, dtype=float), 1e-6, 1 - 1e-6)
    labels = np.array(labels, dtype=float)
    logits = np.log(probs / (1 - probs))
    best_t, best_loss = 1.0, log_loss(probs, labels)
    for t in np.exp(np.linspace(np.log(low), np.log(high), steps)):
        scaled = 1.0 / (1.0 + np.exp(-logits / t))
        loss = log_loss(scaled, labels)
        if loss < best_loss:
            best_t, best_loss = float(t), loss
    return round(best_t, 4)


def apply_temperature(probs, temperature: float) -> list[float]:
    """Return PROBS recalibrated with TEMPERATURE."""
    import numpy as np

    probs = np.clip(np.array(probs, dtype=float), 1e-6, 1 - 1e-6)
    logits = np.log(probs / (1 - probs))
    return list(1.0 / (1.0 + np.exp(-logits / max(1e-6, temperature))))


def reliability(probs, labels, bins: int = 10) -> dict:
    """Return a reliability table, its expected calibration error, the base rate.

    Each bin says how many cases fell in it, what the model said on
    average and what happened on average; a calibrated model's two
    averages agree in every bin, and the gap is what the ECE weighs.
    """
    import numpy as np

    probs = np.array(probs, dtype=float)
    labels = np.array(labels, dtype=float)
    edges = np.linspace(0.0, 1.0, bins + 1)
    table, ece, n = [], 0.0, len(probs)
    for i in range(bins):
        lo, hi = edges[i], edges[i + 1]
        mask = (probs >= lo) & (probs < hi if i < bins - 1 else probs <= hi)
        count = int(mask.sum())
        if count == 0:
            table.append({"lo": round(lo, 3), "hi": round(hi, 3), "n": 0,
                          "said": None, "happened": None})
            continue
        said = float(probs[mask].mean())
        happened = float(labels[mask].mean())
        ece += count / n * abs(said - happened)
        table.append({"lo": round(lo, 3), "hi": round(hi, 3), "n": count,
                      "said": round(said, 4), "happened": round(happened, 4)})
    return {"bins": table, "ece": round(float(ece), 4),
            "base-rate": round(float(labels.mean()), 4) if n else None, "n": n}


def collate(items):
    """Pad ITEMS to the longest text in the batch, for a training loader.

    A batch carries each row's label and, when the rows have one, its
    weight: a case the label cannot settle moves the gradient by less
    than a case, and the loader has to hand that to the loss.
    """
    import torch

    length = max(len(item["input_ids"]) for item in items)
    out = {}
    for key in ("input_ids", "attention_mask", "token_type_ids"):
        if key not in items[0]:
            continue
        pad = 1 if key == "attention_mask" else 0
        out[key] = torch.stack([torch.nn.functional.pad(
            item[key], (0, length - len(item[key])), value=pad) for item in items])
    if "labels" in items[0]:
        out["labels"] = torch.stack([item["labels"] for item in items])
    if "weights" in items[0]:
        out["weights"] = torch.stack([item["weights"] for item in items])
    return out


class Cases:
    """The rows of one split, tokenised once, for a training loader.

    A row is a dict with a `text' and a `label'; `weight' is optional and
    defaults to 1, so a case the label cannot settle can move the
    gradient by less than a case.
    """

    def __init__(self, rows, tokenizer, max_tokens: int = 384):
        self.rows = rows
        self.enc = tokenizer([r["text"] for r in rows], truncation=True,
                             max_length=max_tokens)

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        import torch

        item = {key: torch.tensor(value[i]) for key, value in self.enc.items()}
        item["labels"] = torch.tensor(float(self.rows[i]["label"]))
        item["weights"] = torch.tensor(float(self.rows[i].get("weight", 1.0)))
        return item
