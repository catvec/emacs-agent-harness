;;; harness-naming-test.el --- Tests for session naming  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-naming--running)
(defvar harness-naming--base-system-prompt)
(defvar harness-naming-model)
(defvar harness-naming--timeout)
(defvar harness-providers)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-agent-running-p "harness-agent")
(declare-function harness-naming-sanitise "harness-naming")
(declare-function harness-naming--model "harness-naming")
(declare-function harness-naming--init "harness-naming")
(declare-function harness-naming--shutdown "harness-naming")
(declare-function harness-naming--name-running "harness-naming")

(defmacro harness-naming-test-with (&rest body)
  "Load the state layer with the demo provider and naming, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent naming))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-naming--running)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-naming-auto t)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defconst harness-naming-test-script
  '((:type text :delta "  \"Refactor the ") (:type text :delta "parser\".") (:type done :stop-reason end-turn)))

(defun harness-naming-test-session (&rest plist)
  "Create a demo session; PLIST overrides the defaults."
  (plist-get (apply #'harness-call 'session/create
                    (append plist (list :cwd (harness-test-temp-dir) :model "demo:scripted")))
             :id))

(defun harness-naming-test-answered-session (&rest plist)
  "A session with one answered exchange already in the transcript."
  (let ((id (apply #'harness-naming-test-session plist)))
    (harness-call 'session/append id '(:kind user :content "refactor the parser please"))
    (harness-call 'session/append id '(:kind assistant :content "Done."))
    id))

(defun harness-naming-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(defun harness-naming-test-hints (id)
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint)) (harness-call 'session/nodes id))))

(defun harness-naming-test-name (id)
  (plist-get (harness-call 'session/get id) :name))

(defmacro harness-naming-test-counting-completes (var &rest body)
  "Run BODY with VAR counting the provider requests made."
  (declare (indent 1))
  `(cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
              ((symbol-function 'harness-method/provider/complete)
               (lambda (req) (cl-incf ,var) (funcall orig req))))
     ,@body))

(defun harness-naming-test-naming-request (requests)
  "Return the request among REQUESTS that names a session from its first message."
  (cl-find-if (lambda (r) (plist-get r :ephemeral)) requests))

(defun harness-naming-test-opening-text (request)
  "Return the text of naming REQUEST's first block: the messages it quotes."
  (plist-get (car (plist-get (car (plist-get request :messages)) :content)) :text))

;; A provider whose turns wait for the test, for a turn that is still at
;; work while its session is named.

(defvar harness-naming-test--requests nil
  "Requests the `naming-held' provider got, newest first.")

(defvar harness-naming-test--held nil
  "Event functions of the turns the `naming-held' provider holds, newest first.")

(defvar harness-naming-test--closed nil
  "Ids the `naming-held' provider was told to free, newest first.")

(defvar harness-naming-test--cancelled 0
  "How many requests of the `naming-held' provider were cancelled.")

(defvar harness-naming-test--answer "Fix the parser"
  "What the `naming-held' provider answers a request beside a turn with.
A title, or `hold' for a model that never answers.")

(defun harness-naming-test--held-complete (request)
  "Answer REQUEST as the `naming-held' provider.
A request beside a turn (`:ephemeral') gets `harness-naming-test--answer'
at once; a turn waits until `harness-naming-test-release' ends it."
  (push request harness-naming-test--requests)
  (let ((on-event (plist-get request :on-event))
        (answer harness-naming-test--answer))
    (cond ((not (plist-get request :ephemeral)) (push on-event harness-naming-test--held))
          ((stringp answer)
           (run-at-time 0.005 nil (lambda ()
                                    (funcall on-event (list :type 'text :delta answer))
                                    (funcall on-event '(:type done :stop-reason end-turn)))))))
  (list :cancel (lambda () (cl-incf harness-naming-test--cancelled))))

(defun harness-naming-test-release ()
  "End the turn the `naming-held' provider has held the longest."
  (let ((on-event (car (last harness-naming-test--held))))
    (setq harness-naming-test--held (butlast harness-naming-test--held))
    (funcall on-event '(:type text :delta "Done."))
    (funcall on-event '(:type done :stop-reason end-turn))))

(defmacro harness-naming-test-with-held (&rest body)
  "Run BODY with the provider `naming-held' defined, then drop it.
Its models are \"big\" and \"small\", its cheap tier; see
`harness-naming-test--held-complete' for how it answers."
  (declare (indent 0))
  `(progn
     (setq harness-naming-test--requests nil
           harness-naming-test--held nil
           harness-naming-test--closed nil
           harness-naming-test--cancelled 0)
     (harness-define-provider 'naming-held
       :label "Held turns"
       :models (lambda () (harness-resolved
                           (list (list :name "big" :pricing '(:input 10.0 :output 50.0))
                                 (list :name "small" :pricing '(:input 1.0 :output 5.0)))))
       :tiers '(:cheap "small")
       :complete #'harness-naming-test--held-complete
       :close (lambda (id) (push id harness-naming-test--closed) t))
     (unwind-protect (progn ,@body)
       (remhash 'naming-held harness-providers)
       (harness-provider--forget 'naming-held))))

(ert-deftest harness-naming-sanitise ()
  (should (equal "Refactor the parser" (harness-naming-sanitise "  \"Refactor the parser\".")))
  (should (equal "Fix login bug" (harness-naming-sanitise "**Fix login bug**\n\nMore text")))
  (should (equal "Add tests" (harness-naming-sanitise "# Add tests")))
  (should (equal "Add tests" (harness-naming-sanitise "Title: Add tests")))
  (should (equal "Migrate to sqlite" (harness-naming-sanitise "‘Migrate   to sqlite’!")))
  (should (null (harness-naming-sanitise "  \n\"\" ")))
  (let ((long (harness-naming-sanitise (make-string 100 ?x))))
    (should (= 60 (length long)))
    (should (string-suffix-p "…" long))))

(ert-deftest harness-naming-name-sets-the-session-name ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (requests nil) (done nil))
      (harness-on 'naming/done (lambda (sid name) (push (list sid name) done)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (should (equal "Refactor the parser" (harness-await (harness-call 'naming/name id)))))
      (should (equal "Refactor the parser" (harness-naming-test-name id)))
      (should (equal (list (list id "Refactor the parser")) done))
      (should (equal '("Naming session…" "renamed to Refactor the parser") (harness-naming-test-hints id)))
      ;; No fork capability: the transcript goes out as messages, no provider state.
      (let* ((req (car requests))
             (last (car (last (plist-get req :messages)))))
        (should (= 1 (length requests)))
        (should (null (plist-get req :provider-state)))
        (should (null (plist-get req :tools)))
        (should (= 3 (length (plist-get req :messages))))
        (should (string-match-p "3 to 6 words" (plist-get (car (last (plist-get last :content))) :text))))
      (should (zerop (hash-table-count harness-naming--running))))))

(ert-deftest harness-naming-system-prompt-filter ()
  "Modules add to a session's naming system prompt with `naming/system-prompt'."
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (other (harness-naming-test-answered-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (systems nil))
      (harness-add-filter 'naming/system-prompt
                          (lambda (prompt session)
                            (if (equal (plist-get session :id) id) (concat prompt "\n\nLike a ticket.") prompt)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push (plist-get req :system) systems) (funcall orig req))))
        (harness-await (harness-call 'naming/name id))
        (harness-await (harness-call 'naming/name other)))
      (should (equal (list harness-naming--base-system-prompt
                           (concat harness-naming--base-system-prompt "\n\nLike a ticket."))
                     systems)))))

(ert-deftest harness-naming-name-error-rejects ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom"))))
      (should-error (harness-await (harness-call 'naming/name id)))
      (should (null (harness-naming-test-name id)))
      (should (equal '("Naming session…" "Naming failed: boom") (harness-naming-test-hints id)))
      (should (zerop (hash-table-count harness-naming--running))))))

(ert-deftest harness-naming-name-runs-once-per-session ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (calls 0))
      (harness-naming-test-counting-completes calls
        (let ((p1 (harness-call 'naming/name id))
              (p2 (harness-call 'naming/name id)))
          (should (eq p1 p2))
          (harness-await p1)))
      (should (= 1 calls))
      (should (= 1 (cl-count "Naming session…" (harness-naming-test-hints id) :test #'equal))))))

(ert-deftest harness-naming-auto-as-the-first-turn-starts ()
  "A session is named as soon as its first message is sent, while its turn runs.
A task's first turn lasts until the task is done: naming after it
showed the raw message as the task's title all along.  The request goes
to the provider's cheap model beside the turn: the message and the
question, ephemeral, with no provider state."
  (harness-naming-test-with
    (harness-naming-test-with-held
      (let* ((id (harness-naming-test-session :model "naming-held:big"))
             (turn (harness-call 'agent/prompt id "fix the parser, it drops comments")))
        (should (null (harness-naming-test-name id)))
        (harness-test-wait (lambda () (harness-naming-test-name id)) 5 "the name")
        (should (harness-agent-running-p id))
        (should (equal "Fix the parser" (harness-naming-test-name id)))
        (should (equal '(user hint hint) (harness-naming-test-kinds id)))
        (should (equal '("Naming session…" "renamed to Fix the parser") (harness-naming-test-hints id)))
        (let* ((naming (harness-naming-test-naming-request harness-naming-test--requests))
               (blocks (plist-get (car (plist-get naming :messages)) :content)))
          (should (equal "naming-held:small" (plist-get naming :model)))
          (should (plist-get naming :no-thinking))
          (should (null (plist-get naming :tools)))
          (should (null (plist-get naming :provider-state)))
          (should (equal id (plist-get (plist-get naming :session) :id)))
          (should-not (plist-member (plist-get naming :session) :provider-state))
          (should (= 1 (length (plist-get naming :messages))))
          (should (string-search "<message>\nfix the parser, it drops comments\n</message>"
                                 (plist-get (car blocks) :text)))
          (should-not (string-search "latest message" (plist-get (car blocks) :text)))
          (should (string-search "3 to 6 words" (plist-get (cadr blocks) :text))))
        (harness-naming-test-release)
        (should (eq 'end-turn (plist-get (harness-await turn) :stop-reason)))
        (should (equal '(user hint hint assistant) (harness-naming-test-kinds id)))
        ;; The turn got the message alone: the naming stays out of it.
        (should (= 2 (length harness-naming-test--requests)))
        (let ((own (cl-find-if-not (lambda (r) (plist-get r :ephemeral)) harness-naming-test--requests)))
          (should (equal "naming-held:big" (plist-get own :model)))
          (should (= 1 (length (plist-get own :messages)))))))))

(ert-deftest harness-naming-model-option ()
  "`harness-naming-model' chooses the model that names a session from its message."
  (harness-naming-test-with
    (harness-naming-test-with-held
      (let ((session (list :model "naming-held:big")))
        (should (equal "naming-held:small" (harness-naming--model session)))
        ;; A provider that names no cheap model leaves the session's own.
        (should (equal "nobody:m" (harness-naming--model (list :model "nobody:m"))))
        (let ((harness-naming-model nil))
          (should (equal "naming-held:big" (harness-naming--model session))))
        (let ((harness-naming-model "demo:scripted"))
          (should (equal "demo:scripted" (harness-naming--model session))))))))

(ert-deftest harness-naming-auto-from-the-latest-message-too ()
  "A conversation that has moved on is named from its opening and latest messages.
A fork starts out with its parent's transcript, and a session whose
naming failed has had turns since."
  (harness-naming-test-with
    (let ((id (harness-naming-test-answered-session))
          (harness-provider-demo-script-override harness-naming-test-script)
          (requests nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (harness-await (harness-call 'agent/prompt id "now add tests for it"))
        (harness-test-wait (lambda () (harness-naming-test-name id)) 5 "the name"))
      (let ((text (harness-naming-test-opening-text (harness-naming-test-naming-request requests))))
        (should (string-search "<message>\nrefactor the parser please\n</message>" text))
        (should (string-search "latest message in it:\n\n<message>\nnow add tests for it\n</message>" text)))
      (should (equal "Refactor the parser" (harness-naming-test-name id))))))

(ert-deftest harness-naming-auto-tries-again-at-the-next-turn ()
  "A session whose naming failed is named when its next turn starts."
  (harness-naming-test-with
    (let* ((id (harness-naming-test-session))
           (fail t)
           (harness-provider-demo-script-override
            (lambda (req)
              (cond ((not (plist-get req :ephemeral))
                     '((:type text :delta "Done.") (:type done :stop-reason end-turn)))
                    (fail '((:type done :stop-reason error :error "overloaded")))
                    (t harness-naming-test-script)))))
      (harness-await (harness-call 'agent/prompt id "refactor the parser"))
      (harness-test-wait (lambda () (zerop (hash-table-count harness-naming--running))) 5 "the failure")
      (should (null (harness-naming-test-name id)))
      (should (member "Naming failed: overloaded" (harness-naming-test-hints id)))
      (setq fail nil)
      (harness-await (harness-call 'agent/prompt id "and the lexer"))
      (harness-test-wait (lambda () (harness-naming-test-name id)) 5 "the name")
      (should (equal "Refactor the parser" (harness-naming-test-name id))))))

(ert-deftest harness-naming-keeps-a-name-given-meanwhile ()
  "A name given while the model is asked stays: the model's is dropped."
  (harness-naming-test-with
    (let* ((id (harness-naming-test-answered-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (done nil))
      (harness-on 'naming/done (lambda (sid name) (push (list sid name) done)))
      (let ((promise (harness-call 'naming/name id '(:opening t))))
        (harness-call 'session/update id :name "My own name")
        (should (equal "My own name" (harness-await promise))))
      (should (equal "My own name" (harness-naming-test-name id)))
      (should-not done)
      (should-not (member "renamed to Refactor the parser" (harness-naming-test-hints id))))))

(ert-deftest harness-naming-reload-names-at-turn-start ()
  "Reloading over a harness that named sessions after their turn moves naming.
That version subscribed to the end of turns; its subscription goes."
  (harness-naming-test-with
    (harness-on 'agent/turn-ended 'harness-naming--on-turn-ended)
    (harness-naming--init)
    (should-not (cl-find 'harness-naming--on-turn-ended (gethash 'agent/turn-ended harness--subscribers)
                         :key #'cdr))
    (should (cl-find 'harness-naming--on-turn-started (gethash 'agent/turn-started harness--subscribers)
                     :key #'cdr))))

(ert-deftest harness-naming-auto-names-only-once ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-session))
           (harness-provider-demo-script-override harness-naming-test-script)
           (calls 0))
      (harness-naming-test-counting-completes calls
        (harness-await (harness-call 'agent/prompt id "hello"))
        (harness-test-wait (lambda () (harness-naming-test-name id)) 5 "auto name")
        (harness-await (harness-call 'agent/prompt id "second"))
        (harness-test-wait (lambda () (not (harness-agent-running-p id)))))
      ;; Two turns plus one naming request.
      (should (= 3 calls))
      (should (= 1 (cl-count "Naming session…" (harness-naming-test-hints id) :test #'equal))))))

(ert-deftest harness-naming-auto-leaves-named-session-alone ()
  (harness-naming-test-with
    (let* ((id (harness-naming-test-session :name "Given name"))
           (calls 0))
      (harness-naming-test-counting-completes calls
        (harness-await (harness-call 'agent/prompt id "hello")))
      (should (= 1 calls))
      (should (equal "Given name" (harness-naming-test-name id)))
      (should (equal '(user assistant) (harness-naming-test-kinds id))))))

(ert-deftest harness-naming-auto-skips-btw-and-subagent ()
  (harness-naming-test-with
    (dolist (kind '(btw subagent))
      (let ((id (harness-naming-test-session :kind kind))
            (calls 0))
        (harness-naming-test-counting-completes calls
          (harness-await (harness-call 'agent/prompt id "hello")))
        (should (= 1 calls))
        (should (null (harness-naming-test-name id)))
        (should (equal '(user assistant) (harness-naming-test-kinds id)))))))

(ert-deftest harness-naming-auto-respects-custom ()
  (harness-naming-test-with
    (let ((harness-naming-auto nil)
          (id (harness-naming-test-session))
          (calls 0))
      (harness-naming-test-counting-completes calls
        (harness-await (harness-call 'agent/prompt id "hello")))
      (should (= 1 calls))
      (should (null (harness-naming-test-name id))))))

(ert-deftest harness-naming-auto-waits-for-the-turn-to-start ()
  "A message whose turn never starts (the gate held it back) names nothing."
  (harness-naming-test-with
    (let ((id (harness-naming-test-session))
          (calls 0))
      (harness-add-filter 'agent/before-turn
                          (lambda (_v next _s) (funcall next (list :proceed nil :reason "held"))))
      (harness-naming-test-counting-completes calls
        (should (eq 'blocked (plist-get (harness-await (harness-call 'agent/prompt id "hello")) :stop-reason))))
      (should (= 0 calls))
      (should (null (harness-naming-test-name id))))))

(ert-deftest harness-naming-uses-provider-fork-when-supported ()
  (harness-naming-test-with
    (let ((forks nil) (requests nil))
      (harness-define-provider 'forky
        :label "Forking fake"
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil
                                   (lambda ()
                                     (funcall on-event '(:type text :delta "Forked title here"))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :fork (lambda (model state)
                (push (list model state) forks)
                (harness-resolved (list :forked-from (plist-get state :cli))))
        :capabilities '(:fork t :hosted-loop t))
      (let ((id (harness-naming-test-answered-session :model "forky:m")))
        (harness-call 'session/set-provider-state id '(:cli "abc"))
        (should (equal "Forked title here" (harness-await (harness-call 'naming/name id))))
        (should (equal '(("forky:m" (:cli "abc"))) forks))
        (should (= 1 (length requests)))
        (should (equal '(:forked-from "abc" :provider "forky") (plist-get (car requests) :provider-state)))
        (should (equal "Forked title here" (harness-naming-test-name id)))
        ;; The session's own state is untouched by the fork.
        (should (equal '(:cli "abc") (plist-get (harness-call 'session/get id) :provider-state)))))))

(ert-deftest harness-naming-falls-back-when-fork-fails ()
  (harness-naming-test-with
    (let ((requests nil))
      (harness-define-provider 'forky
        :label "Forking fake"
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil
                                   (lambda ()
                                     (funcall on-event '(:type text :delta "Plain title"))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :fork (lambda (_model _state) (harness-rejected (list 'harness-error "no fork today")))
        :capabilities '(:fork t))
      (let ((id (harness-naming-test-answered-session :model "forky:m")))
        (should (equal "Plain title" (harness-await (harness-call 'naming/name id))))
        (should (null (plist-get (car requests) :provider-state)))
        (should (= 3 (length (plist-get (car requests) :messages))))))))

;;;; A title for a message alone

(defun harness-naming-test-rejection (promise)
  "Wait for PROMISE to settle; return why it was rejected, or fail."
  (harness-test-wait (lambda () (harness-promise-settled-p promise)) 5 "the request to settle")
  (should (eq 'rejected (harness-promise-state promise)))
  (harness-error-message (harness-promise-value promise)))

(ert-deftest harness-naming-title-of-a-message-alone ()
  "`naming/title' titles a message no session holds, as a session's first one.
That is how a task is named while it waits for a slot.  The request is
the one that names a session from its first message: to the cheap
model, ephemeral, without thinking, tools or provider state, the message
quoted.  It goes under an id of its own, which the provider is told to
free once it is answered, and its options go to the
`naming/system-prompt' filters: nothing is stored, no session is made."
  (harness-naming-test-with
    (harness-naming-test-with-held
      (harness-add-filter 'naming/system-prompt
                          (lambda (prompt what)
                            (if (plist-get what :task) (concat prompt "\n\nLike a ticket.") prompt)))
      (should (equal "Fix the parser"
                     (harness-await (harness-call 'naming/title "  fix the parser, it drops comments \n"
                                                  (list :model "naming-held:big" :task "t-1")))))
      (should (= 1 (length harness-naming-test--requests)))
      (let* ((naming (car harness-naming-test--requests))
             (id (plist-get (plist-get naming :session) :id)))
        (should (equal "naming-held:small" (plist-get naming :model)))
        (should (plist-get naming :ephemeral))
        (should (plist-get naming :no-thinking))
        (should (null (plist-get naming :tools)))
        (should (null (plist-get naming :provider-state)))
        (should (string-prefix-p "naming-" id))
        (should (equal default-directory (plist-get (plist-get naming :session) :cwd)))
        (should (equal (concat harness-naming--base-system-prompt "\n\nLike a ticket.")
                       (plist-get naming :system)))
        (should (string-search "<message>\nfix the parser, it drops comments\n</message>"
                               (harness-naming-test-opening-text naming)))
        (should (equal (list id) harness-naming-test--closed)))
      (should (zerop (hash-table-count harness-sessions)))
      ;; Another request, another id; without `:task', the plain prompt.
      (harness-await (harness-call 'naming/title "add a CSV export" '(:model "naming-held:big")))
      (should (equal harness-naming--base-system-prompt (plist-get (car harness-naming-test--requests) :system)))
      (should (= 2 (length (delete-dups (copy-sequence harness-naming-test--closed))))))))

(ert-deftest harness-naming-title-failures-reject ()
  "`naming/title' never signals: its promise rejects, saying why.
A blank message, no model to ask, a provider that fails at once or
later, and a reply without a title; the request's id is freed anyway."
  (harness-naming-test-with
    (should (equal "there is no message to name it from"
                   (harness-naming-test-rejection
                    (harness-call 'naming/title "  \n " '(:model "demo:scripted")))))
    (let ((harness-naming-model 'auto))
      (should (equal "no model to ask for a title"
                     (harness-naming-test-rejection (harness-call 'naming/title "fix it" nil)))))
    (should (equal "No provider for model nobody:m"
                   (harness-naming-test-rejection (harness-call 'naming/title "fix it" '(:model "nobody:m")))))
    (let ((harness-provider-demo-script-override '((:type done :stop-reason error :error "overloaded"))))
      (should (equal "overloaded"
                     (harness-naming-test-rejection (harness-call 'naming/title "fix it" '(:model "demo:scripted"))))))
    (let ((harness-provider-demo-script-override '((:type text :delta " \"\" ") (:type done :stop-reason end-turn))))
      (should (equal "the model returned no usable title"
                     (harness-naming-test-rejection (harness-call 'naming/title "fix it" '(:model "demo:scripted"))))))
    (let ((closed nil))
      (harness-define-provider 'naming-broken
        :label "Broken"
        :complete (lambda (_request) (error "No CLI to run"))
        :close (lambda (id) (push id closed) t))
      (unwind-protect
          (progn
            (should (equal "No CLI to run"
                           (harness-naming-test-rejection
                            (harness-call 'naming/title "fix it" '(:model "naming-broken:m")))))
            (should (= 1 (length closed))))
        (remhash 'naming-broken harness-providers)
        (harness-provider--forget 'naming-broken)))))

(ert-deftest harness-naming-gives-up-on-a-silent-model ()
  "A request naming from a first message fails after `harness-naming--timeout'.
It is cancelled, and a title's id freed: a model that never answers
must not keep a session nameless, which its next turn names again."
  (harness-naming-test-with
    (harness-naming-test-with-held
      (let ((harness-naming-test--answer 'hold)
            (harness-naming--timeout 0.05))
        (should (equal "the model took too long"
                       (harness-naming-test-rejection
                        (harness-call 'naming/title "fix the parser" '(:model "naming-held:big")))))
        (should (= 1 harness-naming-test--cancelled))
        (should (= 1 (length harness-naming-test--closed)))
        (let ((id (harness-naming-test-session :model "naming-held:big")))
          (harness-call 'session/append id '(:kind user :content "fix the parser"))
          (should (equal "the model took too long"
                         (harness-naming-test-rejection (harness-call 'naming/name id '(:opening t)))))
          (should (null (harness-naming-test-name id)))
          (should (member "Naming failed: the model took too long" (harness-naming-test-hints id)))
          (should (= 2 harness-naming-test--cancelled))
          (should (zerop (hash-table-count harness-naming--running))))))))

;;;; Who is named

(ert-deftest harness-naming-auto-p-filter-holds-naming-off ()
  "A `naming/auto-p' filter keeps a session from being named as its turn starts.
Task mode holds it off a session whose task's title is on its way."
  (harness-naming-test-with
    (let ((held (harness-naming-test-session))
          (other (harness-naming-test-session))
          (harness-provider-demo-script-override harness-naming-test-script)
          (asked nil))
      (harness-add-filter 'naming/auto-p
                          (lambda (verdict session)
                            (push (plist-get session :id) asked)
                            (and verdict (not (equal held (plist-get session :id))))))
      (harness-await (harness-call 'agent/prompt held "refactor the parser"))
      (harness-await (harness-call 'agent/prompt other "refactor the parser"))
      (harness-test-wait (lambda () (harness-naming-test-name other)) 5 "the other session's name")
      (should (equal "Refactor the parser" (harness-naming-test-name other)))
      (should (member held asked))
      (should (null (harness-naming-test-name held)))
      (should-not (member "Naming session…" (harness-naming-test-hints held))))))

(ert-deftest harness-naming-reload-names-running-turns ()
  "A nameless session whose turn runs as the harness reloads is named then.
Its turn started before naming moved to the start of turns, and a
task's first turn lasts until the task is done: it would stay nameless
all that time.  A named session is left alone."
  (harness-naming-test-with
    (harness-naming-test-with-held
      ;; Turns that started with nothing to name them.
      (harness-naming--shutdown)
      (let* ((id (harness-naming-test-session :model "naming-held:big"))
             (named (harness-naming-test-session :model "naming-held:big" :name "Given name"))
             (turn (harness-call 'agent/prompt id "fix the parser, it drops comments"))
             (other (harness-call 'agent/prompt named "and the lexer")))
        (harness-test-wait (lambda () (= 2 (length harness-naming-test--held))) 5 "the turns")
        (harness-naming--init)
        (should (null (harness-naming-test-name id)))
        (harness-naming--name-running)
        (harness-test-wait (lambda () (harness-naming-test-name id)) 5 "the name")
        (should (harness-agent-running-p id))
        (should (equal "Fix the parser" (harness-naming-test-name id)))
        (should (equal "Given name" (harness-naming-test-name named)))
        (should (= 1 (cl-count-if (lambda (r) (plist-get r :ephemeral)) harness-naming-test--requests)))
        (harness-naming-test-release)
        (harness-naming-test-release)
        (harness-await turn)
        (harness-await other)))))

(provide 'harness-naming-test)
;;; harness-naming-test.el ends here
