;;; harness-carry-test.el --- Tests for the ways to carry a conversation over  -*- lexical-binding: t; -*-

;;; Commentary:

;; The table of ways the cold-cache question and the model switch share
;; (lisp/harness-carry.el): the keys, the labels and the wording, what
;; each way costs as an estimate says and as a price known already, and
;; the choices built from both.  The two questions' own tests check that
;; they send these choices.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-carry)

(defun harness-carry-test--estimate ()
  "Return a `compaction/estimate' answer to price the ways from."
  (list :context 84000 :carry-on 0.315 :carry-on-cached 0.025
        :kinds (list (list :kind 'summary :model-label "Demo scripted" :cost 0.33 :after 1500)
                     (list :kind "brief" :model-label "Demo cheap" :cost 0.004 :after 900)
                     (list :kind 'transcript :cost 0.0 :after 200)
                     (list :kind 'fresh :cost 0.0 :after 90)
                     (list :kind 'truncate :cost 0.0 :after 50000))))

(ert-deftest harness-carry-ways-are-complete-and-distinct ()
  "Every way has a key, a label and wording, and no two share a key or a label."
  (let ((names (harness-carry-names)))
    (should (equal '(brief summary transcript fresh carry-on ignore hold) names))
    (should (equal '(?b ?s ?t ?f ?c ?i ?q) (mapcar #'harness-carry-key names)))
    (should (= (length names) (length (delete-dups (mapcar #'harness-carry-key names)))))
    (should (= (length names) (length (delete-dups (mapcar #'harness-carry-label names)))))
    (dolist (way names)
      (should (stringp (harness-carry-label way)))
      (should (string-match-p "[^ ]" (harness-carry-property way :what)))
      ;; Nouns and imperatives, no sentences: a segment after another.
      (should-not (string-match-p "[.!?] \\|[.!?]\\'" (harness-carry-property way :what))))
    (should (equal "Transcript file" (harness-carry-label 'transcript)))
    (should (eq 'transcript (harness-carry-by-key ?t)))
    (should (eq 'hold (harness-carry-by-key "q")))
    (should-not (harness-carry-by-key ?z))
    (should-not (harness-carry-by-key "tt"))
    (should (eq 'brief (harness-carry-way "Brief")))
    (should-not (harness-carry-way "nothing"))))

(ert-deftest harness-carry-the-two-summaries-keep-the-first-and-last-messages ()
  "The wording of both summaries says the first and last messages are kept,
as the compaction does (`harness-compaction--with-verbatim-ends'): the
options never left it out because the compaction did not do it."
  (dolist (way '(brief summary))
    (should (string-match-p "first and last messages kept" (harness-carry-property way :what))))
  (dolist (way '(transcript fresh carry-on ignore hold))
    (should-not (string-match-p "first and last" (harness-carry-property way :what)))))

(ert-deftest harness-carry-cost-reads-the-same-wherever-it-is-said ()
  "A way that asks no model is free, the rest cost what the estimate says,
and carrying on or ignoring what the uncached context costs; holding has
no price, and a model the catalogue does not price none."
  (let ((estimate (harness-carry-test--estimate)))
    (should (equal "free" (harness-carry-cost-text estimate 'transcript)))
    (should (equal "free" (harness-carry-cost-text nil 'fresh)))
    (should (equal "~$0.0040" (harness-carry-cost-text estimate 'brief)))
    (should (equal "~$0.330" (harness-carry-cost-text estimate 'summary)))
    (should (equal "~$0.315 uncached" (harness-carry-cost-text estimate 'carry-on)))
    (should (equal "~$0.315 uncached" (harness-carry-cost-text estimate 'ignore)))
    (should-not (harness-carry-cost-text estimate 'hold))
    (should-not (harness-carry-cost-text nil 'summary))
    (should (= 0.33 (harness-carry-cost estimate 'summary)))
    ;; The kind names travel as strings over the wire.
    (should (= 0.004 (harness-carry-cost estimate 'brief)))
    ;; The same words for a price known already.
    (should (equal "~$1.20" (harness-carry-cost-string 'summary 1.2)))
    (should (equal "~$1.20 uncached" (harness-carry-cost-string 'carry-on 1.2)))
    (should (equal "free" (harness-carry-cost-string 'fresh nil)))
    (should-not (harness-carry-cost-string 'summary nil))))

(ert-deftest harness-carry-total-needs-every-price ()
  "A total of prices where one is not known would pass for the whole."
  (should (= 0.5 (harness-carry-total '(0.2 0.3))))
  (should (= 0.25 (harness-carry-total '(0.25))))
  (should-not (harness-carry-total '(0.2 nil)))
  (should-not (harness-carry-total nil)))

(ert-deftest harness-carry-choice-puts-its-own-words-and-the-question-s ()
  "A choice has its way's key, label and wording; the question that offers
it may say its label or wording otherwise, and adds what it knows."
  (let ((choice (harness-carry-choice 'summary :cost 0.33 :by "Demo scripted" :mode "compact")))
    (should (equal "summary" (plist-get choice :choice)))
    (should (equal "s" (plist-get choice :key)))
    (should (equal "Summary" (plist-get choice :label)))
    (should (equal (harness-carry-property 'summary :what) (plist-get choice :what)))
    (should (= 0.33 (plist-get choice :cost)))
    (should (equal "compact" (plist-get choice :mode))))
  (let ((choice (harness-carry-choice 'hold :label "Cancel" :what "model unchanged" :mode "cancel")))
    (should (equal "q" (plist-get choice :key)))
    (should (equal "Cancel" (plist-get choice :label)))
    (should (equal "model unchanged" (plist-get choice :what)))
    (should (equal "cancel" (plist-get choice :mode)))))

(ert-deftest harness-carry-choices-are-priced-from-one-estimate ()
  "The choices of some ways carry what the estimate says of each: its cost,
how that reads, the model that writes it and the context after it."
  (let ((choices (harness-carry-choices '(brief summary transcript carry-on hold)
                                        (harness-carry-test--estimate))))
    (should (equal '("brief" "summary" "transcript" "carry-on" "hold")
                   (mapcar (lambda (c) (plist-get c :choice)) choices)))
    (should (equal '("b" "s" "t" "c" "q") (mapcar (lambda (c) (plist-get c :key)) choices)))
    (should (equal '("~$0.0040" "~$0.330" "free" "~$0.315 uncached" nil)
                   (mapcar (lambda (c) (plist-get c :cost-text)) choices)))
    (should (equal '("Demo cheap" "Demo scripted" nil nil nil)
                   (mapcar (lambda (c) (plist-get c :by)) choices)))
    (should (equal '(900 1500 200 nil nil) (mapcar (lambda (c) (plist-get c :after)) choices)))
    (should (= 0.315 (plist-get (nth 3 choices) :cost))))
  ;; Without an estimate nothing is priced, but what asks no model is free.
  (let ((choices (harness-carry-choices '(brief transcript) nil)))
    (should-not (plist-get (nth 0 choices) :cost-text))
    (should (equal "free" (plist-get (nth 1 choices) :cost-text)))))

(provide 'harness-carry-test)
;;; harness-carry-test.el ends here
