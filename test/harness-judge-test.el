;;; harness-judge-test.el --- Judges: one-off questions to a cheap model, with lookups  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-judge-ask' asks a stub provider, `judge', whose cheap tier
;; is judge:small and which replies what each test scripts.  A scripted
;; `tool-call' marked `:hosted' is sent with a `:respond', as a provider
;; that runs the tool loop itself sends it, and the events after it
;; wait for the result; one without is a native loop's call, which the
;; judge answers with a request of its own.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-providers)
(defvar harness-model)
(defvar harness-judge-lookup-max-chars)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-judge-ask "harness-judge")
(declare-function harness-judge-model "harness-judge" (session &optional model))

(defvar harness-judge-test--replies nil
  "What the stub replies, one list of events per request, in order.")

(defvar harness-judge-test--requests nil
  "The requests the stub got, newest first.")

(defvar harness-judge-test--responses nil
  "What hosted calls were answered with, newest first, as (ID . RESULT).")

(defvar harness-judge-test--cancelled nil
  "Non-nil once a request to the stub was cancelled.")

(defvar harness-judge-test--looked-up nil
  "The inputs the lookup `lookup' ran with, newest first.")

;;;; The provider, a stub

(defun harness-judge-test--reply (text &optional stop-reason)
  "Return the events of a reply of TEXT that ends at STOP-REASON."
  (list (list :type 'text :delta text)
        (list :type 'done :stop-reason (or stop-reason 'end-turn))))

(defun harness-judge-test--says (&rest replies)
  "Have the stub answer REPLIES, one per request, in order.
Each is a list of events; a request past the last gets no reply."
  (setq harness-judge-test--replies replies
        harness-judge-test--requests nil
        harness-judge-test--responses nil
        harness-judge-test--cancelled nil
        harness-judge-test--looked-up nil))

(defun harness-judge-test--play (events on-event)
  "Deliver EVENTS to ON-EVENT in order, as a provider's events come.
A `tool-call' marked `:hosted' is sent with a `:respond' that records
the result it gets and then delivers the events after it: a hosted
loop waits for each result before it goes on."
  (catch 'wait
    (while events
      (let ((ev (pop events)))
        (if (not (plist-get ev :hosted))
            (funcall on-event ev)
          (let ((rest events) (id (plist-get ev :id)))
            (funcall on-event
                     (append (harness-plist-remove ev :hosted)
                             (list :respond
                                   (lambda (result)
                                     (push (cons id result) harness-judge-test--responses)
                                     (run-at-time 0.01 nil #'harness-judge-test--play rest on-event)))))
            (throw 'wait nil)))))))

(defun harness-judge-test--define-provider ()
  "Define the provider `judge', whose cheap tier is judge:small.
Each request gets the next of `harness-judge-test--replies', from a
timer, as a provider's events come."
  (harness-define-provider 'judge
    :label "Judge"
    :models (lambda () (harness-resolved (list (list :name "big" :pricing '(:input 10.0 :output 50.0))
                                               (list :name "small" :pricing '(:input 1.0 :output 5.0)))))
    :tiers '(:cheap "small")
    :complete (lambda (req)
                (push req harness-judge-test--requests)
                (let ((events (pop harness-judge-test--replies))
                      (on-event (plist-get req :on-event)))
                  (when events
                    (run-at-time 0.01 nil #'harness-judge-test--play events on-event)))
                (list :cancel (lambda () (setq harness-judge-test--cancelled t))))))

(defmacro harness-judge-test--with (&rest body)
  "Run BODY with the stub provider `judge', which replies nothing until told."
  (declare (indent 0))
  `(progn
     (harness-test-reset-bus)
     (dolist (m '(project config provider judge))
       (harness-test-load-module m))
     (harness-test-with-temp-state
       (harness-judge-test--define-provider)
       (harness-judge-test--says)
       (unwind-protect (progn ,@body)
         (remhash 'judge harness-providers)
         (harness-provider--forget 'judge)))))

;;;; Asking

(defun harness-judge-test--ask (&rest args)
  "Ask a judge for session s1, which runs on judge:big, with ARGS.
Return its answer."
  (harness-test-await
   (apply #'harness-judge-ask :session (list :id "s1" :cwd default-directory :model "judge:big") args)
   10))

(defun harness-judge-test--parse (text)
  "Return the word TEXT answers with, as \"answer: WORD\", as a symbol, or nil."
  (and (stringp text)
       (string-match "answer: \\([a-z]+\\)" text)
       (intern (match-string 1 text))))

(defun harness-judge-test--tool (&optional handler)
  "Return the lookup `lookup', which says what a word means.
It records its input, then answers \"WORD means 42\" for the input's
:word, or what HANDLER, a function of the input, returns."
  (list :name "lookup" :description "Look up what a word means."
        :schema '(:type "object" :properties (:word (:type "string")) :required ("word"))
        :handler (lambda (input)
                   (push input harness-judge-test--looked-up)
                   (if handler
                       (funcall handler input)
                     (format "%s means 42" (plist-get input :word))))))

(defun harness-judge-test--results (request)
  "Return the tool results REQUEST's last message holds."
  (plist-get (car (last (plist-get request :messages))) :content))

;;;; Without lookups

(ert-deftest harness-judge-asks-the-cheap-tier-once ()
  "A judge is one request to the cheap tier of the session's model:
ephemeral, without thinking or tools, under a session id of its own, in
the session's place; the value is what PARSE reads in the reply."
  (harness-judge-test--with
    (harness-judge-test--says (harness-judge-test--reply "answer: yes"))
    (should (equal '(:value yes :text "answer: yes" :lookups 0)
                   (harness-judge-test--ask :system "Be brief." :prompt "Is it?"
                                            :parse #'harness-judge-test--parse)))
    (should (= 1 (length harness-judge-test--requests)))
    (let ((req (car harness-judge-test--requests)))
      (should (equal "judge:small" (plist-get req :model)))
      (should (eq t (plist-get req :ephemeral)))
      (should (eq t (plist-get req :no-thinking)))
      (should-not (plist-get req :tools))
      (should (equal 200 (plist-get req :max-tokens)))
      (should (equal (list :id "s1-judge" :cwd default-directory :host nil) (plist-get req :session)))
      (should (equal "Be brief." (plist-get req :system)))
      (should (equal '((:role user :content ((:type "text" :text "Is it?"))))
                     (plist-get req :messages))))
    ;; Tools without a budget are not offered; the suffix names the session.
    (harness-judge-test--says (harness-judge-test--reply "answer: no"))
    (should (eq 'no (plist-get (harness-judge-test--ask :prompt "Is it?" :parse #'harness-judge-test--parse
                                                        :tools (list (harness-judge-test--tool))
                                                        :suffix "watch" :max-tokens 50)
                               :value)))
    (let ((req (car harness-judge-test--requests)))
      (should-not (plist-get req :tools))
      (should (equal 50 (plist-get req :max-tokens)))
      (should (equal "s1-watch" (plist-get (plist-get req :session) :id))))
    ;; Without PARSE, the value is the reply itself.
    (harness-judge-test--says (harness-judge-test--reply "  Sure.\n"))
    (should (equal "Sure." (plist-get (harness-judge-test--ask :prompt "Is it?") :value)))))

(ert-deftest harness-judge-model-is-the-cheap-tier ()
  "A judge asks the cheap tier of the model it is given, else of the
session's model, else of `harness-model'; a provider without a cheap
tier is asked with that model itself.  A session may be named by id."
  (harness-judge-test--with
    (let ((cwd default-directory))
      (should (equal "judge:small" (harness-judge-model (list :id "s1" :cwd cwd :model "judge:big"))))
      (should (equal "judge:small" (harness-judge-model (list :id "s1" :cwd cwd :model "nobody:x") "judge:big")))
      (should (equal "nobody:x" (harness-judge-model (list :id "s1" :cwd cwd :model "nobody:x"))))
      (let ((harness-model "judge:big"))
        (should (equal "judge:small" (harness-judge-model (list :id "s1" :cwd cwd)))))
      (let ((harness-model nil))
        (should-not (harness-judge-model (list :id "s1" :cwd cwd))))
      (harness-register-method 'session/get (lambda (id) (list :id id :cwd cwd :model "judge:big")))
      (should (equal "judge:small" (harness-judge-model "s9")))
      (harness-judge-test--says (harness-judge-test--reply "answer: yes"))
      (should (eq 'yes (plist-get (harness-test-await
                                   (harness-judge-ask :session "s9" :prompt "?" :parse #'harness-judge-test--parse))
                                  :value)))
      (should (equal "s9-judge" (plist-get (plist-get (car harness-judge-test--requests) :session) :id))))))

(ert-deftest harness-judge-says-why-it-gave-no-value ()
  "No value comes with why: a reply PARSE finds nothing in (or a PARSE
that fails), an empty reply, a failed request, a stop, a provider the
harness does not have, a request that signals, no model at all."
  (harness-judge-test--with
    (pcase-dolist (`(,reply ,why)
                   `((,(harness-judge-test--reply "I think it is fine.")
                      "its answer held no verdict: I think it is fine.")
                     (,(harness-judge-test--reply "") "it gave no answer")
                     (((:type done :stop-reason error :error "overloaded")) "it failed: overloaded")
                     (,(harness-judge-test--reply "Hm" 'cancelled) "it stopped: cancelled")))
      (harness-judge-test--says reply)
      (let ((answer (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse)))
        (should-not (plist-get answer :value))
        (should (equal why (plist-get answer :reason)))))
    (harness-judge-test--says (harness-judge-test--reply "answer: yes"))
    (should (equal "its answer held no verdict: answer: yes"
                   (plist-get (harness-judge-test--ask :prompt "?" :parse (lambda (_) (error "Bad parser")))
                              :reason)))
    (harness-judge-test--says)
    (should (equal "it failed: No provider for model nobody:x"
                   (plist-get (harness-judge-test--ask :prompt "?" :model "nobody:x") :reason)))
    (let ((harness-model nil))
      (should (equal '(:value nil :reason "no model could be asked" :text "" :lookups 0)
                     (harness-test-await (harness-judge-ask :session (list :id "s1" :cwd default-directory)
                                                            :prompt "?")))))
    (should-not harness-judge-test--requests)
    (harness-register-method 'provider/complete (lambda (_request) (error "Broken provider")))
    (should (equal "it failed: Broken provider"
                   (plist-get (harness-judge-test--ask :prompt "?") :reason)))))

(ert-deftest harness-judge-gives-up-on-a-judge-that-takes-too-long ()
  "A judge that does not answer in time gives no value, and its request
is cancelled; one whose lookup never answers asks nothing more."
  (harness-judge-test--with
    (let* ((start (float-time))
           (answer (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse :timeout 0.2)))
      (should (equal '(:value nil :reason "it took longer than 0.2s" :text "" :lookups 0) answer))
      (should (< (- (float-time) start) 5)))
    (should harness-judge-test--cancelled)
    (harness-judge-test--says
     (list '(:type tool-call :id "c1" :name "lookup" :input (:word "foo"))
           '(:type done :stop-reason tool-use))
     (harness-judge-test--reply "answer: yes"))
    (let ((answer (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                           :timeout 0.3 :max-lookups 1
                                           :tools (list (harness-judge-test--tool
                                                         (lambda (_) (harness-make-promise)))))))
      (should (equal "it took longer than 0.3s" (plist-get answer :reason)))
      (should (= 1 (plist-get answer :lookups))))
    (harness-test-wait (lambda () (sit-for 0.1) t))
    (should (= 1 (length harness-judge-test--requests)))))

(ert-deftest harness-judge-asks-again-when-it-ran-out-of-tokens ()
  "A reply cut off before it held a value is asked for once more, with
the retry's budget when there is one; a value written before the cap
stands.  In a native loop the retry keeps the lookups made."
  (harness-judge-test--with
    (harness-judge-test--says
     (harness-judge-test--reply "Let me think" 'max-tokens)
     (harness-judge-test--reply "answer: yes"))
    (should (eq 'yes (plist-get (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                                         :max-tokens 50 :retry-max-tokens 500)
                                :value)))
    (should (equal '(500 50) (mapcar (lambda (r) (plist-get r :max-tokens)) harness-judge-test--requests)))
    ;; Without a retry budget, or cut off again, it stops there.
    (harness-judge-test--says (harness-judge-test--reply "Let me think" 'max-tokens))
    (should (equal "it stopped: max-tokens"
                   (plist-get (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse) :reason)))
    (should (= 1 (length harness-judge-test--requests)))
    (harness-judge-test--says
     (harness-judge-test--reply "Let me think" 'max-tokens)
     (harness-judge-test--reply "Still thinking" 'max-tokens))
    (should (equal "it stopped: max-tokens"
                   (plist-get (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                                       :retry-max-tokens 500)
                              :reason)))
    (should (= 2 (length harness-judge-test--requests)))
    ;; Cut off after its answer: the answer stands.
    (harness-judge-test--says (harness-judge-test--reply "answer: no, because" 'max-tokens))
    (should (eq 'no (plist-get (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                                        :retry-max-tokens 500)
                               :value)))
    (should (= 1 (length harness-judge-test--requests)))
    ;; A native loop's retry asks with the lookups made.
    (harness-judge-test--says
     (list '(:type tool-call :id "c1" :name "lookup" :input (:word "foo"))
           '(:type done :stop-reason tool-use))
     (harness-judge-test--reply "Thinking" 'max-tokens)
     (harness-judge-test--reply "answer: yes"))
    (should (eq 'yes (plist-get (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                                         :tools (list (harness-judge-test--tool)) :max-lookups 1
                                                         :retry-max-tokens 500)
                                :value)))
    (pcase-let ((`(,retry ,cut ,asked) harness-judge-test--requests))
      (should (= 3 (length (plist-get cut :messages))))
      (should (equal (plist-get cut :messages) (plist-get retry :messages)))
      (should (equal (plist-get asked :tools) (plist-get retry :tools)))
      (should (equal '(500 200 200) (mapcar (lambda (r) (plist-get r :max-tokens)) (list retry cut asked)))))))

;;;; Lookups

(ert-deftest harness-judge-looks-up-in-a-hosted-loop ()
  "A provider that runs the tool loop itself gets each lookup's result
through the call's :respond and goes on with the same request; the
answer is what the judge writes after its lookups.  The provider's own
tools are no lookups."
  (harness-judge-test--with
    (harness-judge-test--says
     (list '(:type text :delta "Let me check; answer: maybe")
           '(:type tool-call :id "b1" :name "web_search" :input (:query "foo") :builtin t)
           '(:type tool-call :id "t1" :name "lookup" :input (:word "foo") :hosted t)
           '(:type text :delta "answer: yes")
           '(:type done :stop-reason end-turn)))
    (should (equal '(:value yes :text "answer: yes" :lookups 1)
                   (harness-judge-test--ask :prompt "Is foo fine?" :parse #'harness-judge-test--parse
                                            :tools (list (harness-judge-test--tool)) :max-lookups 3)))
    (should (equal '((:word "foo")) harness-judge-test--looked-up))
    (should (equal '(("t1" :content "foo means 42" :is-error nil)) harness-judge-test--responses))
    (should (= 1 (length harness-judge-test--requests)))
    ;; The model is shown the lookup's name, description and schema.
    (should (equal '((:name "lookup" :description "Look up what a word means."
                      :schema (:type "object" :properties (:word (:type "string")) :required ("word"))))
                   (plist-get (car harness-judge-test--requests) :tools)))))

(ert-deftest harness-judge-looks-up-in-a-native-loop ()
  "A provider that stops for tool calls is asked again, with the same
tools and budget, and with the calls and their results added as a
session's transcript adds them; the answer comes from that reply."
  (harness-judge-test--with
    (harness-judge-test--says
     (list '(:type thinking :delta "Two words.")
           '(:type text :delta "Looking them up.")
           '(:type tool-call :id "c1" :name "lookup" :input (:word "foo"))
           '(:type tool-call :id "c2" :name "lookup" :input (:word "bar"))
           '(:type done :stop-reason tool-use))
     (harness-judge-test--reply "answer: yes"))
    (should (equal '(:value yes :text "answer: yes" :lookups 2)
                   (harness-judge-test--ask :prompt "Are foo and bar fine?" :parse #'harness-judge-test--parse
                                            :tools (list (harness-judge-test--tool)) :max-lookups 3)))
    (should (equal '((:word "bar") (:word "foo")) harness-judge-test--looked-up))
    (should (= 2 (length harness-judge-test--requests)))
    (pcase-let ((`(,again ,asked) harness-judge-test--requests))
      (should (plist-get again :tools))
      (should (equal (plist-get asked :tools) (plist-get again :tools)))
      (should (equal (plist-get asked :max-tokens) (plist-get again :max-tokens)))
      (should (eq t (plist-get again :ephemeral)))
      (should (eq t (plist-get again :no-thinking)))
      (should (equal (append (plist-get asked :messages)
                             '((:role assistant
                                :content ((:type "thinking" :text "Two words.")
                                          (:type "text" :text "Looking them up.")
                                          (:type "tool_use" :id "c1" :name "lookup" :input (:word "foo"))
                                          (:type "tool_use" :id "c2" :name "lookup" :input (:word "bar"))))
                               (:role user
                                :content ((:type "tool_result" :tool_use_id "c1" :content "foo means 42"
                                                 :is_error nil)
                                          (:type "tool_result" :tool_use_id "c2" :content "bar means 42"
                                                 :is_error nil)))))
                     (plist-get again :messages))))))

(ert-deftest harness-judge-keeps-to-its-budget-of-lookups ()
  "A call past the budget gets an error result and runs nothing, in
either loop.  A native loop still asking a round past its budget gives
no value, and so does a hosted one that goes on calling, whose request
is cancelled."
  (harness-judge-test--with
    (harness-judge-test--says
     (list '(:type tool-call :id "t1" :name "lookup" :input (:word "foo") :hosted t)
           '(:type tool-call :id "t2" :name "lookup" :input (:word "bar") :hosted t)
           '(:type text :delta "answer: yes")
           '(:type done :stop-reason end-turn)))
    (should (equal '(:value yes :text "answer: yes" :lookups 1)
                   (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                            :tools (list (harness-judge-test--tool)) :max-lookups 1)))
    (should (equal '((:word "foo")) harness-judge-test--looked-up))
    (let ((over (cdr (assoc "t2" harness-judge-test--responses))))
      (should (plist-get over :is-error))
      (should (string-prefix-p "No more lookups: " (plist-get over :content))))
    ;; Native: two calls in the first round, one of them too many, then
    ;; still asking in the round after.
    (harness-judge-test--says
     (list '(:type tool-call :id "c1" :name "lookup" :input (:word "foo"))
           '(:type tool-call :id "c2" :name "lookup" :input (:word "bar"))
           '(:type done :stop-reason tool-use))
     (list '(:type tool-call :id "c3" :name "lookup" :input (:word "baz"))
           '(:type done :stop-reason tool-use))
     (harness-judge-test--reply "answer: yes"))
    (let ((answer (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                           :tools (list (harness-judge-test--tool)) :max-lookups 1)))
      (should-not (plist-get answer :value))
      (should (equal "it kept asking for lookups past its budget of 1" (plist-get answer :reason)))
      (should (= 1 (plist-get answer :lookups))))
    (should (equal '((:word "foo")) harness-judge-test--looked-up))
    (should (= 2 (length harness-judge-test--requests)))
    (let ((results (harness-judge-test--results (car harness-judge-test--requests))))
      (should-not (plist-get (nth 0 results) :is_error))
      (should (plist-get (nth 1 results) :is_error))
      (should (string-prefix-p "No more lookups: " (plist-get (nth 1 results) :content))))
    ;; Hosted, calling on and on.
    (harness-judge-test--says
     (list '(:type tool-call :id "t1" :name "lookup" :input (:word "a") :hosted t)
           '(:type tool-call :id "t2" :name "lookup" :input (:word "b") :hosted t)
           '(:type tool-call :id "t3" :name "lookup" :input (:word "c") :hosted t)
           '(:type tool-call :id "t4" :name "lookup" :input (:word "d") :hosted t)
           '(:type text :delta "answer: yes")
           '(:type done :stop-reason end-turn)))
    (let ((answer (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                           :tools (list (harness-judge-test--tool)) :max-lookups 1)))
      (should-not (plist-get answer :value))
      (should (equal "it kept asking for lookups past its budget of 1" (plist-get answer :reason))))
    (should (equal '((:word "a")) harness-judge-test--looked-up))
    (should (equal '("t4" "t3" "t2" "t1") (mapcar #'car harness-judge-test--responses)))
    (should harness-judge-test--cancelled)))

(ert-deftest harness-judge-tells-the-judge-when-a-lookup-fails ()
  "A call of a tool the judge was not given, a handler that signals, one
whose promise rejects and one that returns an error result each give
the judge an error result that says why, and it goes on; a long result
is cut."
  (harness-judge-test--with
    (let ((tools (list (harness-judge-test--tool)
                       (list :name "boom" :description "Fails."
                             :handler (lambda (_) (error "Boom %d" 1)))
                       (list :name "gone" :description "Rejects."
                             :handler (lambda (_) (harness-rejected '(harness-error "it went away"))))
                       (list :name "no" :description "Refuses."
                             :handler (lambda (_) '(:content "Not here" :is-error t)))
                       (list :name "long" :description "Says a lot."
                             :handler (lambda (_) (harness-resolved (make-string 5000 ?x)))))))
      (harness-judge-test--says
       (list '(:type tool-call :id "c1" :name "nope" :input (:word "x"))
             '(:type tool-call :id "c2" :name "boom" :input nil)
             '(:type tool-call :id "c3" :name "gone" :input nil)
             '(:type tool-call :id "c4" :name "no" :input nil)
             '(:type tool-call :id "c5" :name "long" :input nil)
             '(:type done :stop-reason tool-use))
       (harness-judge-test--reply "answer: yes"))
      (let ((answer (harness-judge-test--ask :prompt "?" :parse #'harness-judge-test--parse
                                             :tools tools :max-lookups 5)))
        (should (eq 'yes (plist-get answer :value)))
        (should (= 4 (plist-get answer :lookups))))
      (let* ((results (harness-judge-test--results (car harness-judge-test--requests)))
             (result (lambda (id) (cl-find id results :key (lambda (r) (plist-get r :tool_use_id))
                                           :test #'equal)))
             (cut (format "\n[cut at %d characters]" harness-judge-lookup-max-chars)))
        (should (equal "There is no lookup named nope; the lookups are lookup, boom, gone, no, long."
                       (plist-get (funcall result "c1") :content)))
        (should (equal "The lookup failed: Boom 1" (plist-get (funcall result "c2") :content)))
        (should (equal "The lookup failed: it went away" (plist-get (funcall result "c3") :content)))
        (should (equal "Not here" (plist-get (funcall result "c4") :content)))
        (dolist (id '("c1" "c2" "c3" "c4"))
          (should (eq t (plist-get (funcall result id) :is_error))))
        (let ((long (funcall result "c5")))
          (should-not (plist-get long :is_error))
          (should (equal (concat (make-string harness-judge-lookup-max-chars ?x) cut)
                         (plist-get long :content)))))
      ;; The tool_use of a call without input says {}.
      (should (eq :empty (plist-get (nth 1 (plist-get (nth 1 (plist-get (car harness-judge-test--requests)
                                                                          :messages))
                                                       :content))
                                    :input))))))

(provide 'harness-judge-test)
;;; harness-judge-test.el ends here
