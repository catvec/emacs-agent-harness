;;; harness-ui-model-picker-test.el --- Tests for the model catalogue picker  -*- lexical-binding: t; -*-
;;; Commentary:

;; The model picker opens on providers, drills into the families of one
;; and back out, offers a flat list of the models below the current
;; level, and fuzzy-searches every descendant model as soon as something
;; is typed.  A picker that ranks models across providers (the optional
;; complexity guide) opens on the flat list instead.  The picker never
;; infers availability: it draws the catalogue it is given, which the
;; harness filters by configuration.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)

(defconst harness-ui-model-picker-test--models
  '((:id "chatgpt:gpt-6.1-sol" :label "GPT-6.1 Sol" :provider-label "ChatGPT"
         :context-window 400000 :pricing (:input 1 :output 2))
    (:id "chatgpt:gpt-6.1-astra" :label "GPT-6.1 Astra" :provider-label "ChatGPT"
         :context-window 400000)
    (:id "chatgpt:gpt-6-sol" :label "GPT-6 Sol" :provider-label "ChatGPT"
         :context-window 400000)
    (:id "openrouter:openai/gpt-6.1-sol" :label "GPT-6.1 Sol" :provider-label "OpenRouter"
         :context-window 1048576)
    (:id "openrouter:meta-llama/llama-4-maverick" :label "Llama 4 Maverick"
         :provider-label "OpenRouter" :context-window 200000)
    (:id "openrouter:x-ai/grok-4-fast" :label "Grok 4 Fast" :provider-label "OpenRouter"
         :context-window 2000000)
    (:id "claude:claude-opus-5-5" :label "Claude Opus 5.5" :provider-label "Claude Code"
         :context-window 1000000)
    (:id "local:unknown" :label "Unknown" :provider-label "Local" :context-window 8000))
  "A catalogue with vendors, families, namespaced ids and an unknown model.")

(defun harness-ui-model-picker-test--rows (table &optional string)
  "Return the rows of TABLE offered for STRING, or for an empty query."
  (all-completions (or string "") table))

(defun harness-ui-model-picker-test--annotations (rows)
  "Return the annotation of each of ROWS in the current prompt."
  (let ((fn (plist-get completion-extra-properties :annotation-function)))
    (mapcar fn rows)))

(defun harness-ui-model-picker-test--row (table regexp)
  "Return the row of TABLE whose key matches REGEXP."
  (car (cl-remove-if-not (lambda (row) (string-match-p regexp row))
                         (harness-ui-model-picker-test--rows table))))

(defun harness-ui-model-picker-test--record (prompts steps)
  "Record the PROMPT and its STEPS, for a stub of `completing-read'."
  (push prompts prompts)
  steps)

(defun harness-ui-model-picker-test--walk (script &optional models all prompt)
  "Run a picker over MODELS, following SCRIPT, and return what each step showed.
SCRIPT is a list of (PROMPT CHOICE).  CHOICE is a regexp naming the row to
choose, a function of the completion table returning a row, the symbol
`empty' for an empty answer, or nil to quit.  ALL and PROMPT open on the
flat list, as the ranked picker does.  The result is (PROMPTS STEPS
CHOSEN): STEPS holds (ROWS ANNOTATIONS) in the order they were shown."
  (let ((prompts nil) (steps nil) (chosen nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt table &rest _)
                 (push prompt prompts)
                 (let ((rows (harness-ui-model-picker-test--rows table)))
                   (push (list rows (harness-ui-model-picker-test--annotations rows)) steps))
                 (pcase (pop script)
                   (`(,wanted ,choice)
                    (unless (equal wanted prompt)
                      (error "Expected prompt %S, got %S" wanted prompt))
                    (cond ((null choice) (signal 'quit nil))
                          ((eq choice 'empty) "")
                          ((functionp choice) (funcall choice table))
                          (t (harness-ui-model-picker-test--row table choice))))
                   (_ (error "Unexpected prompt %S" prompt))))))
      (condition-case nil
          (harness-ui-read-model (or models harness-ui-model-picker-test--models)
                                 (lambda (id label) (setq chosen (list id label)))
                                 all prompt)
        (quit nil)))
    (list (nreverse prompts) (nreverse steps) chosen)))

(ert-deftest harness-ui-model-picker-opens-on-providers-and-drills-into-families ()
  "An empty answer lists the providers, then a provider's families, then
a family's models; Back returns from a family to its provider."
  (let* ((result (harness-ui-model-picker-test--walk
                  '(("Model provider: " "ChatGPT")
                    ("Model · ChatGPT: " "GPT 6\\.1")
                    ("Model · ChatGPT / GPT 6.1: " "\\[chatgpt:gpt-6\\.1-sol\\]"))))
         (prompts (nth 0 result))
         (steps (nth 1 result)))
    (should (equal '("Model provider: " "Model · ChatGPT: " "Model · ChatGPT / GPT 6.1: ")
                   prompts))
    ;; The providers, with how many models each offers.
    (should (equal '("ChatGPT" "Claude Code" "Local" "OpenRouter" "All models")
                   (car (nth 0 steps))))
    (should (equal '("  3 models" "  1 model" "  1 model" "  3 models" "  All providers")
                   (cadr (nth 0 steps))))
    ;; A family of several models is a level; a family of one is offered here.
    (should (equal '("GPT 6.1" "GPT-6 Sol (ChatGPT)  [chatgpt:gpt-6-sol]"
                     "All models" "Back")
                   (car (nth 1 steps))))
    (should (equal '("  2 models" "  400k ctx" "  Flat list" "  Parent category")
                   (cadr (nth 1 steps))))
    (should (equal '("GPT-6.1 Sol (ChatGPT)  [chatgpt:gpt-6.1-sol]"
                     "GPT-6.1 Astra (ChatGPT)  [chatgpt:gpt-6.1-astra]"
                     "Back")
                   (car (nth 2 steps))))
    (should (equal '("  400k ctx · $1/$2 per M" "  400k ctx" "  Parent category")
                   (cadr (nth 2 steps))))
    (should (equal '("chatgpt:gpt-6.1-sol" "GPT-6.1 Sol (ChatGPT)") (nth 2 result)))))

(ert-deftest harness-ui-model-picker-back-returns-to-the-level-above ()
  "Back from a family returns to its provider, and from a provider to
the list of providers."
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: " "ChatGPT")
                   ("Model · ChatGPT: " "GPT 6\\.1")
                   ("Model · ChatGPT / GPT 6.1: " "Back")
                   ("Model · ChatGPT: " "Back")
                   ("Model provider: " nil)))))
    (should (equal '("Model provider: " "Model · ChatGPT: " "Model · ChatGPT / GPT 6.1: "
                     "Model · ChatGPT: " "Model provider: ")
                   (nth 0 result)))
    (should-not (nth 2 result))))

(ert-deftest harness-ui-model-picker-picks-a-model-with-its-real-name-and-id ()
  "Choosing a model calls back with its qualified id and readable label,
which is the model, less a provider word, and the provider."
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: " "Claude Code")
                   ("Model · Claude Code: " "\\[claude:claude-opus-5-5\\]")))))
    (should (equal '("Opus 5.5 (Claude)  [claude:claude-opus-5-5]" "Back")
                   (car (nth 1 (nth 1 result)))))
    (should (equal '("claude:claude-opus-5-5" "Opus 5.5 (Claude)") (nth 2 result)))))

(ert-deftest harness-ui-model-picker-provider-level-of-single-model-families ()
  "A provider whose models are all in families of one lists those models
directly, with no level that holds a single model."
  (let* ((result (harness-ui-model-picker-test--walk
                  '(("Model provider: " "OpenRouter")
                    ("Model · OpenRouter: " nil))))
         (step (nth 1 (nth 1 result))))
    (should (equal '("GPT-6.1 Sol (OpenRouter)  [openrouter:openai/gpt-6.1-sol]"
                     "Llama 4 Maverick (OpenRouter)  [openrouter:meta-llama/llama-4-maverick]"
                     "Grok 4 Fast (OpenRouter)  [openrouter:x-ai/grok-4-fast]"
                     "Back")
                   (car step)))
    (should (equal '("  1.05M ctx" "  200k ctx" "  2.00M ctx" "  Parent category")
                   (cadr step)))))

(ert-deftest harness-ui-model-picker-fuzzy-searches-every-provider ()
  "Typing at the providers searches every model of every provider, by
subsequence, so punctuation-free \"g61sol\" finds both GPT-6.1 Sols."
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: " (lambda (table)
                                         (let ((rows (harness-ui-model-picker-test--rows table "g61sol")))
                                           (should (equal '("GPT-6.1 Sol (ChatGPT)"
                                                            "GPT-6.1 Sol (OpenRouter)")
                                                          (mapcar (lambda (row)
                                                                    (car (split-string row "  \\[")))
                                                                  rows)))
                                           (car rows))))))))
    (should (equal '("chatgpt:gpt-6.1-sol" "GPT-6.1 Sol (ChatGPT)") (nth 2 result))))
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: " (lambda (table)
                                         (let ((rows (harness-ui-model-picker-test--rows table "llama")))
                                           (should (= 1 (length rows)))
                                           (car rows))))))))
    (should (equal '("openrouter:meta-llama/llama-4-maverick" "Llama 4 Maverick (OpenRouter)")
                   (nth 2 result)))))

(ert-deftest harness-ui-model-picker-search-matches-provider-and-id-words ()
  "A query may match the provider or the qualified id, and its words may
come in any order."
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: " (lambda (table)
                                         (let ((rows (harness-ui-model-picker-test--rows
                                                      table "openrouter sol")))
                                           (should (equal '("GPT-6.1 Sol (OpenRouter)  [openrouter:openai/gpt-6.1-sol]")
                                                          rows))
                                           (car rows))))))))
    (should (equal "openrouter:openai/gpt-6.1-sol" (car (nth 2 result))))))

(ert-deftest harness-ui-model-picker-search-matches-within-one-field ()
  "A query is matched field by field, not across a name and its
provider: \"opus\" is the Opus models, not every model of OpenRouter, and
a second term can name the provider."
  (let* ((models '((:id "openrouter:openai/gpt-6.1-sol" :label "OpenAI: GPT-6.1 Sol"
                        :provider-label "OpenRouter")
                   (:id "claude:claude-opus-5-5" :label "Claude Opus 5.5"
                    :provider-label "Claude Code")
                   (:id "openrouter:anthropic/claude-opus-5-5"
                    :label "Anthropic: Claude Opus 5.5" :provider-label "OpenRouter")))
         (result (harness-ui-model-picker-test--walk
                  '(("Model provider: " (lambda (table)
                                          (should (equal '("Opus 5.5 (Claude)  [claude:claude-opus-5-5]"
                                                           "Anthropic: Claude Opus 5.5 (OpenRouter)  [openrouter:anthropic/claude-opus-5-5]")
                                                         (harness-ui-model-picker-test--rows table "opus")))
                                          (should (equal '("OpenAI: GPT-6.1 Sol (OpenRouter)  [openrouter:openai/gpt-6.1-sol]")
                                                         (harness-ui-model-picker-test--rows
                                                          table "openrouter sol")))
                                          (signal 'quit nil))))
                  models)))
    (should-not (nth 2 result))))

(ert-deftest harness-ui-model-picker-search-takes-a-qualified-id ()
  "A qualified id asks for its provider and its model, so choosing by
the id a test or a setting names works however the catalogue is grouped."
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: "
                    (lambda (table)
                      (should (equal '("GPT-6.1 Sol (ChatGPT)  [chatgpt:gpt-6.1-sol]")
                                     (harness-ui-model-picker-test--rows
                                      table "chatgpt:gpt-6.1-sol")))
                      (car (harness-ui-model-picker-test--rows
                            table "chatgpt:gpt-6.1-sol"))))))))
    (should (equal '("chatgpt:gpt-6.1-sol" "GPT-6.1 Sol (ChatGPT)") (nth 2 result)))))

(ert-deftest harness-ui-model-picker-search-matches-the-complexity-estimate ()
  "In a picker that ranks models, a query matches the estimate on the
row as well as the name."
  (let* ((ranked '((:id "claude:haiku" :label "Claude Haiku" :provider-label "Claude Code"
                         :complexity-label "Simple tasks")
                   (:id "chatgpt:gpt-6.1-sol" :label "GPT-6.1 Sol" :provider-label "ChatGPT"
                     :complexity-label "Complex tasks")))
         (result (harness-ui-model-picker-test--walk
                  '(("Ranked: " (lambda (table)
                                  (let ((rows (harness-ui-model-picker-test--rows table "complex")))
                                    (should (equal '("Complex tasks  GPT-6.1 Sol (ChatGPT)  [chatgpt:gpt-6.1-sol]")
                                                   rows))
                                    (car rows)))))
                  ranked t "Ranked: ")))
    (should (equal '("chatgpt:gpt-6.1-sol" "GPT-6.1 Sol (ChatGPT)") (nth 2 result)))))

(ert-deftest harness-ui-model-picker-flat-list-of-every-level ()
  "All providers lists every model in catalogue order; All models lists
the models below one provider; Back leaves either list."
  (let ((entries (harness-ui--model-picker-entries
                  (harness-ui--model-picker-records harness-ui-model-picker-test--models)
                  nil t)))
    (should (equal '("GPT-6.1 Sol (ChatGPT)  [chatgpt:gpt-6.1-sol]"
                     "GPT-6.1 Astra (ChatGPT)  [chatgpt:gpt-6.1-astra]"
                     "GPT-6 Sol (ChatGPT)  [chatgpt:gpt-6-sol]"
                     "GPT-6.1 Sol (OpenRouter)  [openrouter:openai/gpt-6.1-sol]"
                     "Llama 4 Maverick (OpenRouter)  [openrouter:meta-llama/llama-4-maverick]"
                     "Grok 4 Fast (OpenRouter)  [openrouter:x-ai/grok-4-fast]"
                     "Opus 5.5 (Claude)  [claude:claude-opus-5-5]"
                     "Unknown (Local)  [local:unknown]"
                     "Back")
                   (mapcar #'car (car entries)))))
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: " "All models")
                   ("All providers: " "\\[local:unknown\\]")))))
    (should (equal '("Model provider: " "All providers: ") (nth 0 result)))
    (should (equal '("local:unknown" "Unknown (Local)") (nth 2 result))))
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: " "ChatGPT")
                   ("Model · ChatGPT: " "All models")
                   ("All models · ChatGPT: " "Back")
                   ("Model · ChatGPT: " "Back")
                   ("Model provider: " nil)))))
    (should (equal '("Model provider: " "Model · ChatGPT: " "All models · ChatGPT: "
                     "Model · ChatGPT: " "Model provider: ")
                   (nth 0 result)))
    (should (equal '("GPT-6.1 Sol (ChatGPT)  [chatgpt:gpt-6.1-sol]"
                     "GPT-6.1 Astra (ChatGPT)  [chatgpt:gpt-6.1-astra]"
                     "GPT-6 Sol (ChatGPT)  [chatgpt:gpt-6-sol]"
                     "Back")
                   (car (nth 2 (nth 1 result)))))))

(ert-deftest harness-ui-model-picker-ranked-list-opens-flat ()
  "A picker ranking models across providers opens on the flat list in
the catalogue's order, each row led by its estimate; Back from there
offers the providers."
  (let* ((ranked '((:id "claude:haiku" :label "Claude Haiku" :provider-label "Claude Code"
                         :complexity-label "Simple tasks" :context-window 200000)
                   (:id "chatgpt:gpt-6.1-sol" :label "GPT-6.1 Sol" :provider-label "ChatGPT"
                     :complexity-label "Complex tasks" :context-window 400000)))
         (result (harness-ui-model-picker-test--walk
                  '(("Providers: " (lambda (table)
                                     (let ((rows (harness-ui-model-picker-test--rows table)))
                                       (should (equal '("Simple tasks  Haiku (Claude)  [claude:haiku]"
                                                        "Complex tasks  GPT-6.1 Sol (ChatGPT)  [chatgpt:gpt-6.1-sol]"
                                                        "Back")
                                                      rows))
                                       "Back")))
                    ("Model provider: " nil))
                  ranked t "Providers: ")))
    (should (equal '("Providers: " "Model provider: ") (nth 0 result)))
    (should-not (nth 2 result))
    ;; The ranked list keeps the catalogue's order and its estimates.
    (should (equal '("Simple tasks  Haiku (Claude)  [claude:haiku]"
                     "Complex tasks  GPT-6.1 Sol (ChatGPT)  [chatgpt:gpt-6.1-sol]"
                     "Back")
                   (car (nth 0 (nth 1 result)))))))

(ert-deftest harness-ui-model-picker-equal-provider-labels-stay-apart ()
  "Two providers with the same label are told apart by id at the root."
  (let ((result (harness-ui-model-picker-test--walk
                 '(("Model provider: " nil))
                 '((:id "work:a" :label "A" :provider-label "Custom")
                   (:id "home:b" :label "B" :provider-label "Custom")))))
    (should (equal '("Custom (home)" "Custom (work)" "All models")
                   (car (nth 0 (nth 1 result)))))))

(ert-deftest harness-ui-model-picker-empty-quit-and-no-models-choose-nothing ()
  "No models, an empty answer and a quit never choose a model, and the
echo area says what happened in nouns."
  (let ((said nil) (picked nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args) (push (apply #'format format-string args) said))))
      (harness-ui-read-model nil (lambda (&rest _) (setq picked t)))
      (should (equal '("No available models") said))
      (setq said nil)
      (let ((result (harness-ui-model-picker-test--walk '(("Model provider: " empty)))))
        (should-not (nth 2 result)))
      (should (equal '("No model chosen") said))
      (should-not picked)
      (setq said nil)
      (let ((result (harness-ui-model-picker-test--walk '(("Model provider: " nil)))))
        (should-not (nth 2 result)))
      (should-not picked)
      (should-not said))))

(ert-deftest harness-ui-model-picker-default-refreshes-and-reports-errors ()
  "Opening the default picker asks providers for a fresh listing, shows
which state it is in, and chooses nothing when the catalogue fails."
  (let ((refresh nil) (said nil) (read nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args) (push (apply #'format format-string args) said)))
              ((symbol-function 'frame-live-p) (lambda (_frame) t))
              ((symbol-function 'harness-ui--in-frame) (lambda (_frame fn) (funcall fn)))
              ((symbol-function 'harness-ui-refresh-models)
               (lambda (callback _on-error &optional fresh)
                 (setq refresh fresh)
                 (funcall callback harness-ui-model-picker-test--models)))
              ((symbol-function 'harness-ui-read-model)
               (lambda (models callback)
                 (setq read models)
                 (funcall callback "local:unknown" "Unknown (Local)"))))
      (harness-ui--choose-model #'ignore))
    (should refresh)
    (should (equal harness-ui-model-picker-test--models read))
    (should (equal '("Model catalogue loading…") said))
    (setq said nil)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args) (push (apply #'format format-string args) said)))
              ((symbol-function 'harness-ui-refresh-models)
               (lambda (_callback on-error &optional _fresh)
                 (funcall on-error '(boom)))))
      (harness-ui--choose-model #'ignore))
    (should (equal '("Model catalogue unavailable" "Model catalogue loading…") said))))

(ert-deftest harness-ui-model-picker-categories-cover-known-families ()
  "Families are inferred from names: GPT versions, Claude families,
Gemini and DeepSeek versions, and the vendor word of other models.
Unknown names and names of a kind, not a family, stay ungrouped."
  (should (equal '("GPT 6.1") (harness-ui-model-groups '(:id "chatgpt:gpt-6.1-sol"))))
  (should (equal '("GPT 6") (harness-ui-model-groups '(:id "chatgpt:gpt-6-sol"))))
  (should (equal '("GPT 5.6") (harness-ui-model-groups '(:id "chatgpt:gpt-5.6-luna"))))
  (should (equal '("GPT 6.1")
                 (harness-ui-model-groups '(:id "openrouter:openai/gpt-6.1-sol"))))
  (should (equal '("Claude Opus") (harness-ui-model-groups '(:id "claude:claude-opus-5-5"))))
  (should (equal '("Claude Sonnet") (harness-ui-model-groups '(:id "claude:sonnet"))))
  (should (equal '("Gemini 3") (harness-ui-model-groups '(:id "gemini:gemini-3-pro"))))
  (should (equal '("DeepSeek") (harness-ui-model-groups '(:id "deepseek:deepseek-flash"))))
  (should (equal '("DeepSeek V4") (harness-ui-model-groups '(:id "deepseek:deepseek-v4-pro"))))
  (should (equal '("Llama")
                 (harness-ui-model-groups '(:id "openrouter:meta-llama/llama-4-maverick"))))
  (should (equal '("Qwen3") (harness-ui-model-groups '(:id "openrouter:qwen/qwen3-235b-a22b"))))
  (should (equal '("Grok") (harness-ui-model-groups '(:id "openrouter:x-ai/grok-4-fast"))))
  (should (equal '("GPT") (harness-ui-model-groups '(:id "local:gpt-oss-120b"))))
  ;; An alias is grouped by what it resolves to.
  (should (equal '("Claude Opus")
                 (harness-ui-model-groups '(:id "claude:default" :resolves-to "claude-opus-5-5"))))
  ;; No family: a name no rule knows, a kind of model, or a single word.
  (should-not (harness-ui-model-groups '(:id "local:unknown")))
  (should-not (harness-ui-model-groups '(:id "openai:text-embedding-3-large")))
  (should-not (harness-ui-model-groups '(:id "local:o3")))
  ;; A catalogue's own categories come first, then its family.
  (should (equal '("Work" "wide")
                 (harness-ui-model-groups '(:id "local:x" :groups ("Work" "wide")))))
  (should (equal '("Reasoning")
                 (harness-ui-model-groups '(:id "local:x" :family "Reasoning")))))

(ert-deftest harness-ui-model-picker-category-function-can-be-flat-or-failing ()
  "Setting the grouping option to nil lists models directly under each
provider, and a failing category function falls back to that instead of
breaking the picker."
  (let ((harness-ui-model-group-function nil))
    (let* ((records (harness-ui--model-picker-records
                     '((:id "demo:a" :label "A" :provider-label "Demo")
                       (:id "demo:b" :label "B" :provider-label "Demo")))))
      (should (equal '("Demo" "All models")
                     (mapcar #'car (car (harness-ui--model-picker-entries records nil nil)))))
      (should (equal '("A (Demo)  [demo:a]" "B (Demo)  [demo:b]" "Back")
                     (mapcar #'car (car (harness-ui--model-picker-entries
                                         records '("Demo") nil)))))))
  (cl-letf (((symbol-function 'harness-log) #'ignore))
    (let ((harness-ui-model-group-function (lambda (_model) (error "broken"))))
      (should (equal '("Demo" "All models")
                     (mapcar #'car
                             (car (harness-ui--model-picker-entries
                                   (harness-ui--model-picker-records
                                    '((:id "demo:a" :label "A" :provider-label "Demo")))
                                   nil nil))))))))

(ert-deftest harness-ui-model-picker-labels-read-as-model-and-provider ()
  "The row names the real model and provider, and drops a provider word
the parenthetical already says."
  (should (equal "GPT-6.1 Sol (ChatGPT)"
                 (harness-ui-model-display-label
                  '(:id "chatgpt:gpt-6.1-sol" :label "GPT-6.1 Sol" :provider-label "ChatGPT"))))
  (should (equal "Opus 5.5 (Claude)"
                 (harness-ui-model-display-label
                  '(:id "claude:claude-opus-5-5" :label "Claude Opus 5.5"
                    :provider-label "Claude Code"))))
  ;; A model without a label is prettified, else read as its name.
  (should (equal "Opus 5.5 (Claude)"
                 (harness-ui-model-display-label '(:id "claude:claude-opus-5-5"
                                                   :provider-label "Claude Code"))))
  (should (equal "gpt-oss (Local)"
                 (harness-ui-model-display-label '(:id "local:gpt-oss")))))

(defconst harness-ui-model-picker-test--copy
  '("Model provider: "
    "Model · ChatGPT: "
    "Model · ChatGPT / GPT 6.1: "
    "All models · ChatGPT: "
    "All providers: "
    "All models"
    "Back"
    "All providers"
    "Flat list"
    "Parent category"
    "3 models"
    "2 models"
    "1 model"
    "GPT 6.1"
    "400k ctx"
    "400k ctx · $1/$2 per M"
    "1.00M ctx"
    "1.05M ctx"
    "200k ctx"
    "2.00M ctx"
    "8.0k ctx")
  "Every authored word the picker shows: prompts, entries and annotations.
The echo-area states are asserted where they are said, in
`harness-ui-model-picker-empty-quit-and-no-models-choose-nothing' and
`harness-ui-model-picker-default-refreshes-and-reports-errors'.")

(defun harness-ui-model-picker-test--shown (script &optional all)
  "Return every prompt, row and annotation the picker shows following SCRIPT.
ALL opens on the flat list, as the ranked picker does."
  (let ((result (harness-ui-model-picker-test--walk script nil all)))
    (append (nth 0 result)
            (apply #'append (mapcar (lambda (step) (append (car step) (cadr step)))
                                    (nth 1 result))))))

(ert-deftest harness-ui-model-picker-copy-is-nouns-and-noun-phrases ()
  "The picker's prompts, entries and annotations are exactly the listed
nouns and noun phrases: no sentence grows in."
  (let ((shown (append
                (harness-ui-model-picker-test--shown
                 '(("Model provider: " "ChatGPT")
                   ("Model · ChatGPT: " "GPT 6\\.1")
                   ("Model · ChatGPT / GPT 6.1: " nil)))
                (harness-ui-model-picker-test--shown
                 '(("Model provider: " "All models")
                   ("All providers: " "Back")
                   ("Model provider: " nil)))
                (harness-ui-model-picker-test--shown
                 '(("Model provider: " "ChatGPT")
                   ("Model · ChatGPT: " "All models")
                   ("All models · ChatGPT: " "Back")
                   ("Model · ChatGPT: " "Back")
                   ("Model provider: " nil)))
                ;; The ranked picker opens flat, with the same default heading.
                (harness-ui-model-picker-test--shown
                 '(("All providers: " nil)) t))))
    ;; Every authored word shown is one of the listed nouns.  A model row
    ;; is the catalogue's own name and id, which the picker does not word.
    (let ((catalogue '("ChatGPT" "Claude Code" "Local" "OpenRouter"))
          unknown)
      (dolist (text shown)
        (when (and (stringp text) (not (string-empty-p text)))
          (unless (or (member (string-trim text) catalogue)
                      (string-match-p "  \\[[^]]+\\]\\'" text)
                      (cl-some (lambda (word) (equal (string-trim text) (string-trim word)))
                               harness-ui-model-picker-test--copy))
            (push text unknown))))
      (should (equal nil unknown)))
    ;; And each listed word is one the picker shows.
    (let (missing)
      (dolist (text harness-ui-model-picker-test--copy)
        (unless (cl-some (lambda (s) (and (stringp s) (equal (string-trim s) (string-trim text))))
                         shown)
          (push text missing)))
      (should (equal nil missing)))))

(provide 'harness-ui-model-picker-test)
;;; harness-ui-model-picker-test.el ends here
