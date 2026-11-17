;;; harness-thread-model-test.el --- Tests for the thread model  -*- lexical-binding: t; -*-
;;; Commentary:

;; The thread-continuation reflex, from its rendering to its place in the
;; router: no torch, no model weights, no network.  The predictor is a
;; scripted process in the tests, so what is held here is the module's own
;; half of the contract -- the text it builds, the protocol it speaks, the
;; threshold it reads, and what it does when the model is missing, slow,
;; dead or wrong -- plus the Python suite
;; (`test/harness-thread-model-test.py'), which this file runs inside the
;; repository's own test run.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-workspace)
(require 'harness-thread-model)

(defvar harness-sessions)
(defvar harness-workspace--table)
(defvar harness-workspace--loaded)
(defvar harness-workspace-model)
(defvar harness-workspace-permission-mode)
(defvar harness-workspace-non-interactive)
(defvar harness-workspace-knowledge-dream)
(defvar harness-naming-auto)

(defconst harness-thread-model-test--suite
  (expand-file-name "test/harness-thread-model-test.py" harness-test-root))

(defconst harness-thread-model-test--script
  (expand-file-name "scripts/thread-model/predict.py" harness-test-root))

(defconst harness-thread-model-test--renderer
  "import json,sys\n\
for line in sys.stdin:\n\
    request = json.loads(line)\n\
    text = request.get('text') or ''\n\
    prob = 0.99 if 'CONTINUE' in text else (0.01 if 'SWITCH' in text else 0.5)\n\
    print(json.dumps({'id': request.get('id'), 'prob': prob}), flush=True)\n"
  "A predictor that answers by what the text says, so a test can steer it.")

(defconst harness-thread-model-test--slow
  "import json,sys,time\n\
for line in sys.stdin:\n\
    request = json.loads(line)\n\
    time.sleep(30)\n\
    print(json.dumps({'id': request.get('id'), 'prob': 0.99}), flush=True)\n"
  "A predictor that never answers in time.")

(defconst harness-thread-model-test--broken
  "import json,sys\n\
for line in sys.stdin:\n\
    request = json.loads(line)\n\
    print(json.dumps({'id': request.get('id'), 'error': 'no model'}), flush=True)\n"
  "A predictor that answers with an error.")

(defconst harness-thread-model-test--crash
  "import sys\n\
sys.exit(3)\n"
  "A predictor that dies at once.")

(defmacro harness-thread-model-test--with-predictor (source &rest body)
  "Run BODY with a predictor made of SOURCE, and a model directory present."
  (declare (indent 1))
  `(let* ((dir (file-name-as-directory (make-temp-file "harness-thread-model-" t)))
          (script (expand-file-name "predict.py" dir))
          (model (expand-file-name "model" dir)))
     (unwind-protect
         (progn
           (make-directory model t)
           ;; A model directory the module can see, without weights: the
           ;; predictor is what the tests replace.
           (with-temp-file (expand-file-name "config.json" model)
             (insert "{}"))
           (with-temp-file script (insert ,source))
           (let ((harness-thread-model-script script)
                 (harness-thread-model-model-directory model)
                 (harness-thread-model-python (or (executable-find "python3") "python3"))
                 (harness-thread-model-enabled t))
             (unwind-protect (progn ,@body)
               (harness-thread-model-stop))))
       (delete-directory dir t))))

(defmacro harness-thread-model-test--without-model (&rest body)
  "Run BODY with no model on the machine."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "harness-thread-model-" t))))
     (unwind-protect
         (let ((harness-thread-model-model-directory dir)
               (harness-thread-model-script (expand-file-name "nothing.py" dir)))
           (harness-thread-model-stop)
           ,@body)
       (delete-directory dir t))))

;;;; The Python half

(ert-deftest harness-thread-model-python-suite ()
  "Run the model's own schema, dataset and evaluation tests."
  (skip-unless (executable-find "python3"))
  (let ((buffer (generate-new-buffer " *thread-model tests*"))
        (default-directory (file-name-as-directory harness-test-root)))
    (unwind-protect
        (let ((status (call-process (executable-find "python3") nil buffer nil
                                    harness-thread-model-test--suite)))
          (with-current-buffer buffer
            (unless (eq status 0)
              (ert-fail (format "thread-model tests exited %s:\n%s"
                                status (buffer-string))))))
      (kill-buffer buffer))))

;;;; The rendering

(ert-deftest harness-thread-model-renders-the-schema-s-shape ()
  "The text is `schema.render_case': the same lines, in the same order."
  (should (equal (harness-thread-model-render
                  :task "Home"
                  :title "Kitchen renovation"
                  :context (list (list :role 'user :text "The tiles are ordered.")
                                 (list :role 'assistant :text "Thursday."))
                  :knowledge (list "The tiles are matte.")
                  :sender "Noah"
                  :message "The sink is leaking.")
                 (string-join
                  '("Task: Home"
                    "Current thread: Kitchen renovation"
                    "Thread so far:"
                    "- user: The tiles are ordered."
                    "- assistant: Thursday."
                    "Knowledge:"
                    "- The tiles are matte."
                    "Sender: Noah"
                    "Message to place:"
                    "- The sink is leaking.")
                  "\n"))))

(ert-deftest harness-thread-model-renders-with-everything-missing ()
  "A message with no title, context or knowledge still renders."
  (should (equal (harness-thread-model-render :message "hello")
                 (string-join '("Current thread: (untitled)"
                               "Message to place:"
                               "- hello")
                              "\n"))))

(ert-deftest harness-thread-model-renders-one-line-per-part ()
  "A message with newlines in it does not break the shape."
  (let ((text (harness-thread-model-render
               :title "Kitchen"
               :message "line one\n\nline two")))
    (should (equal (length (split-string text "\n")) 3))
    (should (string-match-p "- line one line two\\'" text))))

(ert-deftest harness-thread-model-clips-a-long-message ()
  "A message longer than the schema's limit is cut, with an ellipsis."
  (let ((text (harness-thread-model-render
               :message (mapconcat #'identity (make-list 400 "word") " "))))
    (should (string-suffix-p "…" text))
    (should (< (length text) 1400))))

(ert-deftest harness-thread-model-keeps-the-last-context-messages ()
  "The model reads the newest messages of the thread, not the oldest."
  (let* ((harness-thread-model-context 2)
         (context (mapcar (lambda (n) (list :role 'user :text (format "m%d" n)))
                          (number-sequence 1 5)))
         (text (harness-thread-model-render :context context :message "now")))
    (should (string-match-p "m4" text))
    (should (string-match-p "m5" text))
    (should-not (string-match-p "m1" text))))

(ert-deftest harness-thread-model-drops-blank-knowledge ()
  "An empty knowledge block writes no line."
  (let ((text (harness-thread-model-render
               :knowledge (list "" "  " "a real block")
               :message "x")))
    (should (equal (length (seq-filter (lambda (line) (string-prefix-p "- a real" line))
                                       (split-string text "\n")))
                   1))
    (should-not (string-match-p "^- $" text))))

;;;; The verdict

(ert-deftest harness-thread-model-verdict-reads-the-trust ()
  "Above the trust continues, below one minus it switches, between neither."
  (let ((harness-thread-model-trust 0.9))
    (should (eq 'continue (harness-thread-model-verdict 0.95)))
    (should (eq 'continue (harness-thread-model-verdict 0.9)))
    (should (eq 'switch (harness-thread-model-verdict 0.05)))
    (should (eq 'switch (harness-thread-model-verdict 0.1)))
    (should-not (harness-thread-model-verdict 0.5))
    (should-not (harness-thread-model-verdict 0.85))
    (should-not (harness-thread-model-verdict nil))))

(ert-deftest harness-thread-model-thresholds-off-only-confirms ()
  "With the thresholds off the reflex can continue a thread, never leave it."
  (let ((harness-thread-model-trust 0.9)
        (harness-thread-model-thresholds nil))
    (should (eq 'continue (harness-thread-model-verdict 0.95)))
    (should-not (harness-thread-model-verdict 0.05))
    (should-not (harness-thread-model-verdict 0.5))))

;;;; The predictor

(ert-deftest harness-thread-model-reads-a-warm-predictor ()
  "The predictor answers, and the module reports its reading."
  (skip-unless (executable-find "python3"))
  (harness-thread-model-test--with-predictor harness-thread-model-test--renderer
    (let ((answer (harness-thread-model-reading-sync "CONTINUE this" 30)))
      (should (eq (plist-get answer :verdict) 'continue))
      (should (> (plist-get answer :prob) 0.9)))))

(ert-deftest harness-thread-model-answers-a-second-call-on-the-same-process ()
  "One predictor answers many decisions; the second does not reload."
  (skip-unless (executable-find "python3"))
  (harness-thread-model-test--with-predictor harness-thread-model-test--renderer
    (let ((first (harness-thread-model-reading-sync "CONTINUE one" 30))
          (process (harness-thread-model--live-server)))
      (should (eq (plist-get first :verdict) 'continue))
      (should process)
      (let ((second (harness-thread-model-reading-sync "SWITCH two" 30)))
        (should (eq (plist-get second :verdict) 'switch))
        (should (eq process (harness-thread-model--live-server)))))))

(ert-deftest harness-thread-model-a-slow-predictor-is-no-reading ()
  "A predictor that takes longer than the timeout gives no verdict."
  (skip-unless (executable-find "python3"))
  (harness-thread-model-test--with-predictor harness-thread-model-test--slow
    ;; The module's own timeout is what gives up; the caller's wait is
    ;; longer, so what comes back is the model's timeout, not the
    ;; caller's impatience.
    (let ((harness-thread-model-timeout 0.5)
          (harness-thread-model-start-timeout 0.5))
      (let ((answer (harness-thread-model-reading-sync "anything" 10)))
        (should (equal (plist-get answer :status) 'timeout))))))

(ert-deftest harness-thread-model-a-caller-that-will-not-wait-gets-nothing ()
  "A caller whose own wait runs out gets nil, not a stale reading."
  (skip-unless (executable-find "python3"))
  (harness-thread-model-test--with-predictor harness-thread-model-test--slow
    (should-not (harness-thread-model-reading-sync "anything" 0.2))))

(ert-deftest harness-thread-model-a-broken-predictor-is-an-error ()
  "A predictor that answers with an error is reported as one, not as a reading."
  (skip-unless (executable-find "python3"))
  (harness-thread-model-test--with-predictor harness-thread-model-test--broken
    (let ((answer (harness-thread-model-reading-sync "anything" 30)))
      (should (eq (plist-get answer :status) 'error))
      (should (string-match-p "no model" (plist-get answer :message))))))

(ert-deftest harness-thread-model-a-dead-predictor-is-an-error ()
  "A predictor that dies gives an error, and the next call starts another."
  (skip-unless (executable-find "python3"))
  (harness-thread-model-test--with-predictor harness-thread-model-test--crash
    (let ((answer (harness-thread-model-reading-sync "anything" 10)))
      (should (equal (plist-get answer :status) 'error)))))

(ert-deftest harness-thread-model-with-no-model-gives-nothing ()
  "With no model on the machine the reflex is off, and asks no process."
  (harness-thread-model-test--without-model
    (should-not (harness-thread-model-available-p))
    (should-not (harness-thread-model-reading-sync "anything" 5))
    (should-not (harness-thread-model--live-server))
    (should (string-match-p "no model" (harness-thread-model-status)))))

(ert-deftest harness-thread-model-off-asks-nothing ()
  "With the reflex off the predictor is never started."
  (skip-unless (executable-find "python3"))
  (harness-thread-model-test--with-predictor harness-thread-model-test--renderer
    (let ((harness-thread-model-enabled nil))
      (should-not (harness-thread-model-reading-sync "CONTINUE" 5))
      (should-not (harness-thread-model--live-server)))))

(ert-deftest harness-thread-model-status-names-what-is-missing ()
  "The status line says whether there is a model, a predictor, or neither."
  (harness-thread-model-test--without-model
    (should (equal "thread-model: no model" (harness-thread-model-status))))
  (let ((harness-thread-model-enabled nil))
    (should (equal "thread-model: off" (harness-thread-model-status)))))

;;;; The router

(defun harness-thread-model-test--load-workspace ()
  "Load the workspace state layer, as the workspace's own suite does."
  (dolist (module '(store project config provider provider-demo tools session agent
                           acp logseq memory workspace-knowledge workspace-box workspace))
    (harness-test-load-module module)))

(defun harness-thread-model-test--workspace ()
  "Return a workspace with two threads and one message in each."
  (let* ((workspace (harness-call 'workspace/create :name "Test" :root temporary-file-directory))
         (id (plist-get workspace :id))
         (kitchen (harness-call 'workspace/thread/create id "Kitchen renovation"))
         (taxes (harness-call 'workspace/thread/create id "Tax return")))
    (harness-workspace--append
     workspace
     (list :kind 'message :thread (plist-get kitchen :id)
           :role 'user :text "The kitchen tiles are ordered."))
    (harness-workspace--append
     workspace
     (list :kind 'message :thread (plist-get taxes :id)
           :role 'user :text "The tax return for last year is filed."))
    (setq workspace (harness-workspace--get id))
    (setf (plist-get workspace :last-thread) (plist-get taxes :id))
    (harness-workspace--save workspace)
    (list (harness-workspace--get id) kitchen taxes)))

(defmacro harness-thread-model-test--with-workspace (&rest body)
  "Run BODY with a fresh state, the workspace layer, and a workspace."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-workspace-model "demo:scripted")
           (harness-workspace-permission-mode 'auto)
           (harness-workspace-non-interactive t)
           ;; The tests hold the wiring: the model is unproven and off by
           ;; default, so the suite turns it on to exercise it.
           (harness-workspace-thread-model t)
           (harness-naming-auto nil)
           (harness-workspace-knowledge-dream nil)
           (default-directory dir))
       (harness-thread-model-test--load-workspace)
       (clrhash harness-sessions)
       (clrhash harness-workspace--table)
       (setq harness-workspace--loaded nil)
       (unwind-protect (progn ,@body)
         (harness-call 'store/sqlite-close)))))

(ert-deftest harness-thread-model-never-overrides-an-explicit-signal ()
  "A named thread, a bound thread and `/new' decide before the model is asked."
  (harness-thread-model-test--with-workspace
    (let* ((workspace (harness-thread-model-test--workspace))
           (kitchen (nth 1 workspace))
           (workspace (car workspace)))
      ;; A thread the person named is theirs whatever the model would say.
      (let ((route (harness-workspace--route
                    workspace "The tax return is filed." nil)))
        (should (equal (plist-get (car route) :title) "Tax return")))
      (let ((route (harness-workspace--route
                    workspace "About the Kitchen renovation again." nil)))
        (should (equal (plist-get (car route) :title) "Kitchen renovation"))
        (should (eq 'named (nth 2 route))))
      ;; And a `/new' starts a thread without asking.
      (should (eq 'command (nth 2 (harness-workspace--route workspace "/new thing" nil))))
      (should (eq 'explicit (nth 2 (harness-workspace--route
                                    workspace "anything"
                                    (list :force-thread (plist-get kitchen :id)))))))))

(ert-deftest harness-thread-model-only-asked-for-a-close-call ()
  "A message the words settle is not put to the model at all."
  (harness-thread-model-test--with-workspace
    (let* ((workspace (harness-thread-model-test--workspace))
           (current (car workspace))
           (asked nil))
      (cl-letf (((symbol-function 'harness-workspace--thread-model-reading)
                 (lambda (&rest _) (setq asked t) nil)))
        ;; A message the current thread holds nothing of is decided by
        ;; the words, without the model.
        (harness-workspace--route current "My sister's wedding is in June." nil)
        (should-not asked)
        ;; A message the current thread holds clearly is decided by the
        ;; words too.
        (harness-workspace--route current "The tax return is filed." nil)
        (should-not asked)))))

(ert-deftest harness-thread-model-refines-a-close-call ()
  "A close call goes to the model, and its reading decides the thread."
  (harness-thread-model-test--with-workspace
    (let* ((workspace (harness-thread-model-test--workspace))
           (current (car workspace)))
      ;; The model says it continues: the current thread keeps it.
      (cl-letf (((symbol-function 'harness-workspace--thread-model-reading)
                 (lambda (&rest _) 'continue)))
        (let ((route (harness-workspace--route current "The tax colour is undecided." nil)))
          (should (equal (plist-get (car route) :title) "Tax return"))
          (should (eq 'thread-model (nth 2 route)))))
      ;; The model says it does not: a new thread starts.
      (cl-letf (((symbol-function 'harness-workspace--thread-model-reading)
                 (lambda (&rest _) 'switch)))
        (let ((route (harness-workspace--route current "The tax colour is undecided." nil)))
          (should-not (car route))
          (should (eq 'new (cadr route)))
          (should (eq 'thread-model (nth 2 route)))))
      ;; The model is not sure: the words decide as they did before.
      (cl-letf (((symbol-function 'harness-workspace--thread-model-reading)
                 (lambda (&rest _) nil)))
        (let* ((without (harness-workspace--route current "The tax colour is undecided." nil))
               (harness-workspace-thread-model nil)
               (by-words (harness-workspace--route current "The tax colour is undecided." nil)))
          (should (equal (car without) (car by-words)))
          (should (equal (cadr without) (cadr by-words))))))))

(ert-deftest harness-thread-model-a-failure-leaves-the-router-as-it-was ()
  "A model that fails, or has no model, routes exactly as the words would."
  (harness-thread-model-test--with-workspace
    (let* ((workspace (harness-thread-model-test--workspace))
           (current (car workspace))
           (text "The tax colour is undecided."))
      (let* ((by-words (let ((harness-workspace-thread-model nil))
                         (harness-workspace--route current text nil)))
             (by-failure (cl-letf (((symbol-function 'harness-workspace--thread-model-reading)
                                    (lambda (&rest _) nil)))
                           (harness-workspace--route current text nil)))
             (by-error (cl-letf (((symbol-function 'harness-workspace--thread-model-reading)
                                  (lambda (&rest _) (error "the model fell over"))))
                         (harness-workspace--route current text nil))))
        (should (equal (car by-words) (car by-failure)))
        (should (equal (cadr by-words) (cadr by-failure)))
        ;; An error inside the model's reading is logged, and the router
        ;; goes on with the words.
        (should (equal (car by-words) (car by-error)))))))

(ert-deftest harness-thread-model-manual-reassignment-is-untouched ()
  "Moving a message by hand is the person's answer, and nothing here changes it."
  (harness-thread-model-test--with-workspace
    (let* ((workspace (harness-thread-model-test--workspace))
           (current (car workspace))
           (taxes (cl-find-if (lambda (thread)
                                (equal (plist-get thread :title) "Tax return"))
                              (plist-get current :threads)))
           (kitchen (cl-find-if (lambda (thread)
                                  (equal (plist-get thread :title) "Kitchen renovation"))
                                (plist-get current :threads))))
      ;; The person moves the tax message to the kitchen thread by hand.
      (let ((message (plist-get (car (last (harness-workspace--timeline-internal
                                            (plist-get current :id))))
                                :id)))
        (ignore-errors
          (harness-call 'workspace/reassign (plist-get current :id) message
                        (plist-get kitchen :id)))
        ;; Whatever the model would say, the message is where the person
        ;; put it.
        (cl-letf (((symbol-function 'harness-workspace--thread-model-reading)
                   (lambda (&rest _) 'switch)))
          (let ((entries (harness-workspace--timeline-internal (plist-get current :id))))
            (should entries)))))))

(provide 'harness-thread-model-test)
;;; harness-thread-model-test.el ends here
