;;; harness-compaction-test.el --- Tests for compaction  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-compaction--context-reserve)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-compaction--pending)
(defvar harness-compaction--revert-hold)
(defvar harness-compaction-kind)
(defvar harness-compaction-brief-model)
(defvar harness-compaction-mid-turn)
(defvar harness-compaction--mid-turn)
(defvar harness-compaction--mid-turn-note)
(defvar harness-compaction--request-text)
(defvar harness-compaction--summary-output)
(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-define-tool "harness-tools")
(declare-function harness-compaction-needed-p "harness-compaction")
(declare-function harness-compaction-hosted-p "harness-compaction")
(declare-function harness-compaction--block-text "harness-compaction" (block))
(declare-function harness-compaction--messages-text "harness-compaction" (messages))

(defmacro harness-compaction-test-with (&rest body)
  "Load the state layer with the demo provider and compaction, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-compaction--pending)
     (clrhash harness-compaction--revert-hold)
     (clrhash harness-compaction--mid-turn)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-compaction--context-reserve 1000)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defconst harness-compaction-test-script
  '((:type text :delta "SUMMARY ") (:type text :delta "TEXT") (:type done :stop-reason end-turn)))

(defun harness-compaction-test-session (&rest plist)
  "Create a demo session (window 8000) with one answered exchange."
  (let ((id (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                              :model "demo:scripted" :context-window 8000 plist)
                       :id)))
    (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append id '(:kind assistant :content "Done: parser.el rewritten"))
    id))

(defun harness-compaction-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(defun harness-compaction-test-hints (id)
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint)) (harness-call 'session/nodes id))))

(defun harness-compaction-test-first-text (id)
  (plist-get (car (plist-get (car (harness-call 'session/messages id)) :content)) :text))

(defun harness-compaction-test-long-session ()
  "Create a demo session with twenty long alternating messages."
  (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                     :model "demo:scripted" :context-window 8000)
                       :id)))
    (dotimes (i 20)
      (harness-call 'session/append id
                    (list :kind (if (cl-evenp i) 'user 'assistant)
                          :content (format "message %d %s" i
                                           (string-join (make-list 50 "word") " ")))))
    id))

(defun harness-compaction-test-request-text (request)
  "Return all the text of REQUEST's messages, in order."
  (mapconcat (lambda (m)
               (mapconcat (lambda (b) (or (plist-get b :text) "")) (plist-get m :content) "\n"))
             (plist-get request :messages) "\n"))

(defun harness-compaction-test-messages-text (messages)
  "Return all the text blocks of MESSAGES, in order."
  (mapconcat (lambda (m)
               (mapconcat (lambda (b) (or (plist-get b :text) "")) (plist-get m :content) "\n"))
             messages "\n"))

(ert-deftest harness-compaction-compact-appends-summary-node ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (old-head (plist-get (harness-call 'session/get id) :head))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (requests nil) (done nil) (node nil))
      (harness-on 'compaction/done (lambda (sid node) (push (list sid (plist-get node :id)) done)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (let ((n (harness-await (harness-call 'compaction/compact id))))
          (setq node n)
          (should (eq 'compaction (plist-get n :kind)))
          (should (string-prefix-p "SUMMARY TEXT" (plist-get n :content)))
          (should (equal old-head (plist-get (plist-get n :meta) :compacted-head)))
          (should (equal "demo:scripted" (plist-get (plist-get n :meta) :model)))
          (should (eq 'full (plist-get (plist-get n :meta) :context)))
          (should (numberp (plist-get (plist-get n :meta) :input-tokens)))
          (should (equal (list (list id (plist-get n :id))) done))))
      ;; The request: no tools, no provider state, transcript then the ask.
      (should (= 1 (length requests)))
      (let* ((req (car requests))
             (last (car (last (plist-get req :messages)))))
        (should (null (plist-get req :tools)))
        (should (null (plist-get req :provider-state)))
        (should (string-match-p "handoff summary" (plist-get req :system)))
        (should (eq 'user (plist-get last :role)))
        (should (string-match-p "Summarize the conversation above"
                                (plist-get (car (last (plist-get last :content))) :text)))
        (should (= 3 (length (plist-get req :messages)))))
      ;; Transcript: hints around the node, messages restart at the summary.
      (should (equal '(user assistant hint compaction hint) (harness-compaction-test-kinds id)))
      (should (equal "Compacting context…" (car (harness-compaction-test-hints id))))
      (should (string-match-p "\\`Compacted: [0-9.k]+ tokens → summary\\'" (cadr (harness-compaction-test-hints id))))
      (should (= 1 (length (harness-call 'session/messages id))))
      (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY TEXT"
                               (harness-compaction-test-first-text id)))
      (should (= (harness-estimate-tokens (plist-get node :content))
                 (plist-get (plist-get (harness-call 'session/get id) :usage) :context)))
      (should (zerop (hash-table-count harness-compaction--running))))))

(ert-deftest harness-compaction-starts-the-cache-over ()
  "A compaction leaves nothing cached: the conversation goes on from its summary.
What the summariser's request read from the cache is counted, but it
stamps no cache, and the old one's stamp goes: the next request sends
the summary uncached, and none of what was cached before."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override
            '((:type text :delta "SUMMARY")
              (:type usage :input 20 :output 5 :cache-read 400 :cache-at 2000.0 :cache-ttl 3600)
              (:type done :stop-reason end-turn))))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420
                                             :cache-at 1000.0))
      (should (plist-get (harness-call 'session/get id) :cache))
      (harness-await (harness-call 'compaction/compact id))
      (let ((s (harness-call 'session/get id)))
        (should-not (plist-get s :cache))
        (should (= 800 (plist-get (plist-get s :usage) :cache-read)))
        (should-not (plist-member (plist-get s :usage) :cache-at))))))

(ert-deftest harness-compaction-restamps-the-cache-on-the-next-request ()
  "The first request after a compaction stamps the new conversation's cache.
A compaction clears the old stamp but, when the conversation had one,
remembers it; the request that follows -- which the provider may report
as a plain miss, with no cache tokens -- writes the new cache, so the
session reports it with the model's lifetime.  A conversation that never
had a cache is not made to look warm."
  (harness-compaction-test-with
    (let* ((harness-cache-ttl 300)
           (harness-cache-ttl-overrides nil)
           (harness-provider-demo-script-override harness-compaction-test-script)
           (id (harness-compaction-test-session))
           (cache (lambda () (plist-get (harness-call 'session/get id) :cache))))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420
                                             :cache-at 1000.0))
      (should (funcall cache))
      (harness-await (harness-call 'compaction/compact id))
      (let ((s (harness-call 'session/get id)))
        (should-not (plist-get s :cache))
        (should (plist-get (plist-get s :usage) :cache-pending)))
      ;; The turn after the compaction reports a cache miss only.
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 5000.0)))
        (harness-call 'session/usage-add id '(:input 900 :output 60 :cache-read 0 :cache-write 0
                                               :context 1500 :model "demo:scripted")))
      (let* ((c (funcall cache))
             (u (plist-get (harness-call 'session/get id) :usage)))
        (should c)
        (should (= 5000.0 (plist-get c :at)))
        (should (= 300 (plist-get c :ttl)))
        (should (= 5300.0 (plist-get c :expires)))
        (should (equal "demo:scripted" (plist-get c :model)))
        (should-not (plist-get u :cache-pending))))
    ;; A conversation that never had a cache is not made to look warm.
    (let ((harness-cache-ttl 300)
          (harness-cache-ttl-overrides nil)
          (harness-provider-demo-script-override harness-compaction-test-script)
          (id (harness-compaction-test-session)))
      (harness-await (harness-call 'compaction/compact id))
      (should-not (plist-get (plist-get (harness-call 'session/get id) :usage) :cache-pending))
      (harness-call 'session/usage-add id '(:input 900 :output 60 :cache-read 0 :cache-write 0
                                             :context 1500 :model "demo:scripted"))
      (should-not (plist-get (harness-call 'session/get id) :cache)))))

(ert-deftest harness-compaction-hosted-summary-on-a-fork ()
  "A summariser that keeps the conversation itself works on a fork of the session's.
A hosted loop is sent only the newest user messages, so without the
conversation it would summarise nothing; on a fork it has all of it,
and the session's own conversation is left alone.  A state of another
provider is never forked."
  (harness-compaction-test-with
    (let ((requests nil) (forks nil))
      (harness-define-provider 'forky
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil (lambda ()
                                               (funcall on-event '(:type text :delta "SUMMARY"))
                                               (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :fork (lambda (model state)
                (push (list model state) forks)
                (harness-resolved (list :conv (plist-get state :conv) :fork-pending t)))
        :capabilities '(:hosted-loop t :fork t :compaction hosted))
      (let ((id (harness-compaction-test-session)))
        (harness-call 'session/update id :model "forky:m" :silent t)
        (harness-call 'session/set-provider-state id '(:conv "c9" :provider "forky"))
        (should (string-prefix-p "SUMMARY" (plist-get (harness-await (harness-call 'compaction/compact id)) :content)))
        (should (equal '(("forky:m" (:conv "c9" :provider "forky"))) forks))
        (should (equal '(:conv "c9" :fork-pending t :provider "forky") (plist-get (car requests) :provider-state)))
        ;; The summary replaced the conversation the session's provider held.
        (should-not (plist-get (harness-call 'session/get id) :provider-state))
        ;; A sampled context is not forked: the summariser gets the sample.
        (harness-call 'session/set-provider-state id '(:conv "c9" :provider "forky"))
        (setq forks nil)
        (harness-await (harness-call 'compaction/compact id (list :context "sample")))
        (should-not forks)
        (should-not (plist-get (car requests) :provider-state))
        ;; Another provider's state: no fork, no state, and it stays.
        (harness-call 'session/set-provider-state id '(:conv "c9" :provider "other"))
        (setq forks nil)
        (harness-await (harness-call 'compaction/compact id))
        (should-not forks)
        (should-not (plist-get (car requests) :provider-state))
        (should (equal '(:conv "c9" :provider "other")
                       (plist-get (harness-call 'session/get id) :provider-state)))))))

(ert-deftest harness-compaction-hosted-conversation-starts-over ()
  "A hosted loop's compacted conversation starts over from the compaction.
Kept, it would take the summary as one more message of the whole
conversation, read back uncached once its cache lapsed: its provider
state goes, which tells its provider to let its process go too, and so
does the cache stamp, however the summary was made."
  (harness-compaction-test-with
    (harness-define-provider 'forky
      :complete (lambda (req)
                  (let ((on-event (plist-get req :on-event)))
                    (run-at-time 0.005 nil
                                 (lambda ()
                                   (funcall on-event '(:type text :delta "SUMMARY"))
                                   (funcall on-event '(:type usage :input 20 :output 5 :cache-read 400
                                                             :cache-at 2000.0 :cache-ttl 3600))
                                   (funcall on-event '(:type done :stop-reason end-turn)))))
                  (list :cancel #'ignore))
      :fork (lambda (_model state)
              (harness-resolved (list :conv (plist-get state :conv) :fork-pending t)))
      :capabilities '(:hosted-loop t :fork t :compaction hosted))
    (let ((id (harness-compaction-test-session))
          (changed nil)
          (stamp (lambda (id)
                   (harness-call 'session/set-provider-state id '(:conv "c9" :provider "forky"))
                   (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420
                                                          :cache-at 1000.0 :cache-ttl 3600)))))
      (harness-call 'session/update id :model "forky:m" :silent t)
      (harness-on 'session/provider-state-changed (lambda (sid state) (push (list sid state) changed)))
      (dolist (opts (list nil (list :kind "brief") (list :model "forky:n") (list :kind "transcript")))
        (funcall stamp id)
        (should (plist-get (harness-call 'session/get id) :cache))
        (setq changed nil)
        (harness-await (harness-call 'compaction/compact id opts))
        (should-not (plist-get (harness-call 'session/get id) :provider-state))
        (should (equal (list (list id nil)) changed))
        (should-not (plist-get (harness-call 'session/get id) :cache))))))

(defun harness-compaction-test-tiered-provider (&optional capabilities complete)
  "Define provider `tiered': a dear \"big\" model and a cheap \"small\" one.
CAPABILITIES are its capabilities; COMPLETE its completion function,
by default one that answers SUMMARY."
  (harness-define-provider 'tiered
    :label "Tiered"
    :models (lambda ()
              (harness-resolved
               (list (list :name "big" :label "Big" :context-window 200000
                           :pricing '(:input 10.0 :output 50.0 :cache-read 1.0 :cache-write 12.5))
                     (list :name "small" :label "Small" :context-window 200000
                           :pricing '(:input 1.0 :output 5.0 :cache-read 0.1 :cache-write 1.25)))))
    :complete (or complete
                  (lambda (req)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil (lambda ()
                                               (funcall on-event '(:type text :delta "SUMMARY"))
                                               (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore)))
    :capabilities capabilities))

(ert-deftest harness-compaction-brief-summary ()
  "A brief summary is the cheap model's, of the narrative, and ends saying what it lacks.
It is a handoff's `compact-new' on the session's own provider: the
simple tier of the session's provider writes it from the conversation's
narrative, whatever the session's model is."
  (harness-compaction-test-with
    (let ((requests nil))
      (harness-compaction-test-tiered-provider
       nil (lambda (req)
             (push req requests)
             (let ((on-event (plist-get req :on-event)))
               (run-at-time 0.005 nil (lambda ()
                                        (funcall on-event '(:type text :delta "BRIEF"))
                                        (funcall on-event '(:type done :stop-reason end-turn)))))
             (list :cancel #'ignore)))
      (let* ((id (harness-compaction-test-long-session))
             (_ (harness-call 'session/update id :model "tiered:big" :silent t))
             (node (harness-await (harness-call 'compaction/compact id (list :kind "brief"))))
             (meta (plist-get node :meta)))
        (should (equal "tiered:small" (plist-get (car requests) :model)))
        (should (= 21 (length (plist-get (car requests) :messages))))
        (should (equal "brief" (plist-get meta :compaction)))
        (should (equal "brief" (harness-node-compaction-kind node)))
        (should (eq 'sample (plist-get meta :context)))
        (should (equal "tiered:small" (plist-get meta :model)))
        (should (string-prefix-p "BRIEF\n\nHarness note: Small wrote this summary from the conversation's user and assistant"
                                 (plist-get node :content)))
        (should (equal "Compacting context: a brief summary by Small…" (car (harness-compaction-test-hints id))))
        (should (string-match-p "\\`Compacted: [0-9.k]+ tokens → brief summary\\'"
                                (cadr (harness-compaction-test-hints id))))
        (should (string-prefix-p "Summary of the conversation so far:\n\nBRIEF\n\nHarness note:"
                                 (harness-compaction-test-first-text id))))
      ;; A sample alone is a brief summary too, and the caveat can go.
      (setq requests nil)
      (let* ((id (harness-compaction-test-long-session))
             (_ (harness-call 'session/update id :model "tiered:big" :silent t))
             (node (harness-await (harness-call 'compaction/compact id (list :context "sample" :caveat nil)))))
        (should (equal "brief" (plist-get (plist-get node :meta) :compaction)))
        (should (string-prefix-p "BRIEF\n\nThe conversation opened with" (plist-get node :content))))
      ;; The setting picks the model: the session's own, or one named.
      (dolist (case '((nil . "tiered:big") ("tiered:big" . "tiered:big") (auto . "tiered:small")))
        (setq requests nil)
        (let ((harness-compaction-brief-model (car case))
              (id (harness-compaction-test-long-session)))
          (harness-call 'session/update id :model "tiered:big" :silent t)
          (harness-await (harness-call 'compaction/compact id (list :kind 'brief)))
          (should (equal (cdr case) (plist-get (car requests) :model)))))
      ;; A provider with no cheaper model writes it with the session's.
      (setq requests nil)
      (let ((id (harness-compaction-test-long-session))
            (harness-provider-demo-script-override harness-compaction-test-script))
        (should (string-prefix-p "SUMMARY TEXT\n\nHarness note: Demo scripted wrote"
                                 (plist-get (harness-await (harness-call 'compaction/compact id (list :kind "brief")))
                                            :content)))))
    ;; An unknown kind is refused.
    (should-error (harness-await (harness-call 'compaction/compact (harness-compaction-test-session)
                                               (list :kind "sideways"))))))

;;;; A brief summary of a long conversation with tool calls

(defun harness-compaction-test-tool-call (call-id path)
  "Return an assistant tool-call message for CALL-ID reading PATH."
  (list :role 'assistant
        :content (list (list :type "tool_use" :id call-id :name "read_file" :input (list :path path)))))

(defun harness-compaction-test-tool-session ()
  "Create a demo session holding a tool call with a non-ASCII input."
  (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                     :model "demo:scripted" :context-window 8000)
                       :id)))
    (harness-call 'session/append id '(:kind user :content "please read the file"))
    (harness-call 'session/append id (list :kind 'tool-call :tool "read_file" :call-id "c1"
                                           :input (list :path "café/naïve.txt")))
    (harness-call 'session/append id '(:kind tool-result :call-id "c1" :output "the file says café"))
    id))

(defun harness-compaction-test-tool-result (call-id text)
  "Return the user message answering CALL-ID with TEXT."
  (list :role 'user
        :content (list (list :type "tool_result" :tool_use_id call-id :content text))))

(defun harness-compaction-test-tool-messages ()
  "Return a long conversation whose tools are answered, for narrative tests.
A tool call is answered by the message after it; twenty-one messages,
with text on every turn, enough to see the narrative keeps them all and
names each call and result in a line."
  (append
   (list (list :role 'user :content (list (list :type "text" :text "one")))
         (list :role 'assistant :content (list (list :type "text" :text "two")))
         (list :role 'user :content (list (list :type "text" :text "three")))
         (harness-compaction-test-tool-call "c1" "café/naïve.txt")
         (harness-compaction-test-tool-result "c1" "the file says café")
         (list :role 'assistant :content (list (list :type "text" :text "five")))
         (list :role 'user :content (list (list :type "text" :text "six")))
         (list :role 'assistant :content (list (list :type "text" :text "seven")))
         (harness-compaction-test-tool-call "c2" "make")
         (harness-compaction-test-tool-result "c2" "make: nothing to be done")
         (list :role 'user :content (list (list :type "text" :text "eleven")))
         (list :role 'assistant :content (list (list :type "text" :text "twelve")))
         (list :role 'user :content (list (list :type "text" :text "thirteen")))
         (list :role 'assistant :content (list (list :type "text" :text "fourteen")))
         (list :role 'user :content (list (list :type "text" :text "fifteen")))
         (list :role 'assistant :content (list (list :type "text" :text "sixteen")))
         (list :role 'user :content (list (list :type "text" :text "seventeen")))
         (list :role 'assistant :content (list (list :type "text" :text "eighteen")))
         (list :role 'user :content (list (list :type "text" :text "nineteen")))
         (list :role 'assistant :content (list (list :type "text" :text "twenty")))
         (list :role 'user :content (list (list :type "text" :text "twenty-one"))))))

(ert-deftest harness-compaction-block-text-is-json-text ()
  "Tool-call JSON rendered into a transcript is text, not bytes.
`harness-json-encode' gives the UTF-8 bytes; inside the transcript they
turned into raw-byte characters, and `json-serialize' refused the whole
request with `(wrong-type-argument json-value-p \"### user…\")' -- the
error the user saw, with the transcript in *Messages*."
  (let* ((block (list :type "tool_use" :name "bash" :input (list :command "echo café")))
         (text (harness-compaction--block-text block)))
    (should (multibyte-string-p text))
    (should (equal "[called bash with {\"command\":\"echo café\"}]" text))
    ;; The rendered conversation goes into a request as one text: it must
    ;; serialize.
    (should (stringp (harness-json-encode
                      (list :role 'user
                            :content (list (list :type "text"
                                                 :text (harness-compaction--messages-text
                                                        (list (list :role 'assistant :content (list block))))))))))))

(ert-deftest harness-compaction-narrative-names-tools-and-keeps-every-turn ()
  "The narrative a brief summary reads keeps every message and names tools.
A tool call is one line with its main argument, a result one line of
what it answered; no payload, and no tool_use or tool_result block,
goes to the summariser."
  (harness-compaction-test-with
    (let* ((messages (harness-compaction-test-tool-messages))
           (narrative (harness-compaction--narrative-messages messages))
           (text (harness-compaction-test-messages-text narrative)))
      (should (= 21 (length messages)))
      ;; Every turn's text is still there, even where neighbouring assistant
      ;; messages merge.
      (dolist (word '("one" "two" "three" "five" "six" "seven" "eleven" "twelve"
                      "thirteen" "fourteen" "fifteen" "sixteen" "seventeen"
                      "eighteen" "nineteen" "twenty" "twenty-one"))
        (should (string-match-p word text)))
      (should (string-match-p (regexp-quote "[called read_file: path: café/naïve.txt]") text))
      (should (string-match-p (regexp-quote "[result: the file says café]") text))
      (should (string-match-p (regexp-quote "[called read_file: path: make]") text))
      (should (string-match-p (regexp-quote "[result: make: nothing to be done]") text))
      ;; No payload and no tool protocol reach the summariser.
      (should-not (string-match-p "\"path\"" text))
      (should-not (cl-some (lambda (m) (cl-some (lambda (b) (memq (plist-get b :type) '(tool_use tool_result)))
                                                (plist-get m :content)))
                           narrative)))))

(ert-deftest harness-compaction-brief-summary-serializes-a-tool-call ()
  "A brief summary of a sample with tool-call JSON serializes and is accepted.
A hosted-loop provider with no state of this session gets the sample as
one message of text, which is where the tool call's input used to bring
raw bytes in and `json-serialize' refused the whole request, naming the
whole transcript."
  (harness-compaction-test-with
    (let ((requests nil))
      (harness-define-provider 'hosty
        :label "Hosty"
        :models (lambda () (harness-resolved (list (list :name "m" :label "M"))))
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil (lambda ()
                                               (funcall on-event '(:type text :delta "BRIEF"))
                                               (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :capabilities '(:hosted-loop t))
      (let* ((id (harness-compaction-test-tool-session))
             (_ (harness-call 'session/update id :model "hosty:m" :silent t))
             (node (harness-await (harness-call 'compaction/compact id (list :kind 'brief))))
             (req (car requests))
             (text (harness-compaction-test-request-text req)))
        ;; The request the provider is sent serializes: no raw bytes.
        (should (stringp (harness-json-encode (plist-get req :messages))))
        (should (string-match-p (regexp-quote "[called read_file: path: café/naïve.txt]") text))
        (should (string-match-p "Harness note: .* wrote this summary from the conversation's user and assistant"
                                (plist-get node :content)))
        (should (equal "brief" (plist-get (plist-get node :meta) :compaction)))))))


(ert-deftest harness-compaction-by-hand-waits-for-the-turn ()
  "Compacting by hand (OPTS `:idle') refuses a session running a turn,
which would go on writing after the conversation the compaction
replaces.  Automatic compaction runs inside the turn, and does not ask."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (puthash id (list :fake-turn t) harness-agent--turns)
      (unwind-protect
          (progn
            (should (harness-call 'agent/running id))
            (let ((err (should-error (harness-call 'compaction/compact id (list :kind "transcript" :idle t))
                                     :type 'harness-error)))
              (should (string-match-p "running a turn" (harness-error-message err))))
            (should-not (memq 'compaction (harness-compaction-test-kinds id)))
            (should-not (gethash id harness-compaction--running)))
        (remhash id harness-agent--turns))
      ;; Once the turn is over it goes ahead.
      (should (equal "transcript"
                     (harness-node-compaction-kind
                      (harness-await (harness-call 'compaction/compact id (list :kind "transcript" :idle t))))))
      ;; Without it, the turn's own compaction does.
      (let ((other (harness-compaction-test-session))
            (harness-provider-demo-script-override harness-compaction-test-script))
        (puthash other (list :fake-turn t) harness-agent--turns)
        (unwind-protect
            (should (string-prefix-p "SUMMARY TEXT" (plist-get (harness-await (harness-call 'compaction/compact other))
                                                     :content)))
          (remhash other harness-agent--turns))))))

(ert-deftest harness-compaction-transcript ()
  "A transcript compaction writes the conversation to a file and leaves a note.
No model is asked anything; the note opens the conversation from then
on, as it is, and an unanswered message still follows it."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (cwd (plist-get (harness-call 'session/get id) :cwd))
           (requests 0) (done nil))
      (harness-call 'session/append id '(:kind user :content "and now the lexer"))
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420 :cache-at 1000.0))
      (harness-on 'compaction/done (lambda (sid node) (push (list sid (plist-get node :id)) done)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (cl-incf requests) (funcall orig req))))
        (let* ((node (harness-await (harness-call 'compaction/compact id (list :kind "transcript"))))
               (meta (plist-get node :meta))
               (file (plist-get meta :file)))
          (should (= 0 requests))
          (should (equal "transcript" (plist-get meta :compaction)))
          (should (equal "transcript" (harness-node-compaction-kind node)))
          (should (= 420 (plist-get meta :input-tokens)))
          (should (file-in-directory-p file (expand-file-name ".harness/transcripts/" cwd)))
          (should (equal "*\n" (with-temp-buffer
                                 (insert-file-contents (expand-file-name ".harness/transcripts/.gitignore" cwd))
                                 (buffer-string))))
          (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (should (string-prefix-p "# Compacted conversation\n" text))
            (should (string-match-p "\\[user\\] please refactor the parser" text))
            (should (string-match-p "\\[assistant\\] Done: parser.el rewritten" text)))
          (should (string-match-p (regexp-quote file) (plist-get node :content)))
          (should (string-match-p "read its end" (plist-get node :content)))
          (should (equal (list (list id (plist-get node :id))) done))
          ;; The note opens the conversation as it is, the open message after it.
          (let ((messages (harness-call 'session/messages id)))
            (should (= 1 (length messages)))
            (should (equal (list (plist-get node :content) "and now the lexer")
                           (mapcar (lambda (b) (plist-get b :text)) (plist-get (car messages) :content)))))
          (should (equal (format "Compacted: 420 tokens → transcript in %s" (abbreviate-file-name file))
                         (car (last (harness-compaction-test-hints id)))))
          (let ((s (harness-call 'session/get id)))
            (should-not (plist-get s :cache))
            (should (= (harness-estimate-tokens (plist-get node :content))
                       (plist-get (plist-get s :usage) :context)))))))
    ;; A session whose directory is gone has nowhere to write it.
    (let* ((id (harness-compaction-test-session))
           (failed nil))
      (harness-on 'compaction/failed (lambda (sid msg) (push (list sid msg) failed)))
      (delete-directory (plist-get (harness-call 'session/get id) :cwd) t)
      (should-error (harness-await (harness-call 'compaction/compact id (list :kind 'transcript))))
      (should (string-match-p "does not exist" (cadr (car failed))))
      (should-not (memq 'compaction (harness-compaction-test-kinds id)))
      (should (zerop (hash-table-count harness-compaction--running))))))

(ert-deftest harness-compaction-points-at-the-history ()
  "A compaction ends in a line pointing the model at session_history, and
a fresh start's note sends it there, when the model has the tool;
without it there is no pointer, and the fresh note says to ask the user."
  (harness-compaction-test-with
    (harness-define-tool "session_history" :label "Session history" :description "history" :kind 'read
                         :handler (lambda (_input _ctx) "nothing"))
    (let* ((id (harness-compaction-test-session))
           (node (harness-await (harness-call 'compaction/compact id (list :kind 'transcript)))))
      ;; The transcript's note, then the pointer.
      (should (string-match-p "read its end" (plist-get node :content)))
      (should (string-suffix-p "\n\nHarness note: the conversation this stands in for is still on record.  When you need something it left out -- what was asked, decided, tried or found -- search and read it with the session_history tool rather than guessing."
                               (plist-get node :content))))
    (let* ((id (harness-compaction-test-session))
           (node (harness-await (harness-call 'compaction/compact id (list :kind 'fresh))))
           (content (plist-get node :content)))
      (should (equal "fresh" (harness-node-compaction-kind node)))
      (should (string-prefix-p "This conversation starts afresh, to keep the context small: the 2 messages before" content))
      (should (string-match-p "look back at what you need of them with the session_history tool" content))
      ;; Its note says so already: no second pointer.
      (should-not (string-match-p "Harness note:" content)))
    (remhash "session_history" harness-tools)
    (let* ((id (harness-compaction-test-session))
           (node (harness-await (harness-call 'compaction/compact id (list :kind 'transcript)))))
      (should-not (string-match-p "session_history" (plist-get node :content))))
    (let* ((id (harness-compaction-test-session))
           (content (plist-get (harness-await (harness-call 'compaction/compact id (list :kind 'fresh))) :content)))
      (should-not (string-match-p "session_history" content))
      (should (string-match-p "ask the user for what you need of the earlier conversation" content)))))

(ert-deftest harness-compaction-estimate ()
  "The estimate prices each kind of compaction against carrying on.
A summary on an API model reads all of the context uncached, whatever
the cache: it is a prompt of its own.  On a fork of a hosted loop's
conversation it reads it from the cache while that lasts.  A brief one
is the cheap model's, of a sample; a transcript, a fresh start and a
truncation cost nothing."
  (harness-compaction-test-with
    (harness-compaction-test-tiered-provider)
    (let* ((id (harness-compaction-test-long-session))
           (ask (harness-estimate-tokens harness-compaction--request-text))
           (near (lambda (a b) (< (abs (- a b)) 1e-9))))
      (harness-call 'session/update id :model "tiered:big" :silent t)
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 100000 :context 100000 :cache-at 1000.0))
      (let* ((e (harness-call 'compaction/estimate id))
             (kinds (plist-get e :kinds))
             (summary (cl-find 'summary kinds :key (lambda (k) (plist-get k :kind))))
             (brief (cl-find 'brief kinds :key (lambda (k) (plist-get k :kind))))
             (transcript (cl-find 'transcript kinds :key (lambda (k) (plist-get k :kind))))
             (fresh (cl-find 'fresh kinds :key (lambda (k) (plist-get k :kind))))
             (truncate (cl-find 'truncate kinds :key (lambda (k) (plist-get k :kind)))))
        (should (= 100000 (plist-get e :context)))
        ;; The messages since the last compaction, for a question to name.
        (should (> (plist-get e :messages) 0))
        (should (equal "tiered:big" (plist-get e :model)))
        (should (equal "Big" (plist-get e :model-label)))
        (should (eq 'summary (plist-get e :kind)))
        (should-not (plist-get e :cached))
        (should-not (plist-get e :compacting))
        ;; Cache writes are the dearer: 100k at 12.5, against 1.0 read.
        (should (funcall near 1.25 (plist-get e :carry-on)))
        (should (funcall near 0.1 (plist-get e :carry-on-cached)))
        (should (equal '(summary brief transcript fresh truncate)
                       (mapcar (lambda (k) (plist-get k :kind)) kinds)))
        (should (equal "tiered:big" (plist-get summary :model)))
        (should-not (plist-get summary :cached))
        (should (funcall near (/ (+ (* (+ 100000 ask) 12.5) (* harness-compaction--summary-output 50.0)) 1e6)
                         (plist-get summary :cost)))
        ;; Uncached already: what it costs once the cache lapses is the same.
        (should (funcall near (plist-get summary :cost) (plist-get summary :cost-uncached)))
        (should (equal "tiered:small" (plist-get brief :model)))
        (should (equal "Small" (plist-get brief :model-label)))
        (should (< (plist-get brief :input) 3000))
        (should (funcall near (/ (+ (* (plist-get brief :input) 1.25) (* (plist-get brief :output) 5.0)) 1e6)
                         (plist-get brief :cost)))
        (should (< (plist-get brief :cost) 0.02))
        (should (eql 0.0 (plist-get transcript :cost)))
        (should-not (plist-get transcript :model))
        (should (< (plist-get transcript :after) 200))
        ;; A fresh start carries a note over, nothing else.
        (should (eql 0.0 (plist-get fresh :cost)))
        (should-not (plist-get fresh :model))
        (should (< (plist-get fresh :after) 200))
        ;; A truncation asks no model either; with nothing to cut it
        ;; leaves the context as it is.
        (should (eql 0.0 (plist-get truncate :cost)))
        (should-not (plist-get truncate :model))
        (should (equal 0 (plist-get truncate :dropped)))
        (should (equal 100000 (plist-get truncate :after))))
      ;; While the cache lasts, carrying on reads it.  A summary on an API
      ;; model still reads none of it.
      (harness-call 'session/usage-add id (list :input 10 :output 10 :cache-read 100000 :context 100000
                                                :cache-at (float-time) :cache-ttl 3600))
      (let* ((e (harness-call 'compaction/estimate id))
             (summary (car (plist-get e :kinds))))
        (should (plist-get e :cached))
        (should (funcall near 0.1 (plist-get e :carry-on)))
        (should-not (plist-get summary :cached))
        (should (> (plist-get summary :cost) 1.25))))
    ;; A hosted loop with the session's conversation summarises a fork of
    ;; it, which reads the cache while it lasts.
    (harness-compaction-test-tiered-provider '(:hosted-loop t :fork t :compaction hosted))
    (let ((id (harness-compaction-test-long-session))
          (ask (harness-estimate-tokens harness-compaction--request-text)))
      (harness-call 'session/update id :model "tiered:big" :silent t)
      (harness-call 'session/set-provider-state id '(:conv "c9" :provider "tiered"))
      (harness-call 'session/usage-add id (list :input 10 :output 10 :cache-read 100000 :context 100000
                                                :cache-at (float-time) :cache-ttl 3600))
      (let ((summary (car (plist-get (harness-call 'compaction/estimate id) :kinds))))
        (should (plist-get summary :cached))
        (should (< (abs (- (/ (+ (* 100000 1.0) (* ask 10.0) (* harness-compaction--summary-output 50.0)) 1e6)
                           (plist-get summary :cost)))
                   1e-9))
        ;; Once the cache lapses it reads all of it uncached: the other price.
        (should (< (abs (- (/ (+ (* (+ 100000 ask) 12.5) (* harness-compaction--summary-output 50.0)) 1e6)
                           (plist-get summary :cost-uncached)))
                   1e-9))
        (should (> (plist-get summary :cost-uncached) (plist-get summary :cost)))))
    ;; No catalogue prices: no costs, but the transcript's.
    (harness-define-provider 'unpriced
      :models (lambda () (harness-resolved (list (list :name "m" :context-window 100000))))
      :complete #'ignore)
    (let ((id (harness-compaction-test-long-session)))
      (harness-call 'session/update id :model "unpriced:m" :silent t)
      (let ((e (harness-call 'compaction/estimate id)))
        (should (> (plist-get e :context) 0))
        (should-not (plist-get e :carry-on))
        (should-not (plist-get (car (plist-get e :kinds)) :cost))
        (should-not (plist-get (cadr (plist-get e :kinds)) :cost))
        (should (eql 0.0 (plist-get (nth 2 (plist-get e :kinds)) :cost)))))))

(ert-deftest harness-compaction-estimate-prices-the-brief-summary-on-another-model ()
  "A model switch has the new model write the brief summary, so it asks
the estimate to price that one: the same narrative, on the model named."
  (harness-compaction-test-with
    (harness-compaction-test-tiered-provider)
    (let ((id (harness-compaction-test-long-session))
          (near (lambda (a b) (< (abs (- a b)) 1e-9))))
      (harness-call 'session/update id :model "tiered:big" :silent t)
      (let* ((brief (lambda (&optional opts)
                      (cl-find 'brief (plist-get (harness-call 'compaction/estimate id opts) :kinds)
                               :key (lambda (k) (plist-get k :kind)))))
             (usual (funcall brief))
             (other (funcall brief '(:brief-model "tiered:big"))))
        (should (equal "tiered:small" (plist-get usual :model)))
        (should (equal "tiered:big" (plist-get other :model)))
        (should (equal "Big" (plist-get other :model-label)))
        ;; The narrative is the same; the big model's list prices are higher.
        (should (= (plist-get usual :input) (plist-get other :input)))
        (should (funcall near (/ (+ (* (plist-get other :input) 12.5) (* (plist-get other :output) 50.0)) 1e6)
                         (plist-get other :cost)))
        (should (> (plist-get other :cost) (plist-get usual :cost)))))))

(ert-deftest harness-compaction-resend-cost-prices-the-context-both-ways ()
  "`compaction/resend-cost' says what sending the context costs read from the
cache and not: the numbers `compaction/estimate' carries on with, without the
rest of the estimate.  The uncached price is the dearer of cache write and
input.  A model the catalogue does not price has none."
  (harness-compaction-test-with
    (harness-compaction-test-tiered-provider)
    (let* ((id (harness-compaction-test-long-session))
           (near (lambda (a b) (< (abs (- a b)) 1e-9))))
      (harness-call 'session/update id :model "tiered:big" :silent t)
      (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 100000 :context 100000 :cache-at 1000.0))
      (let ((cost (harness-call 'compaction/resend-cost id))
            (estimate (harness-call 'compaction/estimate id)))
        (should (= 100000 (plist-get cost :context)))
        (should (equal "tiered:big" (plist-get cost :model)))
        (should (funcall near 0.1 (plist-get cost :cached)))
        (should (funcall near 1.25 (plist-get cost :uncached)))
        (should (funcall near (plist-get estimate :carry-on-cached) (plist-get cost :cached)))
        (should (funcall near (plist-get estimate :carry-on) (plist-get cost :uncached)))))
    (harness-define-provider 'unpriced
      :models (lambda () (harness-resolved (list (list :name "m" :context-window 100000))))
      :complete #'ignore)
    (let ((id (harness-compaction-test-long-session)))
      (harness-call 'session/update id :model "unpriced:m" :silent t)
      (let ((cost (harness-call 'compaction/resend-cost id)))
        (should (> (plist-get cost :context) 0))
        (should-not (plist-get cost :cached))
        (should-not (plist-get cost :uncached))))))

(ert-deftest harness-compaction-brief-reads-the-narrative ()
  "A `sample' context sends the whole narrative: every message, no elision.
The summary reads all of the conversation's turns and user messages,
rather than a start and an end with the middle left out."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-long-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (requests nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (let* ((node (harness-await (harness-call 'compaction/compact id (list :context "sample"))))
               (text (harness-compaction-test-request-text (car requests))))
          (should (eq 'sample (plist-get (plist-get node :meta) :context)))
          (should (= 21 (length (plist-get (car requests) :messages))))
          (dolist (i (number-sequence 0 19))
            (should (string-match-p (format "message %d" i) text)))
          (should-not (string-match-p "left out" text))
          (should (string-match-p "Summarize the conversation above" text)))))
    ;; An unknown context is refused.
    (should-error (harness-await (harness-call 'compaction/compact
                                               (harness-compaction-test-long-session)
                                               (list :context "sideways"))))))

(ert-deftest harness-compaction-keeps-the-first-and-last-messages ()
  "A model-written compaction keeps the first and last messages verbatim.
The summary stands for the middle; the task and the most recent message
stay as they were written, so nothing lossy eats them."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-long-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (node (harness-await (harness-call 'compaction/compact id))))
      (should (string-prefix-p "SUMMARY TEXT" (plist-get node :content)))
      (should (string-match-p "message 0" (plist-get node :content)))
      (should (string-match-p "message 19" (plist-get node :content)))
      (should (string-match-p "conversation opened with this message" (plist-get node :content)))
      (should (string-match-p "most recent message before this compaction" (plist-get node :content)))
      (should (string-match-p "kept verbatim rather than summarised" (plist-get node :content))))))

(ert-deftest harness-compaction-hosted-summariser-without-state-gets-text ()
  "A hosted summariser with no provider state of the session is sent the context as one message.
Claude Code and Copilot are sent only the newest user messages, so
messages carrying the whole transcript would never reach one; the
context goes inside a single message of structured text instead."
  (harness-compaction-test-with
    (let ((requests nil))
      (harness-define-provider 'hostedsum
        :complete (lambda (req)
                    (push req requests)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil (lambda ()
                                               (funcall on-event '(:type text :delta "SUMMARY"))
                                               (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :capabilities '(:hosted-loop t :compaction hosted))
      (let ((id (harness-compaction-test-long-session)))
        (let ((node (harness-await (harness-call 'compaction/compact id (list :model "hostedsum:m"))))
              (text (harness-compaction-test-request-text (car requests)))
              (messages (plist-get (car requests) :messages)))
          (should (eq 'full (plist-get (plist-get node :meta) :context)))
          (should-not (plist-get (car requests) :provider-state))
          (should (= 1 (length messages)))
          (should (eq 'user (plist-get (car messages) :role)))
          (should (string-match-p "### user" text))
          (should (string-match-p "### assistant" text))
          (dolist (i '(0 4 19)) (should (string-match-p (format "message %d" i) text)))
          (should (string-match-p "Summarize the conversation above" text))))
      ;; The same inlining carries a sampled context.
      (setq requests nil)
      (let* ((id (harness-compaction-test-long-session))
             (node (harness-await (harness-call 'compaction/compact
                                                id (list :model "hostedsum:m" :context "sample"))))
             (text (harness-compaction-test-request-text (car requests))))
        (should (eq 'sample (plist-get (plist-get node :meta) :context)))
        (should (= 1 (length (plist-get (car requests) :messages))))
        (dolist (i (number-sequence 0 19))
          (should (string-match-p (format "message %d" i) text)))
        (should-not (string-match-p "left out" text))))))

(ert-deftest harness-compaction-compact-error-rejects ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom")))
           (failed nil))
      (harness-on 'compaction/failed (lambda (sid msg) (push (list sid msg) failed)))
      (should-error (harness-await (harness-call 'compaction/compact id)))
      (should (equal '(user assistant hint hint) (harness-compaction-test-kinds id)))
      (should (equal "Compaction failed: boom" (cadr (harness-compaction-test-hints id))))
      (should (equal (list (list id "boom")) failed))
      (should (zerop (hash-table-count harness-compaction--running))))))

(ert-deftest harness-compaction-compact-runs-once-per-session ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (calls 0))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (cl-incf calls) (funcall orig req))))
        (let ((p1 (harness-call 'compaction/compact id))
              (p2 (harness-call 'compaction/compact id)))
          (should (eq p1 p2))
          (harness-await p1)))
      (should (= 1 calls))
      (should (= 1 (cl-count 'compaction (harness-compaction-test-kinds id)))))))

(ert-deftest harness-compaction-status-levels ()
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (cl-flet ((status-at (context)
                  (harness-call 'session/usage-add id (list :context context))
                  (harness-call 'compaction/status id)))
        (let ((s (status-at 1000)))
          (should (= 8000 (plist-get s :window)))
          (should (= 1000 (plist-get s :reserve)))
          (should (= 7000 (plist-get s :usable)))
          (should (= 1000 (plist-get s :context)))
          (should (< (abs (- (plist-get s :fraction) (/ 1000.0 7000))) 1e-6))
          (should (eq 'ok (plist-get s :level))))
        (should (eq 'warning (plist-get (status-at 5000) :level)))
        (should (eq 'urgent (plist-get (status-at 6000) :level)))
        (should (eq 'critical (plist-get (status-at 6900) :level)))
        (should (eq 'critical (plist-get (status-at 9000) :level)))))))

(ert-deftest harness-compaction-status-caps-reserve-for-small-windows ()
  (harness-compaction-test-with
    (let* ((harness-compaction--context-reserve 20000)
           (id (harness-compaction-test-session))
           (s (harness-call 'compaction/status id)))
      (should (= 4000 (plist-get s :usable)))
      (should (eq 'ok (plist-get s :level)))
      (should-not (harness-compaction-needed-p (harness-call 'session/get id))))))

(ert-deftest harness-compaction-context-limit-shortens-the-window ()
  "A session capped below its model's window compacts at the cap."
  (harness-compaction-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                        :model "demo:scripted" :context-window-limit 4000)
                          :id))
           (harness-provider-demo-script-override harness-compaction-test-script))
      (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
      (harness-call 'session/append id '(:kind assistant :content "Done: parser.el rewritten"))
      ;; Half of the demo model's 8000, less the test's 1000-token reserve.
      (let ((s (harness-call 'compaction/status id)))
        (should (= 4000 (plist-get s :window)))
        (should (= 3000 (plist-get s :usable))))
      ;; 3500 tokens compacts under the 4000 cap, where a session with
      ;; the whole 8000 window would not.
      (harness-call 'session/usage-add id '(:context 3500))
      (should (harness-compaction-needed-p (harness-call 'session/get id)))
      (harness-await (harness-call 'agent/prompt id "carry on"))
      (should (member 'compaction (harness-compaction-test-kinds id))))))

(ert-deftest harness-compaction-auto-compacts-before-turn ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (requests nil))
      (harness-call 'session/usage-add id '(:context 7500))
      (should (harness-compaction-needed-p (harness-call 'session/get id)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "next question"))
                                         :stop-reason))))
      (setq requests (nreverse requests))
      (should (= 2 (length requests)))
      ;; First the summariser, then the turn, whose transcript starts at the summary
      ;; and still carries the user's new message.
      (should (null (plist-get (car requests) :tools)))
      (let* ((turn (cadr requests))
             (first (car (plist-get turn :messages)))
             (texts (mapcar (lambda (b) (plist-get b :text)) (plist-get first :content))))
        (should (eq 'user (plist-get first :role)))
        (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY TEXT" (car texts)))
        (should (member "next question" texts)))
      (should (equal '(user assistant hint compaction hint user assistant)
                     (harness-compaction-test-kinds id)))
      ;; The user's message follows the compaction node exactly once.
      (should (equal "next question" (plist-get (nth 5 (harness-call 'session/nodes id)) :content)))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should (< (plist-get (plist-get (harness-call 'session/get id) :usage) :context) 7000)))))

(ert-deftest harness-compaction-auto-makes-the-configured-kind ()
  "Automatic compaction makes `harness-compaction-kind': here a transcript, no summary."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-compaction-kind 'transcript)
           (harness-provider-demo-script-override '((:type text :delta "ok") (:type done :stop-reason end-turn)))
           (requests nil))
      (harness-call 'session/usage-add id '(:context 7500))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (harness-await (harness-call 'agent/prompt id "next question")))
      ;; The turn only: a transcript asks no model.
      (should (= 1 (length requests)))
      (let* ((first (car (plist-get (car requests) :messages)))
             (texts (mapcar (lambda (b) (plist-get b :text)) (plist-get first :content))))
        (should (string-prefix-p "The conversation so far was compacted into a file" (car texts)))
        (should (member "next question" texts)))
      (should (equal "transcript" (harness-node-compaction-kind
                                   (cl-find 'compaction (harness-call 'session/nodes id)
                                            :key (lambda (n) (plist-get n :kind)))))))))

(ert-deftest harness-compaction-auto-idle-below-threshold ()
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-call 'session/usage-add id '(:context 6999))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (should-not (memq 'compaction (harness-compaction-test-kinds id))))))

(ert-deftest harness-compaction-auto-skips-hosted-providers ()
  (harness-compaction-test-with
    (let ((completes 0))
      (harness-define-provider 'hostedfake
        :label "Hosted fake"
        :complete (lambda (req)
                    (cl-incf completes)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil
                                   (lambda ()
                                     (funcall on-event '(:type text :delta "ok"))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :capabilities '(:hosted-loop t :compaction hosted))
      (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                         :model "hostedfake:m" :context-window 8000)
                           :id)))
        (harness-call 'session/usage-add id '(:context 7500))
        (should (harness-compaction-needed-p (harness-call 'session/get id)))
        (should (harness-compaction-hosted-p (harness-call 'session/get id)))
        (harness-await (harness-call 'agent/prompt id "hello"))
        (should (= 1 completes))
        (should (equal '(user assistant) (harness-compaction-test-kinds id)))))))

(ert-deftest harness-compaction-auto-proceeds-when-compaction-fails ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom")))
           (started 0))
      (harness-on 'agent/turn-started (lambda (_) (cl-incf started)))
      (harness-call 'session/usage-add id '(:context 7500))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (should (= 1 started))
      (should (member "Compaction failed: boom" (harness-compaction-test-hints id)))
      (should-not (memq 'compaction (harness-compaction-test-kinds id))))))

;;;; Truncate

(defun harness-compaction-test-compactions (id)
  "Return the compaction nodes of ID, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'compaction)) (harness-call 'session/nodes id)))

(ert-deftest harness-compaction-truncate-keeps-the-newest ()
  "Truncating drops the oldest nodes and keeps the newest verbatim, with a
note pointing at session_history; no model is asked anything."
  (harness-compaction-test-with
    (harness-test-load-module 'tools-sessions)
    (let* ((id (harness-compaction-test-long-session))
           (before (harness-compaction-test-kinds id))
           (harness-compaction--truncate-keep 0.1)
           (estimate (harness-call 'compaction/estimate id))
           (entry (cl-find-if (lambda (k) (equal "truncate" (format "%s" (plist-get k :kind))))
                              (plist-get estimate :kinds))))
      (should entry)
      (should (equal 0.0 (plist-get entry :cost)))
      (should (> (plist-get entry :dropped) 0))
      (should (< (plist-get entry :after) (plist-get estimate :context)))
      (let ((node (harness-await (harness-call 'compaction/compact id '(:kind "truncate")))))
        (should (eq 'compaction (plist-get node :kind)))
        (should (equal "truncate" (harness-node-compaction-kind node)))
        (should (string-match-p "not carried over" (plist-get node :content)))
        (should (string-match-p "session_history" (plist-get node :content)))
        (let ((meta (plist-get node :meta)))
          (should (> (plist-get meta :truncate-dropped) 0))
          (should (> (plist-get meta :truncate-kept) 0))
          (should (numberp (plist-get meta :dropped-tokens))))
        ;; The kept nodes follow the compaction node and its done-hint,
        ;; exactly the tail of what was there before.
        (let* ((kinds (harness-compaction-test-kinds id))
               (pos (cl-position 'compaction kinds)))
          (should pos)
          (should (equal '(compaction hint) (cl-subseq kinds pos (min (length kinds) (+ pos 2)))))
          (should (equal (last before (plist-get (plist-get node :meta) :truncate-kept))
                         (nthcdr (+ pos 2) kinds))))
        ;; The transcript restarts at the note, and is shorter.
        (should (string-prefix-p "This conversation was cut short"
                                 (harness-compaction-test-first-text id)))
        (should-not (string-prefix-p "Summary of the conversation so far:"
                                     (harness-compaction-test-first-text id)))
        (should (< (length (harness-call 'session/messages id)) (length before)))))))

(ert-deftest harness-compaction-truncate-refuses-a-small-conversation ()
  "A conversation that fits the keep budget has nothing to cut: the estimate
says so, and compacting with truncate signals."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (estimate (harness-call 'compaction/estimate id))
           (entry (cl-find-if (lambda (k) (equal "truncate" (format "%s" (plist-get k :kind))))
                              (plist-get estimate :kinds))))
      (should (equal 0 (plist-get entry :dropped)))
      (should (equal (plist-get estimate :context) (plist-get entry :after)))
      (should-error (harness-await (harness-call 'compaction/compact id '(:kind "truncate")))
                    :type 'harness-error))))

;;;; Queue and interrupt

(defun harness-compaction-test--running (id &optional handle)
  "Put a fake running turn in the agent's table for ID, and return it."
  (let ((turn (make-harness-agent-turn :session-id id :handle handle)))
    (puthash id turn harness-agent--turns)
    turn))

(ert-deftest harness-compaction-queue-runs-at-the-next-boundary ()
  "Queueing a compaction while a turn runs resolves at once and runs it
at the next step boundary, not before.  A second queued request replaces
the first."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script))
      (harness-compaction-test--running id)
      (harness-await (harness-call 'compaction/compact id '(:kind "summary" :queue t)))
      (should (equal '(:queued t :kind "brief" :interrupt nil)
                     (harness-await (harness-call 'compaction/compact id '(:kind "brief" :queue t)))))
      (should-not (harness-compaction-test-compactions id))
      ;; The next step boundary runs it.
      (harness-await (harness-run-filter-async 'agent/step (list :proceed t) (harness-call 'session/get id)))
      (let ((nodes (harness-compaction-test-compactions id)))
        (should (= 1 (length nodes)))
        (should (equal "brief" (harness-node-compaction-kind (car nodes)))))
      (should-not (gethash id harness-compaction--pending))
      (should-not (gethash id harness-compaction--running)))))

(ert-deftest harness-compaction-queue-runs-when-the-turn-ends ()
  "A compaction queued while a turn runs and never taking another step
runs as soon as the turn ends."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script))
      (harness-compaction-test--running id)
      (harness-await (harness-call 'compaction/compact id '(:kind "brief" :queue t)))
      (should-not (harness-compaction-test-compactions id))
      (remhash id harness-agent--turns)
      (harness-emit 'agent/turn-ended id 'end-turn)
      (harness-test-wait (lambda () (harness-compaction-test-compactions id)) 5 "the queued compaction")
      (let ((nodes (harness-compaction-test-compactions id)))
        (should (= 1 (length nodes)))
        (should (equal "brief" (harness-node-compaction-kind (car nodes)))))
      (should-not (gethash id harness-compaction--pending)))))

(ert-deftest harness-compaction-interrupt-cancels-the-turn ()
  "Interrupting to compact cancels the running turn at once and runs the
compaction once the turn is over, however it ended."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (cancelled nil)
           (turn (harness-compaction-test--running
                  id (list :cancel (lambda () (setq cancelled t))))))
      (should (equal '(:queued t :kind "transcript" :interrupt t)
                     (harness-await (harness-call 'compaction/compact id '(:kind "transcript" :interrupt t)))))
      (should cancelled)
      (should (harness-agent-turn-cancelled turn))
      (should-not (harness-compaction-test-compactions id))
      ;; The turn ends: the queued compaction runs.
      (remhash id harness-agent--turns)
      (harness-emit 'agent/turn-ended id 'cancelled)
      (harness-test-wait (lambda () (harness-compaction-test-compactions id)) 5 "the interrupted compaction")
      (let ((nodes (harness-compaction-test-compactions id)))
        (should (= 1 (length nodes)))
        (should (equal "transcript" (harness-node-compaction-kind (car nodes)))))
      (should-not (gethash id harness-compaction--pending)))))

(ert-deftest harness-compaction-idle-queue-runs-now-and-idle-refuses ()
  "An idle session with `:queue' compacts at once, leaving nothing pending;
`:idle' still refuses a running turn."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (node (harness-await (harness-call 'compaction/compact id '(:kind "transcript" :queue t)))))
      (should (eq 'compaction (plist-get node :kind)))
      (should (equal "transcript" (harness-node-compaction-kind node)))
      (should-not (gethash id harness-compaction--pending))
      (harness-compaction-test--running id)
      (should-error (harness-await (harness-call 'compaction/compact id '(:kind "transcript" :idle t)))
                    :type 'harness-error))))

;;;; In the middle of a turn

(defun harness-compaction-test-define-echo ()
  "Define the tool `echo', which the turns of the tests below call."
  (harness-define-tool "echo" :label "Echo" :description "echo" :kind 'read
                       :handler (lambda (input _ctx) (format "echoed %s" (plist-get input :text)))))

(defun harness-compaction-test-requests-of (thunk)
  "Call THUNK; return the provider requests made meanwhile, oldest first."
  (let ((requests nil))
    (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
               ((symbol-function 'harness-method/provider/complete)
                (lambda (req) (push req requests) (funcall orig req))))
      (funcall thunk))
    (nreverse requests)))

(defun harness-compaction-test-summary-request-p (request)
  "Non-nil when REQUEST asks a model for the summary of a compaction."
  (string-match-p "handoff summary" (or (plist-get request :system) "")))

(defun harness-compaction-test-tool-turn (contexts &optional on-summary)
  "Return a demo script for a turn that calls the tool `echo' at every step but its last.
CONTEXTS lists the context each model call of the turn reports -- the
size of its prompt -- the last one answering instead of calling a tool.
A request for the summary of a compaction gets one (SUMMARY TEXT), after
ON-SUMMARY, a function of no arguments, was called when it is given."
  (let ((step 0))
    (lambda (request)
      (if (harness-compaction-test-summary-request-p request)
          (progn (when on-summary (funcall on-summary))
                 harness-compaction-test-script)
        (let ((context (nth step contexts)))
          (cl-incf step)
          (if (= step (length contexts))
              `((:type text :delta "All done.")
                (:type usage :input 10 :output 5 :context ,context)
                (:type done :stop-reason end-turn))
            `((:type text :delta ,(format "Step %d." step))
              (:type usage :input 10 :output 5 :context ,context)
              (:type tool-call :id ,(format "call-%d" step) :name "echo"
                     :input (:text ,(format "%d" step))))))))))

(defun harness-compaction-test-step-gate (id &optional value)
  "Run the `agent/step' gate of session ID, VALUE the gate so far; return what it lets through."
  (harness-await (harness-run-filter-async 'agent/step (or value (list :proceed t))
                                           (harness-call 'session/get id))))

(defun harness-compaction-test-compaction-count (id)
  "Return how many compactions session ID's transcript holds."
  (cl-count 'compaction (harness-compaction-test-kinds id)))

(ert-deftest harness-compaction-mid-turn-compacts-between-the-steps ()
  "A turn whose context went over the limit is compacted before its next step.
The first step reports a context of 7500 tokens, over the 7000 an 8000
window leaves.  The boundary after its tool call has the conversation
summarised, and the second step goes on from the summary, told that its
work is not finished: one turn throughout, ended by its model."
  (harness-compaction-test-with
    (harness-compaction-test-define-echo)
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override (harness-compaction-test-tool-turn '(7500 600)))
           (steps nil) (phases nil) (done nil))
      (should harness-compaction-mid-turn)
      (harness-on 'agent/step-started (lambda (_ n) (push n steps)))
      (harness-on 'agent/activity-changed (lambda (_ activity) (push (plist-get activity :phase) phases)))
      (harness-on 'compaction/done (lambda (sid node) (push (list sid (plist-get node :id)) done)))
      (let ((requests (harness-compaction-test-requests-of
                       (lambda ()
                         (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go"))
                                                          :stop-reason)))))))
        ;; The turn's first step, the summary, the step that goes on from it.
        (should (= 3 (length requests)))
        (should (plist-get (nth 0 requests) :tools))
        (should (harness-compaction-test-summary-request-p (nth 1 requests)))
        (should (null (plist-get (nth 1 requests) :tools)))
        (should (plist-get (nth 2 requests) :tools))
        ;; That step sends the summary alone: the work before it is in it.
        (let* ((messages (plist-get (nth 2 requests) :messages))
               (blocks (plist-get (car messages) :content))
               (text (plist-get (car blocks) :text)))
          (should (= 1 (length messages)))
          (should (= 1 (length blocks)))
          (should (eq 'user (plist-get (car messages) :role)))
          (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY TEXT" text))
          (should (string-suffix-p harness-compaction--mid-turn-note text))))
      ;; Two steps of one turn, the compaction between them.
      (should (equal '(2 1) steps))
      (should (equal '(user assistant user assistant tool-call tool-result hint compaction hint assistant)
                     (harness-compaction-test-kinds id)))
      (let ((node (car (harness-compaction-test-compactions id))))
        (should (equal "summary" (harness-node-compaction-kind node)))
        (should (eq t (plist-get (plist-get node :meta) :mid-turn)))
        (should (string-suffix-p harness-compaction--mid-turn-note (plist-get node :content)))
        (should (equal (list (list id (plist-get node :id))) done)))
      (let ((hints (harness-compaction-test-hints id)))
        (should (equal "Compacting context in the middle of the turn…" (car hints)))
        (should (string-match-p "\\`Compacted: [0-9.k]+ tokens → summary\\'" (cadr hints))))
      ;; The chat is told the turn compacts, and then that it waits for its model again.
      (should (equal '(compacting waiting) (cl-subseq (member 'compacting (reverse phases)) 0 2)))
      (should-not (harness-agent-running-p id))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should (= 600 (plist-get (plist-get (harness-call 'session/get id) :usage) :context)))
      ;; What the turn learned of compacting goes with it.
      (should-not (gethash id harness-compaction--mid-turn)))))

(ert-deftest harness-compaction-mid-turn-can-be-turned-off ()
  "With `harness-compaction-mid-turn' nil a turn runs on past the limit, as it did.
Its conversation is compacted before the next turn all the same."
  (harness-compaction-test-with
    (harness-compaction-test-define-echo)
    (let* ((id (harness-compaction-test-session))
           (harness-compaction-mid-turn nil)
           (harness-provider-demo-script-override (harness-compaction-test-tool-turn '(7500 7600)))
           (requests (harness-compaction-test-requests-of
                      (lambda () (harness-await (harness-call 'agent/prompt id "go"))))))
      ;; Two steps and no summary: the second sends everything again.
      (should (= 2 (length requests)))
      (should (cl-every (lambda (request) (plist-get request :tools)) requests))
      (should (= 5 (length (plist-get (cadr requests) :messages))))
      (should (equal '(user assistant user assistant tool-call tool-result assistant)
                     (harness-compaction-test-kinds id)))
      (should-not (gethash id harness-compaction--mid-turn))
      ;; The next turn meets the context before it starts.
      (setq harness-provider-demo-script-override harness-compaction-test-script)
      (harness-await (harness-call 'agent/prompt id "and now?"))
      (let ((nodes (harness-compaction-test-compactions id)))
        (should (= 1 (length nodes)))
        (should-not (plist-get (plist-get (car nodes) :meta) :mid-turn))
        (should-not (string-search harness-compaction--mid-turn-note (plist-get (car nodes) :content)))))))

(ert-deftest harness-compaction-mid-turn-leaves-a-turn-under-its-limit-alone ()
  "A turn that stays under its limit is not compacted in its middle."
  (harness-compaction-test-with
    (harness-compaction-test-define-echo)
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override (harness-compaction-test-tool-turn '(3000 6999)))
           (requests (harness-compaction-test-requests-of
                      (lambda () (harness-await (harness-call 'agent/prompt id "go"))))))
      (should (= 2 (length requests)))
      (should-not (harness-compaction-test-compactions id)))))

(ert-deftest harness-compaction-mid-turn-step-gate-needs-the-turn-to-go-on-and-the-limit-passed ()
  "The step gate compacts only a step that goes on, the option on, the context over its limit."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session))
          (harness-provider-demo-script-override harness-compaction-test-script))
      ;; Under the limit: nothing to do.
      (harness-call 'session/usage-add id '(:context 6999))
      (should (plist-get (harness-compaction-test-step-gate id) :proceed))
      (should (= 0 (harness-compaction-test-compaction-count id)))
      ;; Over it, but another gate refused the step already: the refusal stands.
      (harness-call 'session/usage-add id '(:context 7500))
      (let ((gate (harness-compaction-test-step-gate id '(:proceed nil :reason "no money"))))
        (should-not (plist-get gate :proceed))
        (should (equal "no money" (plist-get gate :reason))))
      (should (= 0 (harness-compaction-test-compaction-count id)))
      ;; The option is off.
      (let ((harness-compaction-mid-turn nil))
        (should (plist-get (harness-compaction-test-step-gate id) :proceed)))
      (should (= 0 (harness-compaction-test-compaction-count id)))
      ;; Over the limit, the step goes on: compacted first.
      (should (plist-get (harness-compaction-test-step-gate id) :proceed))
      (should (= 1 (harness-compaction-test-compaction-count id)))
      (should (eq t (plist-get (plist-get (car (harness-compaction-test-compactions id)) :meta) :mid-turn))))))

(ert-deftest harness-compaction-mid-turn-is-not-made-for-a-step-another-gate-refuses ()
  "A step the budget's gate refuses is not compacted for, which would only spend money.
The gate that looks at hard budgets (priority 30) comes before the
compaction in the middle of a turn: a step it refuses ends the turn
`blocked', and the summary of a conversation it never sends on would
be a request made over the budget.  The gate that holds a step for a
merge works the same way, and a hold is over when the context is looked at."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (refuse (lambda (value next _session)
                     (funcall next (if (plist-get value :proceed)
                                       (list :proceed nil :reason "the budget is spent")
                                     value))))
           (chain (lambda () (mapcar #'car (cl-remove-if-not (lambda (f) (memq (cdr f) '(harness-compaction--before-step)))
                                                              (gethash 'agent/step harness--filters)))))
           (requests 0))
      (harness-call 'session/usage-add id '(:context 7500))
      (should (equal '(35) (funcall chain)))
      (harness-add-filter 'agent/step refuse 30)
      (unwind-protect
          (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                     ((symbol-function 'harness-method/provider/complete)
                      (lambda (req) (cl-incf requests) (funcall orig req))))
            (let ((gate (harness-compaction-test-step-gate id)))
              (should-not (plist-get gate :proceed))
              (should (equal "the budget is spent" (plist-get gate :reason))))
            (should (= 0 requests))
            (should (= 0 (harness-compaction-test-compaction-count id))))
        (harness-remove-filter 'agent/step refuse))
      ;; Without the refusal the same boundary compacts.
      (should (plist-get (harness-compaction-test-step-gate id) :proceed))
      (should (= 1 (harness-compaction-test-compaction-count id))))))

(ert-deftest harness-compaction-mid-turn-leaves-hosted-providers-alone ()
  "A provider that compacts on its own side is not compacted in the middle of a turn."
  (harness-compaction-test-with
    (let ((completes 0))
      (harness-define-provider 'hostedfake
        :label "Hosted fake"
        :complete (lambda (req)
                    (cl-incf completes)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil
                                   (lambda ()
                                     (funcall on-event '(:type text :delta "ok"))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :capabilities '(:hosted-loop t :compaction hosted))
      (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                         :model "hostedfake:m" :context-window 8000)
                           :id)))
        (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
        (harness-call 'session/append id '(:kind assistant :content "Done: parser.el rewritten"))
        (harness-call 'session/usage-add id '(:context 7500))
        (should (harness-compaction-needed-p (harness-call 'session/get id)))
        (should (harness-compaction-hosted-p (harness-call 'session/get id)))
        (should (plist-get (harness-compaction-test-step-gate id) :proceed))
        (should (= 0 completes))
        (should (equal '(user assistant) (harness-compaction-test-kinds id)))
        (should-not (gethash id harness-compaction--mid-turn))))))

(ert-deftest harness-compaction-mid-turn-is-not-repeated-at-every-step ()
  "A compaction that left the context over the limit waits some steps for the next.
A conversation that stays over a small limit would otherwise be
summarised at every step.  Each try that does not help waits twice as
long, and a boundary that finds the context under the limit starts over."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session))
          (harness-provider-demo-script-override harness-compaction-test-script))
      (cl-flet ((boundary (context)
                  ;; The step before it reported CONTEXT as its prompt.
                  (harness-call 'session/usage-add id (list :context context))
                  (should (plist-get (harness-compaction-test-step-gate id) :proceed))
                  (harness-compaction-test-compaction-count id)))
        ;; Tried at once, then at the third boundary over the limit after
        ;; it, then at the sixth after that.
        (should (equal '(1 1 1 2 2 2 2 2 2 3)
                       (cl-loop repeat 10 collect (boundary 7500))))
        ;; Under the limit the tries start over: the next is due at once,
        ;; and the one after it waits three boundaries again.
        (boundary 100)
        (should-not (gethash id harness-compaction--mid-turn))
        (should (equal '(4 4 4 5) (cl-loop repeat 4 collect (boundary 7500))))))))

(ert-deftest harness-compaction-mid-turn-failure-goes-on-and-is-not-asked-again-at-once ()
  "A compaction that fails lets the step go on, and is tried again later, not at every step."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session))
          (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom")))
          (failed nil))
      (harness-on 'compaction/failed (lambda (_sid msg) (push msg failed)))
      (cl-flet ((boundary ()
                  (harness-call 'session/usage-add id '(:context 7500))
                  (should (plist-get (harness-compaction-test-step-gate id) :proceed))
                  (length failed)))
        (should (equal '(1 1 1 2) (cl-loop repeat 4 collect (boundary)))))
      (should (equal '("boom" "boom") failed))
      (should (equal '("Compaction failed: boom" "Compaction failed: boom")
                     (cl-remove-if-not (lambda (hint) (string-prefix-p "Compaction failed" hint))
                                       (harness-compaction-test-hints id))))
      (should-not (harness-compaction-test-compactions id))
      ;; Gone with the turn, and with the session.
      (should (gethash id harness-compaction--mid-turn))
      (harness-emit 'agent/turn-ended id 'end-turn)
      (should-not (gethash id harness-compaction--mid-turn))
      (puthash id (list :tries 2 :since 1) harness-compaction--mid-turn)
      (harness-emit 'session/deleted id)
      (should-not (gethash id harness-compaction--mid-turn)))))

(ert-deftest harness-compaction-mid-turn-carries-over-a-message-sent-meanwhile ()
  "A message sent to the turn while its summary is written reaches the model.
The summary of a long conversation takes a while.  A message the user
sends meanwhile lies before the compaction node on the path, which the
model never reads, so it is carried over after it, as an unanswered
message at the end of a conversation is: once, and delivered already,
not queued for good."
  (harness-compaction-test-with
    (harness-compaction-test-define-echo)
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override
            (harness-compaction-test-tool-turn
             '(7500 600) (lambda () (harness-call 'agent/prompt id "also check the lexer"))))
           (requests (harness-compaction-test-requests-of
                      (lambda ()
                        (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go"))
                                                         :stop-reason)))))))
      (should (= 3 (length requests)))
      ;; The step after the summary reads the message once, after the summary.
      (let* ((messages (plist-get (nth 2 requests) :messages))
             (texts (mapcar (lambda (b) (plist-get b :text)) (plist-get (car messages) :content))))
        (should (= 1 (length messages)))
        (should (string-prefix-p "Summary of the conversation so far:" (car texts)))
        (should (equal '("also check the lexer") (cdr texts))))
      ;; The message was held while the summary was written: it is not
      ;; before the compaction, but once, as a user message after it.
      (let* ((nodes (harness-call 'session/nodes id))
             (compaction (car (harness-compaction-test-compactions id)))
             (pos (cl-position (plist-get compaction :id) nodes :key (lambda (n) (plist-get n :id)) :test #'equal))
             (texts (lambda (ns) (delq nil (mapcar (lambda (n) (and (eq (plist-get n :kind) 'user) (plist-get n :content))) ns)))))
        (should-not (member "also check the lexer" (funcall texts (cl-subseq nodes 0 pos))))
        (should (equal '("also check the lexer") (funcall texts (nthcdr pos nodes))))))))

(ert-deftest harness-compaction-mid-turn-makes-the-configured-kind ()
  "A compaction in the middle of a turn is of `harness-compaction-kind', and tells the model to go on.
A transcript asks no model, so the turn makes two requests, and the
note that points at the file ends in the one that says the work goes on."
  (harness-compaction-test-with
    (harness-compaction-test-define-echo)
    (let* ((id (harness-compaction-test-session))
           (harness-compaction-kind 'transcript)
           (harness-provider-demo-script-override (harness-compaction-test-tool-turn '(7500 600)))
           (requests (harness-compaction-test-requests-of
                      (lambda () (harness-await (harness-call 'agent/prompt id "go"))))))
      (should (= 2 (length requests)))
      (let* ((first (car (plist-get (cadr requests) :messages)))
             (text (plist-get (car (plist-get first :content)) :text)))
        (should (= 1 (length (plist-get (cadr requests) :messages))))
        (should (string-prefix-p "The conversation so far was compacted into a file" text))
        (should (string-suffix-p harness-compaction--mid-turn-note text)))
      (let ((node (car (harness-compaction-test-compactions id))))
        (should (equal "transcript" (harness-node-compaction-kind node)))
        (should (eq t (plist-get (plist-get node :meta) :mid-turn)))
        (should (file-exists-p (plist-get (plist-get node :meta) :file)))))))

(ert-deftest harness-compaction-mid-turn-names-its-brief-summary ()
  "The hint of a brief summary made in the middle of a turn says so, and who writes it."
  (harness-compaction-test-with
    (harness-compaction-test-tiered-provider)
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                       :model "tiered:big" :context-window 8000)
                         :id))
          (harness-compaction-kind 'brief))
      (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
      (harness-call 'session/usage-add id '(:context 7500))
      (should (plist-get (harness-compaction-test-step-gate id) :proceed))
      (should (equal "Compacting context in the middle of the turn: a brief summary by Small…"
                     (car (harness-compaction-test-hints id))))
      (should (equal "brief" (harness-node-compaction-kind (car (harness-compaction-test-compactions id))))))))

(ert-deftest harness-compaction-mid-turn-is-a-setting ()
  "The settings page offers the switch, in the compaction section, on by default."
  (harness-compaction-test-with
    (let* ((saved nil)
           (setting (lambda ()
                      (cl-find "harness-compaction-mid-turn"
                               (plist-get (harness-call 'config/describe default-directory) :settings)
                               :key (lambda (s) (plist-get s :key)) :test #'equal))))
      (should (eq t (default-value 'harness-compaction-mid-turn)))
      (should (equal "compaction" (plist-get (funcall setting) :section)))
      (should (equal "t" (plist-get (funcall setting) :value)))
      (should (eq :false (plist-get (funcall setting) :layered)))
      (cl-letf (((symbol-function 'harness-save-user-option)
                 (lambda (symbol value) (set symbol value) (push (cons symbol value) saved))))
        (let ((harness-compaction-mid-turn harness-compaction-mid-turn))
          (harness-call 'config/set 'harness-compaction-mid-turn "nil" :printed t :scope 'global)
          (should (equal '((harness-compaction-mid-turn)) saved))
          (should-not harness-compaction-mid-turn)
          (should (equal "nil" (plist-get (funcall setting) :value))))))))

;;;; A message that comes while a compaction runs

;; Whichever turn the compaction holds -- before its first request, or
;; between two steps (a compaction queued for the boundary, or the one
;; made in the middle of a turn) -- a message sent meanwhile does not
;; steer it: it waits with the turn and is recorded after the compaction
;; (`agent/hold').  A test of one that expects the message as a steering
;; node before the compaction node, copied after it, expects what that
;; replaced.

(defvar harness-compaction-test--requests nil
  "The requests of the turns the demo provider answered, newest first.
The summaries a compaction asks for are not among them.")

(defun harness-compaction-test--summary-p (request)
  "Non-nil when REQUEST asks for a summary: a compaction's."
  (string-match-p "handoff summary" (or (plist-get request :system) "")))

(defun harness-compaction-test--answer (request)
  "Answer REQUEST: the summary when it asks for one, else a short reply.
The turns' requests are kept in `harness-compaction-test--requests'."
  (if (harness-compaction-test--summary-p request)
      harness-compaction-test-script
    (push request harness-compaction-test--requests)
    '((:type text :delta "Done.") (:type done :stop-reason end-turn))))

(defun harness-compaction-test-user-texts (id)
  "Return the texts of the user messages of session ID, oldest first."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes id))))

(defun harness-compaction-test-steering (id)
  "Return the steering messages recorded in session ID."
  (cl-remove-if-not (lambda (n) (plist-get (plist-get n :meta) :steering)) (harness-call 'session/nodes id)))

(defun harness-compaction-test-wait-waiting (id)
  "Wait until the turn of session ID waits for a compaction, shown as running."
  (harness-test-wait (lambda () (and (harness-compaction-busy-p id)
                                     (eq 'running (plist-get (harness-call 'session/get id) :status))))
                     10 "the turn to wait for the compaction"))

(ert-deftest harness-compaction-a-message-that-comes-while-it-runs-goes-after-it ()
  "A message sent to an idle session while a compaction of it runs waits for it.
No turn runs beside the compaction, which would bury its exchange: the
conversation restarts at the compaction node, which comes after the
whole exchange.  The turn waits, the session reads as compacting and
says what waits, and a second message waits with it.  Once the
compaction is done they are the user's messages after it, in the order
sent, and the model answers both in one request."
  (harness-compaction-test-with
    (setq harness-compaction-test--requests nil)
    (let* ((harness-provider-demo--delay 0.15)
           (harness-provider-demo-script-override #'harness-compaction-test--answer)
           (id (harness-compaction-test-session))
           (compaction (harness-call 'compaction/compact id '(:kind "summary" :idle t)))
           (turn (harness-call 'agent/prompt id "and now the lexer")))
      (harness-compaction-test-wait-waiting id)
      (should-not harness-compaction-test--requests)
      (should (eq 'compacting (plist-get (harness-call 'agent/activity id) :phase)))
      (should (equal "1 message waits: “and now the lexer”"
                     (plist-get (harness-call 'agent/activity id) :detail)))
      ;; Not in the transcript, which the compaction is about to replace.
      (should-not (member "and now the lexer" (harness-compaction-test-user-texts id)))
      (should (eq turn (harness-call 'agent/prompt id "and the parser")))
      (should (equal "2 messages wait"
                     (plist-get (harness-call 'agent/activity id) :detail)))
      (should-not (plist-get (harness-call 'session/get id) :queue))
      (should (eq 'end-turn (plist-get (harness-test-await turn 20) :stop-reason)))
      (harness-test-await compaction 5)
      (should (equal '(user assistant hint compaction hint user user assistant)
                     (harness-compaction-test-kinds id)))
      (should (equal '("please refactor the parser" "and now the lexer" "and the parser")
                     (harness-compaction-test-user-texts id)))
      (should-not (harness-compaction-test-steering id))
      ;; The model read the summary and both messages, once.
      (should (= 1 (length harness-compaction-test--requests)))
      (let ((text (harness-compaction-test-request-text (car harness-compaction-test--requests))))
        (should (string-match-p "\\`Summary of the conversation so far:\n\nSUMMARY TEXT" text))
        (should (string-match-p "and now the lexer\nand the parser\\'" text)))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should-not (harness-call 'agent/activity id)))))

(defun harness-compaction-test-waiting (id)
  "Return the items of the messages session ID lists as waiting for its turn."
  (plist-get (harness-call 'session/get id) :steering))

(defun harness-compaction-test-waiting-texts (id)
  "Return the texts of the messages session ID lists as waiting."
  (mapcar (lambda (item) (plist-get item :text)) (harness-compaction-test-waiting id)))

(ert-deftest harness-compaction-the-messages-that-wait-for-it-show-as-queued ()
  "A message that does not go because a compaction runs shows as queued.
The turn that message opened waits for the compaction, and so does a
message sent to it meanwhile: the session lists both, in the order sent,
saying they wait for the compaction -- a UI draws them as the queue's
messages above its compose box -- and neither is a node of the
transcript the compaction replaces.  They are recorded after it under
the ids they were listed with, and the list is empty again."
  (harness-compaction-test-with
    (setq harness-compaction-test--requests nil)
    (let* ((harness-provider-demo--delay 0.15)
           (harness-provider-demo-script-override #'harness-compaction-test--answer)
           (id (harness-compaction-test-session))
           (compaction (harness-call 'compaction/compact id '(:kind "summary" :idle t)))
           (turn (harness-call 'agent/prompt id "and now the lexer")))
      (harness-compaction-test-wait-waiting id)
      (should (equal '("and now the lexer") (harness-compaction-test-waiting-texts id)))
      (should (equal "the compaction" (plist-get (car (harness-compaction-test-waiting id)) :why)))
      (should (eq turn (harness-call 'agent/prompt id "and the parser")))
      (should (equal '("and now the lexer" "and the parser") (harness-compaction-test-waiting-texts id)))
      (should (equal '("the compaction" "the compaction")
                     (mapcar (lambda (item) (plist-get item :why)) (harness-compaction-test-waiting id))))
      (should-not (plist-get (harness-call 'session/get id) :queue))
      (should-not (member "and the parser" (harness-compaction-test-user-texts id)))
      (let ((listed (mapcar (lambda (item) (plist-get item :id)) (harness-compaction-test-waiting id))))
        (should (eq 'end-turn (plist-get (harness-test-await turn 20) :stop-reason)))
        (harness-test-await compaction 5)
        (let ((users (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                       (harness-call 'session/nodes id))))
          (should (equal listed (mapcar (lambda (n) (plist-get n :id)) (last users 2))))))
      (should-not (harness-compaction-test-waiting id)))))

(ert-deftest harness-compaction-a-message-that-waits-for-it-can-be-taken-back ()
  "[delete] on a message that waits for the compaction takes it out of what
the turn records: the model never reads it, the other goes on."
  (harness-compaction-test-with
    (setq harness-compaction-test--requests nil)
    (let* ((harness-provider-demo--delay 0.15)
           (harness-provider-demo-script-override #'harness-compaction-test--answer)
           (id (harness-compaction-test-session))
           (compaction (harness-call 'compaction/compact id '(:kind "summary" :idle t)))
           (turn (harness-call 'agent/prompt id "and now the lexer")))
      (harness-compaction-test-wait-waiting id)
      (harness-call 'agent/prompt id "and the parser")
      (let ((node (harness-call 'agent/withdraw id (plist-get (cadr (harness-compaction-test-waiting id)) :id))))
        (should (equal "and the parser" (plist-get node :content))))
      (should (equal '("and now the lexer") (harness-compaction-test-waiting-texts id)))
      (should (eq 'end-turn (plist-get (harness-test-await turn 20) :stop-reason)))
      (harness-test-await compaction 5)
      (should (equal '("please refactor the parser" "and now the lexer") (harness-compaction-test-user-texts id)))
      (let ((text (harness-compaction-test-request-text (car harness-compaction-test--requests))))
        (should (string-match-p "and now the lexer\\'" text))
        (should-not (string-match-p "and the parser\\'" text))))))

(ert-deftest harness-compaction-taking-back-the-message-that-opened-the-turn ()
  "Taken back while the compaction runs, the message that opened the turn
is never recorded and the turn it opened is cancelled: the compaction
goes on, as it is nobody's to cancel, and the model is asked nothing."
  (harness-compaction-test-with
    (setq harness-compaction-test--requests nil)
    (let* ((harness-provider-demo--delay 0.15)
           (harness-provider-demo-script-override #'harness-compaction-test--answer)
           (id (harness-compaction-test-session))
           (compaction (harness-call 'compaction/compact id '(:kind "summary" :idle t)))
           (turn (harness-call 'agent/prompt id "and now the lexer")))
      (harness-compaction-test-wait-waiting id)
      (harness-call 'agent/withdraw id (plist-get (car (harness-compaction-test-waiting id)) :id))
      (should-not (harness-compaction-test-waiting id))
      (should (eq 'cancelled (plist-get (harness-test-await turn 20) :stop-reason)))
      (harness-test-await compaction 5)
      (should (equal '("please refactor the parser") (harness-compaction-test-user-texts id)))
      (should-not harness-compaction-test--requests)
      (should (memq 'compaction (harness-compaction-test-kinds id)))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status))))))

(ert-deftest harness-compaction-the-compaction-before-a-turn-shows-the-message-that-waits ()
  "The automatic compaction a turn waits for shows its message as queued.
The turn's own message is no node until the compaction is done, and
that takes a while: it is listed meanwhile, with the one sent after it."
  (harness-compaction-test-with
    (setq harness-compaction-test--requests nil)
    (let* ((harness-provider-demo--delay 0.15)
           (harness-provider-demo-script-override #'harness-compaction-test--answer)
           (id (harness-compaction-test-session))
           (_ (harness-call 'session/usage-add id '(:context 7500)))
           (turn (harness-call 'agent/prompt id "next question")))
      (harness-test-wait (lambda () (harness-compaction-busy-p id)) 10 "the automatic compaction")
      (should (equal '("next question") (harness-compaction-test-waiting-texts id)))
      (should (equal "the compaction" (plist-get (car (harness-compaction-test-waiting id)) :why)))
      (harness-call 'agent/prompt id "one more thing")
      (should (equal '("next question" "one more thing") (harness-compaction-test-waiting-texts id)))
      (should (eq 'end-turn (plist-get (harness-test-await turn 20) :stop-reason)))
      (should-not (harness-compaction-test-waiting id))
      (should (equal '("please refactor the parser" "next question" "one more thing")
                     (harness-compaction-test-user-texts id))))))

(ert-deftest harness-compaction-a-turn-that-met-no-compaction-is-left-alone ()
  "With no compaction under way a turn starts at once, and a message sent
to it steers it, as it always did."
  (harness-compaction-test-with
    (setq harness-compaction-test--requests nil)
    (let* ((harness-provider-demo-script-override #'harness-compaction-test--answer)
           (id (harness-compaction-test-session))
           (turn (harness-call 'agent/prompt id "go")))
      (harness-test-wait (lambda () (harness-call 'agent/running id)))
      (should-not (harness-compaction--on-hold nil id))
      (harness-call 'agent/prompt id "and this")
      ;; It steers: it waits for the turn's next step, listed on the session,
      ;; and is a node where the model reads it.
      (should (equal '("and this") (mapcar (lambda (item) (plist-get item :text))
                                           (plist-get (harness-call 'session/get id) :steering))))
      (harness-test-await turn 10)
      (should (= 1 (length (harness-compaction-test-steering id))))
      (should-not (plist-get (harness-call 'session/get id) :steering))
      (should-not (memq 'compaction (harness-compaction-test-kinds id))))))

(ert-deftest harness-compaction-says-it-holds-a-turn-only-while-it-runs ()
  "The `agent/hold' answer is the compaction's while one of the session
runs, and the first handler to answer wins."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (should-not (harness-compaction--on-hold nil id))
      (puthash id (harness-make-promise) harness-compaction--running)
      (should (equal '(:text "the compaction" :phase compacting) (harness-compaction--on-hold nil id)))
      (should (equal '(:text "another" :phase waiting)
                     (harness-compaction--on-hold '(:text "another" :phase waiting) id)))
      (should-not (harness-compaction--on-hold nil "another-session"))
      (remhash id harness-compaction--running))))

(ert-deftest harness-compaction-a-failed-compaction-lets-the-waiting-messages-go ()
  "A compaction that fails leaves the conversation as it was, and the
messages that waited for it go on with it: nothing is lost to the failure."
  (harness-compaction-test-with
    (setq harness-compaction-test--requests nil)
    (let* ((harness-provider-demo--delay 0.1)
           (harness-provider-demo-script-override
            (lambda (request)
              (if (harness-compaction-test--summary-p request)
                  '((:type done :stop-reason error :error "boom"))
                (harness-compaction-test--answer request))))
           (id (harness-compaction-test-session))
           (compaction (harness-call 'compaction/compact id '(:kind "summary" :idle t)))
           (turn (harness-call 'agent/prompt id "carry on")))
      (harness-compaction-test-wait-waiting id)
      (harness-call 'agent/prompt id "and this too")
      (should-error (harness-test-await compaction 10))
      (should (eq 'end-turn (plist-get (harness-test-await turn 20) :stop-reason)))
      (should-not (memq 'compaction (harness-compaction-test-kinds id)))
      (should (equal '("please refactor the parser" "carry on" "and this too")
                     (harness-compaction-test-user-texts id)))
      (let ((text (harness-compaction-test-request-text (car harness-compaction-test--requests))))
        (should (string-match-p "please refactor the parser" text))
        (should (string-match-p "carry on\nand this too\\'" text))))))

(ert-deftest harness-compaction-the-compaction-before-a-turn-holds-its-messages ()
  "A message sent while the compaction a turn waits for runs -- the
automatic one, before the turn -- waits with the turn rather than steer
it: sent so, it would lie before the compaction, which the model never
reads.  The session reads as compacting meanwhile, and the model reads
both messages after the summary."
  (harness-compaction-test-with
    (setq harness-compaction-test--requests nil)
    (let* ((harness-provider-demo--delay 0.15)
           (harness-provider-demo-script-override #'harness-compaction-test--answer)
           (id (harness-compaction-test-session))
           (_ (harness-call 'session/usage-add id '(:context 7500)))
           (turn (harness-call 'agent/prompt id "next question")))
      (harness-test-wait (lambda () (harness-compaction-busy-p id)) 10 "the automatic compaction")
      (should (eq turn (harness-call 'agent/prompt id "one more thing")))
      ;; Both wait: this compaction showed nothing, so the turn does now.
      (should (eq 'running (plist-get (harness-call 'session/get id) :status)))
      (should (equal '(:phase compacting :detail "2 messages wait")
                     (harness-plist-remove (harness-call 'agent/activity id) :since)))
      (should-not (harness-compaction-test-steering id))
      (should (eq 'end-turn (plist-get (harness-test-await turn 20) :stop-reason)))
      (should (equal '(user assistant hint compaction hint user user assistant)
                     (harness-compaction-test-kinds id)))
      (should (equal '("please refactor the parser" "next question" "one more thing")
                     (harness-compaction-test-user-texts id)))
      (should-not (harness-compaction-test-steering id))
      (should (= 1 (length harness-compaction-test--requests)))
      (let ((text (harness-compaction-test-request-text (car harness-compaction-test--requests))))
        (should (string-match-p "\\`Summary of the conversation so far:" text))
        (should (string-match-p "next question\none more thing\\'" text))))))

(defun harness-compaction-test-define-plain ()
  "Define `plain', a provider that calls a tool once, then answers.
A turn's first request is answered with a call of list_dir, its next
ones with text; a summary comes slowly, so that a message can be sent
while it is written.  The turns' requests are kept in
`harness-compaction-test--requests'."
  (harness-define-tool "list_dir" :label "List" :description "list" :kind 'read
                       :handler (lambda (input _ctx) (format "listing of %s" (plist-get input :path))))
  (harness-define-provider
   'plain :label "Plain"
   :models (lambda () (harness-resolved (list (list :name "m" :label "Plain M" :context-window 8000))))
   :complete (lambda (request)
               (let* ((on-event (plist-get request :on-event))
                      (summary (harness-compaction-test--summary-p request))
                      (_ (unless summary (push request harness-compaction-test--requests)))
                      (events (cond (summary '((:type text :delta "SUMMARY TEXT") (:type done :stop-reason end-turn)))
                                    ((= 1 (length harness-compaction-test--requests))
                                     '((:type tool-call :id "t1" :name "list_dir" :input (:path "/a"))
                                       (:type done :stop-reason tool-use)))
                                    (t '((:type text :delta "Done.") (:type done :stop-reason end-turn))))))
                 (run-at-time (if summary 0.4 0.01) nil
                              (lambda () (dolist (ev events) (funcall on-event ev))))
                 (list :cancel #'ignore)))))

(ert-deftest harness-compaction-a-boundary-that-compacts-holds-the-messages-for-the-next-step ()
  "A compaction queued for a turn runs at its next step boundary.  A
message sent while it runs waits there, and is recorded right after it:
the step that follows reads the summary and the message, and answers."
  (harness-compaction-test-with
    (harness-compaction-test-define-plain)
    (setq harness-compaction-test--requests nil)
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                        :model "plain:m" :context-window 8000)
                          :id))
           (turn (harness-call 'agent/prompt id "go")))
      (harness-test-wait (lambda () (harness-call 'agent/running id)))
      (should (plist-get (harness-await (harness-call 'compaction/compact id '(:kind "summary" :queue t))) :queued))
      (harness-test-wait (lambda () (harness-compaction-busy-p id)) 10 "the compaction at the boundary")
      (should (eq turn (harness-call 'agent/prompt id "and also this")))
      (should (eq 'running (plist-get (harness-call 'session/get id) :status)))
      ;; Whatever the step before left the line saying, the turn compacts.
      (should (equal '(:phase compacting :detail "1 message waits: “and also this”")
                     (harness-plist-remove (harness-call 'agent/activity id) :since)))
      (should-not (member "and also this" (harness-compaction-test-user-texts id)))
      (should (eq 'end-turn (plist-get (harness-test-await turn 20) :stop-reason)))
      (should (equal '(user hint tool-call tool-result hint compaction hint user assistant)
                     (harness-compaction-test-kinds id)))
      (should-not (harness-compaction-test-steering id))
      ;; The first request is the turn's, the second the step after the compaction.
      (should (= 2 (length harness-compaction-test--requests)))
      (let ((text (harness-compaction-test-request-text (car harness-compaction-test--requests))))
        (should (string-match-p "\\`Summary of the conversation so far:" text))
        (should (string-match-p "and also this\\'" text))
        (should-not (string-match-p "listing of" text))))))

(ert-deftest harness-compaction-carries-a-steering-message-over-delivered ()
  "A message that steered a turn and still waited for its step when a
compaction began is carried over after it, and says it was delivered: the
model reads it with the conversation that starts there, and a chat must
not show it queued for good."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-call 'session/append id '(:kind user :content "carry me" :meta (:steering t)))
      (let* ((node (harness-await (harness-call 'compaction/compact id '(:kind "transcript"))))
             (copy (car (last (harness-call 'session/nodes id)))))
        (should (equal "carry me" (plist-get copy :content)))
        (should (plist-get (plist-get copy :meta) :steering))
        (should (equal (plist-get node :id) (plist-get (plist-get copy :meta) :delivered-after)))
        (should (plist-get (plist-get copy :meta) :carried-from))))))


;;;; Reverting a compaction

(defun harness-compaction-test-compacted-session ()
  "Create a session of one answered exchange, compacted; return its id.
The summary says SUMMARY TEXT."
  (let ((id (harness-compaction-test-session))
        (harness-provider-demo-script-override harness-compaction-test-script))
    (harness-await (harness-call 'compaction/compact id))
    id))

(defun harness-compaction-test-message-texts (id)
  "Return the text of each message the model of session ID is sent, oldest first."
  (mapcar (lambda (m)
            (mapconcat (lambda (b) (or (plist-get b :text) "")) (plist-get m :content) "\n"))
          (harness-call 'session/messages id)))

(defun harness-compaction-test-turn (id text)
  "Send TEXT to session ID, wait for the demo model to answer; return its request."
  (setq harness-compaction-test--requests nil)
  (let ((harness-provider-demo-script-override #'harness-compaction-test--answer))
    (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt id text) 20)
                                     :stop-reason))))
  (car harness-compaction-test--requests))

(defun harness-compaction-test-refusal (thunk)
  "Call THUNK, which must signal a `harness-error'; return its message."
  (condition-case err
      (progn (funcall thunk) (ert-fail "no error was signalled"))
    (harness-error (format "%s" (cadr err)))))

(ert-deftest harness-compaction-revert-gives-the-model-the-conversation-before-it ()
  "Reverting a compaction sends the model the conversation it stood for.
The next request is the whole of it, then the new message -- not the
summary -- and the node stays where it is, marked reverted."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-compacted-session))
           (node (car (harness-compaction-test-compactions id))))
      (should (string-prefix-p "Summary of the conversation so far:"
                               (car (harness-compaction-test-message-texts id))))
      (let ((answer (harness-call 'compaction/revert id)))
        (should (eq 'reverted (plist-get answer :state)))
        (should (eq t (plist-get answer :changed)))
        (should (equal (plist-get node :id) (plist-get answer :node-id)))
        (should (string-prefix-p "Reverted the compaction" (plist-get answer :message))))
      ;; Nothing was deleted: the node stays, marked.
      (should (equal (list (plist-get node :id))
                     (mapcar (lambda (n) (plist-get n :id)) (harness-compaction-test-compactions id))))
      (should (harness-node-compaction-reverted-p (car (harness-compaction-test-compactions id))))
      (should (equal '("please refactor the parser" "Done: parser.el rewritten")
                     (harness-compaction-test-message-texts id)))
      ;; The transcript says so, where it happened.
      (should (string-prefix-p "Reverted the compaction" (car (last (harness-compaction-test-hints id)))))
      ;; The next request is the conversation before the compaction, whole.
      (let ((text (harness-compaction-test-request-text (harness-compaction-test-turn id "and the lexer?"))))
        (should (string-match-p "please refactor the parser\nDone: parser.el rewritten\nand the lexer\\?\\'" text))
        (should-not (string-match-p "Summary of the conversation so far" text))))))

(ert-deftest harness-compaction-restore-sends-the-summary-again ()
  "Going back to the compaction sends the summary in place of the conversation.
What was said meanwhile follows it, as it follows the conversation
reverted: it is after the compaction either way."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-compacted-session)))
      (harness-call 'compaction/revert id)
      (harness-compaction-test-turn id "and the lexer?")
      (let ((answer (harness-call 'compaction/restore id)))
        (should (eq 'compacted (plist-get answer :state)))
        (should (eq t (plist-get answer :changed)))
        (should (string-prefix-p "Back to the compaction" (plist-get answer :message))))
      (should-not (harness-node-compaction-reverted-p (car (harness-compaction-test-compactions id))))
      (should (= 2 (length (harness-call 'session/messages id))))
      (let* ((request (harness-compaction-test-turn id "and the parser?"))
             (messages (plist-get request :messages)))
        ;; The summary and the first question after it, the answer, the new question.
        (should (equal '(user assistant user) (mapcar (lambda (m) (plist-get m :role)) messages)))
        (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY TEXT"
                                 (plist-get (car (plist-get (car messages) :content)) :text)))
        (should (equal "and the lexer?" (plist-get (cadr (plist-get (car messages) :content)) :text)))
        (should (string-match-p "Done\\.\nand the parser\\?\\'" (harness-compaction-test-request-text request)))))))

(ert-deftest harness-compaction-revert-and-restore-toggle-as-often-as-asked ()
  "Undo and redo, again and again: each move puts the model's context back as it was.
Asking for what is the case already changes nothing, so a button
clicked twice does not undo itself."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-compacted-session))
           (compacted (harness-compaction-test-message-texts id))
           (reverted '("please refactor the parser" "Done: parser.el rewritten")))
      (dotimes (_ 4)
        (should (eq 'reverted (plist-get (harness-call 'compaction/revert id) :state)))
        (should (equal reverted (harness-compaction-test-message-texts id)))
        (should (eq 'compacted (plist-get (harness-call 'compaction/restore id) :state)))
        (should (equal compacted (harness-compaction-test-message-texts id))))
      (let ((hints (length (harness-compaction-test-hints id))))
        ;; Already as asked: nothing is done, nothing is said.
        (let ((answer (harness-call 'compaction/restore id)))
          (should (eq 'compacted (plist-get answer :state)))
          (should (eq :false (plist-get answer :changed))))
        (harness-call 'compaction/revert id)
        (setq hints (length (harness-compaction-test-hints id)))
        (let ((answer (harness-call 'compaction/revert id)))
          (should (eq 'reverted (plist-get answer :state)))
          (should (eq :false (plist-get answer :changed))))
        (should (= hints (length (harness-compaction-test-hints id))))
        (should (equal reverted (harness-compaction-test-message-texts id)))))))

(ert-deftest harness-compaction-revert-keeps-what-was-said-after-the-compaction ()
  "The conversation the model gets back is followed by what came after the compaction.
A message the compaction carried over after itself is the original
again, not both."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-call 'session/append id '(:kind user :content "carry me"))
      (let ((harness-provider-demo-script-override harness-compaction-test-script))
        (harness-await (harness-call 'compaction/compact id)))
      ;; The compaction carried the unanswered message over: two of it are recorded.
      (should (= 2 (cl-count "carry me" (harness-compaction-test-user-texts id) :test #'equal)))
      (harness-compaction-test-turn id "and then?")
      (harness-call 'compaction/revert id)
      (should (equal '("please refactor the parser" "Done: parser.el rewritten"
                       "carry me\nand then?" "Done.")
                     (harness-compaction-test-message-texts id)))
      (harness-call 'compaction/restore id)
      (let ((texts (harness-compaction-test-message-texts id)))
        (should (= 2 (length texts)))
        (should (string-prefix-p "Summary of the conversation so far:" (car texts)))
        (should (string-suffix-p "carry me\nand then?" (car texts)))
        (should (equal "Done." (cadr texts)))))))

(ert-deftest harness-compaction-revert-waits-for-a-turn-or-a-compaction ()
  "Nothing is reverted or restored while a turn runs, a compaction runs or one is queued.
The same waits a message has: the turn writes into the conversation
whose context this would change.  A refusal changes nothing; once the
wait is over the same call works."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-compacted-session))
           (reverted-p (lambda () (harness-node-compaction-reverted-p
                                   (car (harness-compaction-test-compactions id)))))
           (hints (length (harness-compaction-test-hints id))))
      (dolist (case (list
                     (list "turn" "is running a turn"
                           (lambda () (harness-compaction-test--running id))
                           (lambda () (remhash id harness-agent--turns)))
                     (list "compaction" "compaction is under way"
                           (lambda () (puthash id (harness-make-promise) harness-compaction--running))
                           (lambda () (remhash id harness-compaction--running)))
                     (list "queue" "compaction is queued"
                           (lambda () (puthash id (list :opts nil) harness-compaction--pending))
                           (lambda () (remhash id harness-compaction--pending)))))
        (funcall (nth 2 case))
        (dolist (method '(compaction/revert compaction/restore))
          (should (string-match-p (nth 1 case)
                                  (harness-compaction-test-refusal (lambda () (harness-call method id))))))
        (should-not (funcall reverted-p))
        (should (= hints (length (harness-compaction-test-hints id))))
        (funcall (nth 3 case)))
      (should (eq 'reverted (plist-get (harness-call 'compaction/revert id) :state)))
      ;; Restoring waits as well.
      (harness-compaction-test--running id)
      (should (string-match-p "running a turn"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/restore id)))))
      (should (funcall reverted-p))
      (remhash id harness-agent--turns)
      (should (eq 'compacted (plist-get (harness-call 'compaction/restore id) :state))))))

(ert-deftest harness-compaction-revert-says-no-to-what-it-cannot-do ()
  "A conversation with no compaction, another node than the latest, a handoff's summary."
  (harness-compaction-test-with
    (let ((fresh (harness-compaction-test-session)))
      (should (string-match-p "no compaction to revert"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/revert fresh)))))
      (should (string-match-p "no compaction to restore"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/restore fresh)))))
      (should (string-match-p "No session"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/revert "nope"))))))
    (let* ((id (harness-compaction-test-compacted-session))
           (node (car (harness-compaction-test-compactions id))))
      (should (string-match-p "Only the latest compaction can be reverted: n-nope is an older one"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/revert id "n-nope")))))
      ;; The node itself may be named.
      (should (eq 'reverted (plist-get (harness-call 'compaction/revert id (plist-get node :id)) :state)))
      (should (string-match-p "restored: n-nope"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/restore id "n-nope")))))
      (should (eq 'compacted (plist-get (harness-call 'compaction/restore id (plist-get node :id)) :state))))
    ;; A compaction made to hand the conversation over to another model.
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script))
      (harness-await (harness-call 'compaction/compact id
                                   (list :meta '(:handoff (:mode "compact" :from "demo:scripted" :to "other:model")))))
      (should (string-match-p "hand the conversation over to another model cannot be reverted"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/revert id)))))
      (should-not (harness-node-compaction-reverted-p (car (harness-compaction-test-compactions id)))))))

(ert-deftest harness-compaction-revert-survives-a-restart ()
  "A reverted compaction is still reverted when the session is loaded again, and restored too."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-compacted-session))
           (compacted (harness-compaction-test-message-texts id))
           (reverted '("please refactor the parser" "Done: parser.el rewritten"))
           (restart (lambda ()
                      (harness-session-flush)
                      (clrhash harness-sessions)
                      (harness-session--load-all)
                      (harness-call 'session/resume id))))
      (harness-call 'compaction/revert id)
      (funcall restart)
      (should (harness-node-compaction-reverted-p (car (harness-compaction-test-compactions id))))
      (should (equal reverted (harness-compaction-test-message-texts id)))
      (harness-call 'compaction/restore id)
      (funcall restart)
      (should-not (harness-node-compaction-reverted-p (car (harness-compaction-test-compactions id))))
      (should (equal compacted (harness-compaction-test-message-texts id)))
      ;; And it can be flipped again after the restart.
      (should (eq 'reverted (plist-get (harness-call 'compaction/revert id) :state)))
      (should (equal reverted (harness-compaction-test-message-texts id))))))

(ert-deftest harness-compaction-revert-starts-the-cache-over ()
  "Reverting or restoring sends the model another conversation than the last request's.
Its prompt cache is gone, as a compaction leaves it, until the next
request stamps a new one, and the context the session reports is an
estimate of the one it has now."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-compacted-session))
           (stamp (lambda ()
                    (harness-call 'session/usage-add id '(:input 10 :output 10 :cache-read 400 :context 420
                                                           :cache-at 1000.0))))
           (usage (lambda () (plist-get (harness-call 'session/get id) :usage))))
      (dolist (way '(compaction/revert compaction/restore))
        (funcall stamp)
        (should (plist-get (harness-call 'session/get id) :cache))
        (harness-call way id)
        (should-not (plist-get (harness-call 'session/get id) :cache))
        (should-not (plist-member (funcall usage) :cache-at))
        (should (plist-get (funcall usage) :cache-pending))
        ;; What the model is sent now: the conversation before the compaction is
        ;; at least as big as the model said it was when it was compacted.
        (let ((live (harness-compaction--live-tokens id))
              (was (plist-get (plist-get (car (harness-compaction-test-compactions id)) :meta) :input-tokens)))
          (should (= (if (eq way 'compaction/revert) (max live was) live)
                     (plist-get (funcall usage) :context))))
        (should (= 0 (plist-get (funcall usage) :last-output)))))))

(ert-deftest harness-compaction-revert-counts-what-the-model-said-it-compacted ()
  "The context a revert reports is never under what the compaction replaced, as the model read it.
The estimate of the nodes leaves out what it cannot see -- a long system prompt, a picture --
so the size the model reported when it compacted the conversation is the floor."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override
            '((:type text :delta "SUMMARY")
              (:type usage :input 150000 :output 5 :context 150000)
              (:type done :stop-reason end-turn))))
      (harness-await (harness-call 'compaction/compact id))
      (let ((answer (harness-call 'compaction/revert id)))
        (should (= 150000 (plist-get answer :context)))
        (should (= 150000 (plist-get (plist-get (harness-call 'session/get id) :usage) :context)))
        (should (string-match-p "about 150k tokens" (plist-get answer :message))))
      ;; Restored, it is the summary's size again.
      (let ((answer (harness-call 'compaction/restore id)))
        (should (< (plist-get answer :context) 1000))))))

(ert-deftest harness-compaction-revert-starts-a-hosted-loop-over ()
  "A provider that keeps the conversation itself starts a new one from the other context."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-compacted-session))
          (changed nil))
      (harness-on 'session/provider-state-changed (lambda (sid state) (push (list sid state) changed)))
      (dolist (way '(compaction/revert compaction/restore))
        (harness-call 'session/set-provider-state id '(:conv "c9"))
        (setq changed nil)
        (harness-call way id)
        (should-not (plist-get (harness-call 'session/get id) :provider-state))
        (should (equal (list (list id nil)) changed))))))

(defun harness-compaction-test-long-exchange (id chars)
  "Append to session ID a user message and a CHARS characters long answer."
  (harness-call 'session/append id '(:kind user :content "write it all out"))
  (harness-call 'session/append id (list :kind 'assistant :content (make-string chars ?x))))

(ert-deftest harness-compaction-revert-is-not-compacted-again-before-the-next-turn ()
  "A conversation over the limit that the user asked for is sent once as it is.
Its window is 8000 tokens and the limit 7000: the reverted conversation
is some 7500.  The automatic compaction before the next turn would make
the compaction again before the model saw any of it, so it lets that
turn through; the one after it compacts as it always did."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-compaction-test-long-exchange id 30000)
      (let ((harness-provider-demo-script-override harness-compaction-test-script))
        (harness-await (harness-call 'compaction/compact id)))
      (let ((answer (harness-call 'compaction/revert id)))
        (should (< 7000 (plist-get answer :context) 8000))
        (should-not (string-match-p "compacts it again" (plist-get answer :message))))
      (should (gethash id harness-compaction--revert-hold))
      (should (harness-compaction-needed-p (harness-call 'session/get id)))
      (let ((request (harness-compaction-test-turn id "and now?")))
        (should (= 1 (harness-compaction-test-compaction-count id)))
        (should (string-match-p "xxxxxxxx" (harness-compaction-test-request-text request))))
      (should-not (gethash id harness-compaction--revert-hold))
      ;; The next turn: nothing holds the compaction back.
      (harness-compaction-test-turn id "and then?")
      (should (= 2 (harness-compaction-test-compaction-count id))))))

(ert-deftest harness-compaction-revert-over-the-window-is-compacted-at-once ()
  "A conversation that does not fit the window is not let through: the reverted
conversation says so, and the next message compacts it again."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-compaction-test-long-exchange id 40000)
      (let ((harness-provider-demo-script-override harness-compaction-test-script))
        (harness-await (harness-call 'compaction/compact id)))
      (let ((answer (harness-call 'compaction/revert id)))
        (should (< 8000 (plist-get answer :context)))
        (should (string-match-p "more than its 8k window, so the next message compacts it again"
                                (plist-get answer :message))))
      (should-not (gethash id harness-compaction--revert-hold))
      (harness-compaction-test-turn id "and now?")
      (should (= 2 (harness-compaction-test-compaction-count id))))))

(ert-deftest harness-compaction-restore-and-a-new-compaction-forget-the-hold ()
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-compaction-test-long-exchange id 30000)
      (let ((harness-provider-demo-script-override harness-compaction-test-script))
        (harness-await (harness-call 'compaction/compact id))
        (harness-call 'compaction/revert id)
        (should (gethash id harness-compaction--revert-hold))
        (harness-call 'compaction/restore id)
        (should-not (gethash id harness-compaction--revert-hold))
        (harness-call 'compaction/revert id)
        (should (gethash id harness-compaction--revert-hold))
        (harness-await (harness-call 'compaction/compact id))
        (should-not (gethash id harness-compaction--revert-hold))
        (harness-call 'compaction/revert id)
        (harness-call 'session/delete id)
        (should-not (gethash id harness-compaction--revert-hold))))))

(ert-deftest harness-compaction-only-the-latest-compaction-is-reverted ()
  "An older compaction keeps the state it had, so undoing the latest goes back exactly.
Reverting the second compaction leaves the conversation as the first
made it; reverting the first before the second was made leaves the
whole conversation after the second is reverted too."
  (harness-compaction-test-with
    (let* ((harness-provider-demo-script-override harness-compaction-test-script)
           (id (harness-compaction-test-session)))
      (harness-await (harness-call 'compaction/compact id))
      (harness-call 'session/append id '(:kind user :content "second task"))
      (harness-call 'session/append id '(:kind assistant :content "second done"))
      (let ((first (car (harness-compaction-test-compactions id))))
        (harness-await (harness-call 'compaction/compact id))
        (let ((second (cadr (harness-compaction-test-compactions id))))
          ;; The first is no longer the latest.
          (should (string-match-p "Only the latest compaction can be reverted"
                                  (harness-compaction-test-refusal
                                   (lambda () (harness-call 'compaction/revert id (plist-get first :id))))))
          (should (equal (plist-get second :id)
                         (plist-get (harness-call 'compaction/revert id) :node-id)))
          ;; The first compaction is where the conversation starts again.
          (let ((texts (harness-compaction-test-message-texts id)))
            (should (string-prefix-p "Summary of the conversation so far:" (car texts)))
            (should (string-suffix-p "Done: parser.el rewritten\nsecond task" (car texts)))
            (should (equal "second done" (cadr texts))))
          (should-not (harness-node-compaction-reverted-p (car (harness-compaction-test-compactions id))))
          (harness-call 'compaction/restore id)
          (should (string-prefix-p "Summary of the conversation so far:"
                                   (car (harness-compaction-test-message-texts id))))))
      ;; Reverted first, while it was the latest; then a second one is made.
      (let ((id (harness-compaction-test-compacted-session)))
        (harness-call 'compaction/revert id)
        (harness-call 'session/append id '(:kind user :content "second task"))
        (harness-call 'session/append id '(:kind assistant :content "second done"))
        (harness-await (harness-call 'compaction/compact id))
        (should (= 1 (length (harness-call 'session/messages id))))
        (harness-call 'compaction/revert id)
        (should (equal '("please refactor the parser" "Done: parser.el rewritten" "second task" "second done")
                       (harness-compaction-test-message-texts id)))
        (harness-call 'compaction/restore id)
        (should (= 1 (length (harness-call 'session/messages id))))))))

(ert-deftest harness-compaction-a-fork-keeps-the-state-and-flips-it-on-its-own ()
  "A fork copies the nodes, the mark on a reverted compaction with them, and
flipping it in the fork or in the session leaves the other as it is."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-compacted-session))
           (node (car (harness-compaction-test-compactions id))))
      (harness-call 'compaction/revert id)
      (let* ((fork (plist-get (harness-await (harness-call 'session/fork id)) :id))
             (in-fork (lambda () (car (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'compaction))
                                                        (harness-call 'session/nodes fork))))))
        (should (equal (plist-get node :id) (plist-get (funcall in-fork) :id)))
        (should (harness-node-compaction-reverted-p (funcall in-fork)))
        (should (equal '("please refactor the parser" "Done: parser.el rewritten")
                       (harness-compaction-test-message-texts fork)))
        (harness-call 'compaction/restore fork)
        (should-not (harness-node-compaction-reverted-p (funcall in-fork)))
        (should (harness-node-compaction-reverted-p (car (harness-compaction-test-compactions id))))
        (should (= 2 (length (harness-call 'session/messages id))))
        (should (= 1 (length (harness-call 'session/messages fork))))))))

(ert-deftest harness-compaction-revert-a-compaction-made-in-the-middle-of-a-turn ()
  "A compaction in the middle of a turn can be reverted once the turn is over.
The tool call and its result are in the conversation that comes back,
paired, and the model's last answer follows them."
  (harness-compaction-test-with
    (harness-compaction-test-define-echo)
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override (harness-compaction-test-tool-turn '(7500 600))))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (eq t (plist-get (plist-get (car (harness-compaction-test-compactions id)) :meta) :mid-turn)))
      ;; The summary, with the note to carry on, and the answer that followed it.
      (should (= 2 (length (harness-call 'session/messages id))))
      (harness-call 'compaction/revert id)
      (let ((messages (harness-call 'session/messages id)))
        (should (equal '(user assistant user assistant user assistant)
                       (mapcar (lambda (m) (plist-get m :role)) messages)))
        (should (equal '("tool_result")
                       (mapcar (lambda (b) (plist-get b :type)) (plist-get (nth 4 messages) :content))))
        (should (equal '("text" "tool_use")
                       (mapcar (lambda (b) (plist-get b :type)) (plist-get (nth 3 messages) :content))))
        (should (equal (plist-get (cadr (plist-get (nth 3 messages) :content)) :id)
                       (plist-get (car (plist-get (nth 4 messages) :content)) :tool_use_id)))
        (should (equal "All done." (plist-get (car (plist-get (nth 5 messages) :content)) :text))))
      (harness-call 'compaction/restore id)
      (let ((messages (harness-call 'session/messages id)))
        (should (equal '(user assistant) (mapcar (lambda (m) (plist-get m :role)) messages)))
        (should (string-suffix-p harness-compaction--mid-turn-note
                                 (plist-get (car (plist-get (car messages) :content)) :text)))))))

(ert-deftest harness-compaction-truncate-keeps-what-it-cut-on-the-path ()
  "The nodes a truncation cuts away stay on the session's path, before its node.
They are what session_history reads and what a revert gives the model
back; the kept nodes follow the node, as before."
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-long-session))
           (before (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id)))
           (harness-compaction--truncate-keep 0.1)
           (node (harness-await (harness-call 'compaction/compact id '(:kind "truncate"))))
           (meta (plist-get node :meta))
           (path (mapcar (lambda (n) (plist-get n :id)) (harness-call 'session/nodes id)))
           (at (cl-position (plist-get node :id) path :test #'equal))
           (dropped (plist-get meta :truncate-dropped)))
      ;; The cut nodes, then the compaction, its hint, and the kept nodes: all 20 are there.
      (should (equal (cl-subseq before 0 dropped) (cl-subseq path 0 at)))
      (should (equal (nth (1- dropped) before) (plist-get meta :truncate-after)))
      (should (equal (cl-subseq before dropped) (nthcdr (+ at 2) path)))
      (should (= (+ 20 2) (length path)))
      ;; The head is still the newest node.
      (should (equal (car (last before)) (plist-get (harness-call 'session/get id) :head)))
      (let ((reverted-count (length (harness-call 'session/messages id))))
        (should (< reverted-count 20))
        (harness-call 'compaction/revert id)
        (should (= 20 (length (harness-call 'session/messages id))))
        (should (string-prefix-p "message 0 " (car (harness-compaction-test-message-texts id))))
        (harness-call 'compaction/restore id)
        (should (= reverted-count (length (harness-call 'session/messages id))))))))

(ert-deftest harness-compaction-revert-refuses-a-cut-from-before-it-could-be-undone ()
  "A truncation of an earlier harness lost the nodes it cut off the path: there is nothing to go back to."
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-call 'session/append id (list :kind 'compaction :content "cut"
                                            :meta '(:compaction "truncate" :truncate-dropped 3)))
      (should (string-match-p "cannot be reverted"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/revert id))))))
    ;; Nor one that opens the path: nothing before it.
    (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id)))
      (harness-call 'session/append id (list :kind 'compaction :content "first of all"
                                            :meta '(:compaction "summary")))
      (should (string-match-p "nothing before this compaction"
                              (harness-compaction-test-refusal (lambda () (harness-call 'compaction/revert id))))))))

(provide 'harness-compaction-test)
;;; harness-compaction-test.el ends here
