;;; harness-model-complexity.el --- Plain-language estimates of model task complexity  -*- lexical-binding: t; -*-

;;; Commentary:

;; An optional guide to the work a model is suited for, from simple to
;; very complex tasks.  These are editable estimates, not benchmark
;; scores or guarantees, and models at the same level are not ordered
;; by capability.  A model the guide does not recognise stays Unrated.
;; Price, context window, reasoning effort and provider/model-tier are
;; deliberately not evidence: the latter may itself fall back to price.
;;
;; `model-complexity/list' reads the allowed model catalogue and returns
;; annotated copies, never changing the catalogue or a session's model.
;; The user's first matching rule wins over the separate default guide;
;; an explicit nil leaves a model Unrated.  A listed alias may be rated
;; by its `:resolves-to' model without changing the alias's name or id.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)

(defgroup harness-model-complexity nil
  "Plain-language estimates of the task complexity models can handle."
  :group 'harness
  :prefix "harness-model-complexity-")

(defcustom harness-model-complexity-rules nil
  "User estimates of model task complexity, checked before the default guide.
Each entry is (REGEXP . LEVEL), matched against a qualified model id
such as \"chatgpt:gpt-6-sol\".  LEVEL is `simple', `routine', `complex',
`very-complex' or nil for Unrated.  The first matching entry wins;
matching nil explicitly suppresses a default estimate.  Rules also
match a listed alias's qualified `:resolves-to' id.

These are estimates of task suitability, not measured capability or
promises of success.  Adding a rule does not remove the other models'
default estimates; unknown models without a rule remain Unrated."
  :type '(alist :key-type (regexp :tag "Qualified model id")
                :value-type (choice (const :tag "Simple tasks" simple)
                                    (const :tag "Routine tasks" routine)
                                    (const :tag "Complex tasks" complex)
                                    (const :tag "Very complex tasks" very-complex)
                                    (const :tag "Unrated" nil)))
  :group 'harness-model-complexity)

(defconst harness-model-complexity-default-rules
  (append
   '(("\\`[^:]+:gpt-5\\.6-luna\\'" . routine)
     ("\\`[^:]+:gpt-6\\(?:\\.1\\)?-sol\\'" . complex)
     ("\\`[^:]+:gpt-6-astra\\'" . very-complex))
   (mapcar
    (lambda (entry)
      (cons (concat "\\`[^:]+:\\(?:\\(?:[a-z]+\\.\\)?anthropic\\.\\)?"
                    "\\(?:claude-\\(?:[0-9]+-\\)*\\)?" (symbol-name (car entry))
                    "\\(?:\\'\\|-[0-9]\\)")
            (cdr entry)))
    '((haiku . simple) (sonnet . routine) (opus . complex) (fable . very-complex))))
  "Default task-suitability estimates, not benchmark rankings.
The named ChatGPT models are Luna 5.6, Sol 6 and 6.1, and Astra 6;
other GPT versions or suffixes are not silently assigned a level.
Claude family names follow the same order as the harness's configured
family tiers, across providers and Bedrock's regional ids.  User rules
in `harness-model-complexity-rules' take precedence over these.")

(defconst harness-model-complexity--levels
  '((simple "Simple tasks" 1
            "Small, well-specified edits, formatting, and short summaries.")
    (routine "Routine tasks" 2
             "Routine bug fixes, tests, and bounded feature work.")
    (complex "Complex tasks" 3
             "Multi-file changes, difficult debugging, and design trade-offs.")
    (very-complex "Very complex tasks" 4
                  "Ambiguous requirements, large refactors, and sustained investigation."))
  "Complexity estimates as (LEVEL LABEL RANK DESCRIPTION), lowest first.")

(defun harness-model-complexity--ids (model)
  "Return the original and resolved qualified ids of listed MODEL.
A `:resolves-to' name is local to MODEL's provider unless it already
starts with that provider's prefix."
  (let* ((id (plist-get model :id))
         (target (plist-get model :resolves-to))
         (prefix (and (stringp id) (string-match "\\`[^:]+:" id)
                      (match-string 0 id)))
         (resolved (and prefix (stringp target) (not (equal target ""))
                        (if (string-prefix-p prefix target) target (concat prefix target)))))
    (delete-dups (delq nil (list (and (stringp id) id) resolved)))))

(defun harness-model-complexity--matching-rule (rules ids)
  "Return the first entry of RULES matching one of IDS, or nil.
The entry itself, not its value, distinguishes an explicit Unrated
rule from no rule.  A malformed regexp matches nothing."
  (let ((case-fold-search nil))
    (cl-find-if
     (lambda (rule)
       (and (stringp (car rule))
            (cl-some (lambda (id)
                       (condition-case nil
                           (string-match-p (car rule) id)
                         (invalid-regexp nil)))
                     ids)))
     rules)))

(defun harness-model-complexity--annotate (model)
  "Return an annotated copy of MODEL using user rules, then the default guide."
  (let* ((ids (harness-model-complexity--ids model))
         (user (harness-model-complexity--matching-rule harness-model-complexity-rules ids))
         ;; A resolved alias describes the model actually run.  Defaults
         ;; follow it rather than a potentially stale family alias.
         (default (unless user
                    (harness-model-complexity--matching-rule
                     harness-model-complexity-default-rules (last ids))))
         (rule (or user default))
         (level (assq (cdr rule) harness-model-complexity--levels))
         (copy (copy-tree model)))
    (dolist (entry (list (cons :complexity-level (and level (symbol-name (car level))))
                         (cons :complexity-label (or (nth 1 level) "Unrated"))
                         (cons :complexity-rank (nth 2 level))
                         (cons :complexity-description
                               (or (nth 3 level) "No estimate is configured; add a rule for this model."))
                         (cons :complexity-basis
                               (cond (user "User rule (estimate)")
                                     (default "Default guide (estimate)")
                                     (t "No matching rule")))))
      (setq copy (plist-put copy (car entry) (cdr entry))))
    copy))

(defun harness-model-complexity-rank-models (models)
  "Return annotated copies of MODELS, sorted from low to high task complexity.
Unrated models come last.  Models sharing a level sort by qualified id,
not by capability.  Nothing in MODELS is changed; this helper neither
fetches models nor filters them by policy.  `model-complexity/list'
reads the allowed catalogue before calling it."
  (sort (mapcar #'harness-model-complexity--annotate models)
        (lambda (a b)
          (let ((ra (or (plist-get a :complexity-rank) 5))
                (rb (or (plist-get b :complexity-rank) 5)))
            (if (= ra rb)
                (string< (or (plist-get a :id) "") (or (plist-get b :id) ""))
              (< ra rb))))))

(harness-defmethod model-complexity/list (&optional refresh)
  "Return a promise of allowed models, with estimated task levels, lowest first.
REFRESH is passed to `provider/models'.  Each model keeps its original
catalogue fields, plus `:complexity-level' (a string, or nil),
`:complexity-label', `:complexity-rank' (1 through 4, or nil),
`:complexity-description' and `:complexity-basis'.  Unrated models are
last; ties sort by id and do not imply relative capability.  These are
editable estimates, not benchmark results.  No completion is requested
and no session or catalogue model is changed."
  (harness-then (harness-call-async 'provider/models refresh)
                #'harness-model-complexity-rank-models))

(harness-define-module 'model-complexity
  :doc "Plain-language estimates of model task complexity, ordered from simple to very complex."
  :requires '(provider))

(provide 'harness-model-complexity)
;;; harness-model-complexity.el ends here
