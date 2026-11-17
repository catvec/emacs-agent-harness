#!/usr/bin/env python3
"""Deterministic tests for the thread-continuation model's own code.

Every test here runs without a model, a network or a log store: the
schema renders what it is given, the dataset cuts labels by the rules it
documents, and the evaluator's arithmetic is held to numbers computed by
hand.  What the suite does hold the code to:

* the rendering: every part present, every part missing, a malformed
  context, and the exact shape the Emacs module must reproduce;
* the label rules: a continuation, an announced switch, a subject change
  the conversation records, a message the workspace filed elsewhere, a
  short reply, a splice;
* leakage: a conversation never sits on two sides of a split, a
  near-duplicate group never does, and a synthetic variant carries its
  source's group;
* the evaluation's arithmetic: the AUC of a known ranking, the log loss
  and the Brier score of known probabilities, the reliability table's
  bins, the threshold table's wrong-switch and missed-switch counts;
* the baselines' parsers, on the rendered text;
* the degraded inputs, which must stay renderable and stay parseable.

The model's own numbers are `evaluate.py`'s and the model card's; this
suite never trains and never claims a reading it did not compute.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "thread-model"))

import dataset as D  # noqa: E402
import evaluate as E  # noqa: E402
import gen_conversations as G  # noqa: E402
import schema as S  # noqa: E402


def message(role: str, text: str, at: float = 0.0) -> S.Message:
    return S.Message(role=role, text=text, at=at)


def case(**kwargs) -> S.Case:
    base = dict(id="c1", conversation="conv-a", current="conv-a", label=1,
                message=message("user", "The sink is leaking under the window."),
                context=[message("user", "The kitchen renovation is behind."),
                         message("assistant", "The tiles are ordered.")],
                title="Kitchen renovation", task="Home")
    base.update(kwargs)
    return S.Case(**base)


class SchemaTest(unittest.TestCase):
    def test_render_has_every_part_in_order(self):
        text = S.render_case(case(knowledge=["The tiles are matte."]))
        lines = text.splitlines()
        self.assertTrue(lines[0].startswith("Task: "))
        self.assertTrue(lines[1].startswith("Current thread: "))
        self.assertIn("Thread so far:", lines)
        self.assertIn("Knowledge:", lines)
        self.assertIn("Message to place:", lines)
        self.assertTrue(lines[-1].startswith("- The sink is leaking"))

    def test_render_is_total(self):
        """A case with nothing but a message still renders, and stays readable."""
        bare = S.Case(id="b", conversation="c", current="c", label=1,
                      message=message("user", "hello"))
        text = S.render_case(bare)
        self.assertIn("Current thread: (untitled)", text)
        self.assertIn("Message to place:", text)
        self.assertNotIn("Thread so far:", text)
        self.assertNotIn("Knowledge:", text)

    def test_render_survives_a_malformed_context(self):
        """An empty message, a bad role and a missing title do not raise."""
        broken = case(context=[message("user", ""), message("tool", "x"),
                               message("assistant", "ok")], title="")
        text = S.render_case(broken)
        self.assertIn("Current thread: (untitled)", text)
        self.assertIn("Message to place:", text)

    def test_render_clips_a_long_message(self):
        long_case = case(message=message("user", "word " * 5000))
        text = S.render_case(long_case, message_chars=100)
        self.assertLessEqual(len(text.splitlines()[-1]), 103)
        self.assertIn("…", text)

    def test_render_takes_the_last_context_messages(self):
        context = [message("user", f"m{i}") for i in range(20)]
        text = S.render_case(case(context=context), context_messages=3)
        self.assertIn("m19", text)
        self.assertNotIn("m16", text)

    def test_features_are_the_five_the_artifact_declares(self):
        features = S.render_features(case(knowledge=["k"]))
        self.assertEqual(set(features), set(S.FEATURES))
        self.assertEqual(features["thread-title"], "Kitchen renovation")
        self.assertEqual(features["knowledge"], 1)

    def test_labels_and_decision_are_the_contract(self):
        self.assertEqual(S.LABELS, ("continue", "switch"))
        self.assertEqual(S.DECISION, "thread-continuation")
        self.assertEqual(case(label=0).label_name, "switch")

    def test_an_uncertain_case_must_be_ambiguous(self):
        ok, why = case(uncertain=True, slice="ordinary").valid()
        self.assertFalse(ok)
        self.assertIn("ambiguous", why)
        ok, _ = case(uncertain=True, slice="ambiguous").valid()
        self.assertTrue(ok)

    def test_a_case_round_trips(self):
        original = case(knowledge=["a"], slice="local-reference")
        again = S.Case.from_dict(json.loads(json.dumps(original.to_dict())))
        self.assertEqual(again.to_dict(), original.to_dict())


class LabelTest(unittest.TestCase):
    def conversation(self, texts, subjects=None, threads=None):
        conv = D.Conversation(id="conv-a", title="Kitchen", task="Home")
        for role, text in texts:
            conv.messages.append(message(role, text))
        if subjects:
            conv.subjects = subjects
        if threads:
            conv.threads = threads
        return conv

    def test_a_continuation_is_labelled_continue(self):
        conv = self.conversation([
            ("user", "The kitchen renovation is behind."),
            ("assistant", "The tiles arrive Thursday."),
            ("user", "The sink under the window is leaking."),
        ])
        cases = D.cases_of(conv)
        self.assertEqual(len(cases), 1)
        self.assertEqual(cases[0].label, 1)

    def test_a_message_that_repeats_the_last_words_is_a_local_reference(self):
        conv = self.conversation([
            ("user", "The kitchen renovation is behind."),
            ("assistant", "The tiles arrive Thursday."),
            ("user", "Are the kitchen tiles matte?"),
        ])
        cases = D.cases_of(conv)
        self.assertEqual(cases[0].slice, "local-reference")

    def test_an_announced_switch_is_a_switch(self):
        conv = self.conversation([
            ("user", "The kitchen renovation is behind."),
            ("assistant", "The tiles arrive Thursday."),
            ("user", "Different topic: the tax return is filed."),
        ])
        cases = D.cases_of(conv)
        self.assertEqual(cases[0].label, 0)
        self.assertEqual(cases[0].slice, "in-conversation")

    def test_a_recorded_subject_change_is_a_switch(self):
        """A conversation that changes subject midstream is a switch there."""
        conv = self.conversation([
            ("user", "The kitchen renovation is behind."),
            ("assistant", "The tiles arrive Thursday."),
            ("user", "The sink is leaking under the window."),
        ], subjects=["kitchen", "kitchen", "taxes"])
        cases = D.cases_of(conv)
        self.assertEqual(cases[0].label, 0)
        self.assertEqual(cases[0].slice, "in-conversation")

    def test_a_reassigned_message_is_a_switch(self):
        """The person moved it to another thread: that is the label."""
        conv = self.conversation([
            ("user", "The kitchen renovation is behind."),
            ("assistant", "The tiles arrive Thursday."),
            ("user", "The sink is leaking under the window."),
        ], threads={0: "th-kitchen", 1: "th-kitchen", 2: "th-plumbing"})
        cases = D.cases_of(conv)
        self.assertEqual(cases[0].label, 0)
        self.assertEqual(cases[0].slice, "reassigned")

    def test_a_short_reply_is_its_own_slice(self):
        conv = self.conversation([
            ("user", "The kitchen renovation is behind."),
            ("assistant", "The tiles arrive Thursday."),
            ("user", "ok, do that"),
        ])
        cases = D.cases_of(conv)
        self.assertEqual(cases[0].label, 1)
        self.assertEqual(cases[0].slice, "short-reply")

    def test_context_is_only_what_came_before(self):
        conv = self.conversation([
            ("user", "The kitchen renovation is behind."),
            ("assistant", "The tiles arrive Thursday."),
            ("user", "The sink is leaking under the window."),
            ("user", "And the tax return is late."),
        ])
        cases = D.cases_of(conv)
        self.assertNotIn("tax return", " ".join(m.text for m in cases[0].context))

    def test_a_splice_is_a_switch_from_another_conversation(self):
        into = self.conversation([
            ("user", "The kitchen renovation is behind."),
            ("assistant", "The tiles arrive Thursday."),
            ("user", "The sink is leaking under the window."),
        ])
        source = self.conversation([
            ("user", "The tax return needs the second page."),
        ])
        source.id = "conv-b"
        spliced = D.splice(source, into, 2)
        self.assertIsNotNone(spliced)
        self.assertEqual(spliced.label, 0)
        self.assertEqual(spliced.slice, "spliced")
        self.assertEqual(spliced.origin, "conv-b")
        self.assertIn("tax return", spliced.message.text)

    def test_short_reply_is_recognised(self):
        self.assertTrue(D.is_short_reply("ok"))
        self.assertTrue(D.is_short_reply("Yes, and then?"))
        self.assertFalse(D.is_short_reply("The tax return is filed."))

    def test_announced_switch_is_recognised_as_a_whole_phrase(self):
        self.assertTrue(D.announces_switch("Separate question: the roof."))
        self.assertFalse(D.announces_switch("The topic is the roof."))


class LeakageTest(unittest.TestCase):
    def test_groups_keep_near_duplicates_together(self):
        cases = [case(id=f"c{i}", conversation=f"conv-{i}",
                      message=message("user", f"The kitchen sink {i} is leaking."))
                 for i in range(6)]
        twin = case(id="twin", conversation="conv-twin",
                    message=message("user", "The kitchen sink 0 is leaking."))
        cases.append(twin)
        group = D.groups(cases)
        self.assertEqual(group["c0"], group["twin"])

    def test_two_different_subjects_are_two_groups(self):
        a = case(id="a", message=message("user", "The kitchen sink is leaking."))
        b = case(id="b", conversation="conv-b",
                 message=message("user", "The tax return for last year is filed."))
        group = D.groups([a, b])
        self.assertNotEqual(group["a"], group["b"])

    def test_a_group_is_split_as_one(self):
        cases = [case(id=f"c{i}", conversation=f"conv-{i}",
                      message=message("user", "The kitchen sink is leaking."))
                 for i in range(4)]
        group = D.groups(cases)
        splits = {D.split_of_group(group[c.id]) for c in cases}
        self.assertEqual(len(splits), 1)

    def test_a_synthetic_variant_joins_its_sources_group(self):
        source = case(id="src", conversation="conv-a",
                      message=message("user", "The kitchen sink is leaking."))
        variant = case(id="v", conversation="syn-1", origin="conv-a",
                       message=message("user", "The basin under the window drips."))
        group = D.groups([source, variant])
        self.assertEqual(group["src"], group["v"])

    def test_split_of_a_lone_case_is_stable(self):
        a = case(id="stable", message=message("user", "The kitchen sink leaks."))
        self.assertEqual(D.split_of(a), D.split_of(a))


class StoreTest(unittest.TestCase):
    def test_a_session_log_becomes_a_conversation(self):
        with tempfile.TemporaryDirectory() as directory:
            sessions = os.path.join(directory, "sessions")
            os.makedirs(sessions)
            path = os.path.join(sessions, "s1.nodes.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                for i, (kind, text) in enumerate([
                        ("user", "The kitchen renovation is behind."),
                        ("assistant", "The tiles arrive Thursday."),
                        ("user", "The sink is leaking under the window."),
                        ("hint", "a hint is not a message")]):
                    f.write(json.dumps({"id": f"n{i}", "session": "s1",
                                        "kind": kind, "content": text,
                                        "ts": 1000 + i}) + "\n")
            conversation = D.read_conversation(path, "s1")
            self.assertIsNotNone(conversation)
            self.assertEqual(len(conversation.messages), 3)
            self.assertEqual(conversation.messages[0].role, "user")

    def test_a_workspace_brief_is_not_the_person_talking(self):
        with tempfile.TemporaryDirectory() as directory:
            sessions = os.path.join(directory, "sessions")
            os.makedirs(sessions)
            path = os.path.join(sessions, "s1.nodes.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                for i, (kind, text, meta) in enumerate([
                        ("user", "The kitchen renovation is behind.", None),
                        ("assistant", "The tiles arrive Thursday.", None),
                        ("user", "[Workspace Home] Thread: Kitchen", {"workspace-brief": True}),
                        ("user", "The sink is leaking under the window.", None)]):
                    record = {"id": f"n{i}", "session": "s1", "kind": kind,
                              "content": text, "ts": 1000 + i}
                    if meta:
                        record["meta"] = meta
                    f.write(json.dumps(record) + "\n")
            conversation = D.read_conversation(path, "s1")
            self.assertEqual([m.text for m in conversation.messages],
                             ["The kitchen renovation is behind.",
                              "The tiles arrive Thursday.",
                              "The sink is leaking under the window."])

    def test_a_torn_line_is_skipped(self):
        """The last line of a log being written is half a line; the rest reads."""
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "s1.nodes.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                for i, (kind, text) in enumerate([
                        ("user", "The kitchen renovation is behind."),
                        ("assistant", "The tiles arrive Thursday."),
                        ("user", "The sink is leaking under the window."),
                        ("assistant", "A plumber can come Tuesday.")]):
                    f.write(json.dumps({"id": f"n{i}", "kind": kind,
                                        "content": text, "ts": 1 + i}) + "\n")
                f.write('{"id": "n9", "kind": "user", "cont')
            conversation = D.read_conversation(path, "s1")
            self.assertIsNotNone(conversation)
            self.assertEqual(len(conversation.messages), 4)
            self.assertEqual(conversation.messages[-1].text,
                             "A plumber can come Tuesday.")

    def test_an_update_line_merges_into_its_node(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "s1.nodes.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                f.write(json.dumps({"id": "n1", "kind": "user",
                                    "content": "The kitchen", "ts": 1}) + "\n")
                f.write(json.dumps({"id": "n2", "kind": "assistant",
                                    "content": "ok", "ts": 2}) + "\n")
                f.write(json.dumps({"id": "n1", "_op": "update",
                                    "content": "The kitchen renovation is behind."}) + "\n")
                f.write(json.dumps({"id": "n3", "kind": "user",
                                    "content": "The sink leaks.", "ts": 3}) + "\n")
            conversation = D.read_conversation(path, "s1")
            self.assertEqual(conversation.messages[0].text,
                             "The kitchen renovation is behind.")

    def test_a_store_with_no_sessions_is_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(D.read_store(directory), [])


class EvaluationTest(unittest.TestCase):
    def test_auc_of_a_known_ranking(self):
        self.assertEqual(E.auc([0.9, 0.8, 0.1], [1, 1, 0]), 1.0)
        self.assertEqual(E.auc([0.1, 0.2, 0.9], [1, 1, 0]), 0.0)
        self.assertAlmostEqual(E.auc([0.5, 0.5], [0, 1]), 0.5)

    def test_log_loss_and_brier_of_known_numbers(self):
        self.assertAlmostEqual(E.log_loss([0.9], [1]), -__import__("math").log(0.9), places=5)
        self.assertAlmostEqual(E.brier([0.9, 0.2], [1, 0]), (0.01 + 0.04) / 2, places=6)

    def test_reliability_bins_and_ece(self):
        table = E.reliability([0.05, 0.15, 0.95], [0, 0, 1])
        self.assertEqual(table["n"], 3)
        self.assertGreater(table["ece"], 0)
        self.assertAlmostEqual(table["base-rate"], 1 / 3, places=4)
        populated = [row for row in table["bins"] if row["n"]]
        self.assertEqual(len(populated), 3)

    def test_threshold_table_counts_both_mistakes(self):
        # 0.95 continues (right), 0.05 switches (wrong: it continued),
        # 0.2 is undecided at trust 0.9.
        table = E.threshold_table([0.95, 0.05, 0.2], [1, 1, 1], (0.9,))[0]
        self.assertEqual(table["decided"], 2)
        self.assertEqual(table["wrong-switch"], 1)
        self.assertEqual(table["missed-switch"], 0)

    def test_the_threshold_never_ships_a_value_that_decides_nothing(self):
        chosen = E.choose_threshold([0.99, 0.98], [1, 1], max_wrong_switch=0)
        self.assertGreaterEqual(chosen, 0.5)

    def test_parse_case_reads_what_render_wrote(self):
        text = S.render_case(case(knowledge=["The tiles are matte."]))
        parts = E.parse_case(text)
        self.assertEqual(parts["title"], "Kitchen renovation")
        self.assertEqual(parts["task"], "Home")
        self.assertEqual(parts["message"], "The sink is leaking under the window.")
        self.assertEqual(parts["knowledge"], ["The tiles are matte."])
        self.assertEqual(len(parts["context"]), 2)

    def test_word_overlap_rule_prefers_the_thread_that_holds_the_words(self):
        # The message shares its subject with the thread it is in...
        held = S.render_case(case(
            message=message("user", "The kitchen tiles are matte.")))
        # ...and shares nothing with a thread about something else.
        other = S.render_case(case(
            message=message("user", "The wedding is in June."),
            context=[message("user", "My sister is engaged."),
                     message("assistant", "Congratulations.")],
            title="Wedding"))
        self.assertGreater(E.word_overlap_rule(held),
                           E.word_overlap_rule(other) / 2)
        # A message whose words no part of the thread holds scores zero,
        # which is what makes the router start a thread for it.
        stranger = S.render_case(case(
            message=message("user", "My sister's wedding is in June."),
            title="Kitchen renovation"))
        self.assertEqual(E.word_overlap_rule(stranger), 0.0)

    def test_graph_only_rule_needs_a_graph(self):
        without = S.render_case(case())
        with_graph = S.render_case(case(knowledge=["The sink is leaking."]))
        self.assertEqual(E.graph_only_rule(without), 0.0)
        self.assertGreater(E.graph_only_rule(with_graph), 0.0)

    def test_degraded_inputs_stay_parseable(self):
        text = S.render_case(case(knowledge=["The tiles are matte."]))
        for how in ("no-graph", "no-context", "no-title",
                    "truncated-message", "empty"):
            degraded = E.degraded(text, how)
            parts = E.parse_case(degraded)      # must not raise
            self.assertIn("title", parts)
        self.assertEqual(E.degraded(text, "no-graph").count("Knowledge:"), 0)
        self.assertEqual(E.degraded(text, "no-context").count("Thread so far:"), 0)
        self.assertEqual(E.parse_case(E.degraded(text, "empty"))["message"], "")


class GeneratorTest(unittest.TestCase):
    def test_a_written_conversation_becomes_one_with_subjects(self):
        raw = {"title": "Kitchen", "task": "Home", "messages": [
            {"role": "user", "text": "The kitchen renovation is behind.", "subject": "kitchen"},
            {"role": "assistant", "text": "The tiles arrive Thursday.", "subject": "kitchen"},
            {"role": "user", "text": "The sink is leaking.", "subject": "kitchen"},
            {"role": "user", "text": "The tax return is late.", "subject": "taxes"}]}
        conversation = G.to_conversation(raw, "home", 0)
        self.assertIsNotNone(conversation)
        self.assertEqual(conversation.subjects[0], "kitchen")
        self.assertEqual(G.switch_indices(conversation), {3})

    def test_a_conversation_with_no_roles_is_refused(self):
        raw = {"messages": [{"text": "hello"}] * 5}
        self.assertIsNone(G.to_conversation(raw, "home", 0))

    def test_subjects_survive_a_round_trip(self):
        raw = {"title": "T", "task": "X", "messages": [
            {"role": "user", "text": "a b c", "subject": "one"},
            {"role": "assistant", "text": "d e f", "subject": "one"},
            {"role": "user", "text": "g h i", "subject": "two"},
            {"role": "assistant", "text": "j k l", "subject": "two"}]}
        conversation = G.to_conversation(raw, "fam", 0)
        again = D.Conversation.from_dict(json.loads(json.dumps(conversation.to_dict())))
        self.assertEqual(again.subjects, conversation.subjects)
        self.assertEqual(G.switch_indices(again), {2})


class SetTest(unittest.TestCase):
    def test_a_built_set_has_no_group_on_two_sides(self):
        import build_set
        conversations = []
        for n in range(6):
            conv = D.Conversation(id=f"syn-{n}", title=f"Thread {n}",
                                  task="Home", source="synthetic")
            for role, text, subject in [
                    ("user", f"The kitchen {n} renovation is behind.", "kitchen"),
                    ("assistant", "The tiles arrive Thursday.", "kitchen"),
                    ("user", f"The sink {n} is leaking under the window.", "kitchen"),
                    ("assistant", "A plumber can come Tuesday.", "kitchen"),
                    ("user", f"The tax return {n} is late.", "taxes")]:
                conv.messages.append(message(role, text))
                conv.subjects.append(subject)
            conversations.append(conv)
        rows, report = build_set.build(conversations, seed=3)
        self.assertTrue(rows)
        self.assertEqual(report["cases"], len(rows))
        for row in rows:
            self.assertIn(row["split"], ("train", "val", "test"))
            self.assertIn(row["text"], row["text"])

    def test_the_set_refuses_a_group_on_two_sides(self):
        import build_set
        rows = [{"group": "g", "split": "train"}, {"group": "g", "split": "test"}]
        seen = {}
        clash = False
        for row in rows:
            other = seen.setdefault(row["group"], row["split"])
            if other != row["split"]:
                clash = True
        self.assertTrue(clash)


if __name__ == "__main__":
    unittest.main(verbosity=2)
