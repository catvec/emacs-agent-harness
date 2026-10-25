;;; harness-emacs-endpoint-test.el --- Tools run in the harness; an Emacs is lent to it  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every tool runs in the harness.  The tools about the user's Emacs
;; reach the Emacs a client lent to the harness (advertised in
;; `initialize'), exactly one of them, and never a client that lends
;; none, such as a phone.  These tests connect in-process clients of
;; both kinds and check who is asked, what they answer, and what the
;; tools make of it.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-model)
(defvar harness-tools-max-output-chars)
(defvar harness-emacs-endpoint--methods)
(declare-function harness-tools-reason "harness-tools" (err))
(declare-function harness-acp-add-client "harness-acp")
(declare-function harness-acp-client-receive "harness-acp")
(declare-function harness-acp-drop-client "harness-acp")
(declare-function harness-acp-close "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp-respond-error "harness-acp")
(declare-function harness-emacs-endpoint-handle "harness-emacs-endpoint")

(defun harness-emacs-endpoint-test--allow (_decision next &rest _)
  "Permissive permission filter for the tests."
  (funcall next (list :behavior 'allow)))

(defun harness-emacs-endpoint-test--setup ()
  "Load the tool modules and acp, allow every call, and drop every client.
Each test then connects the clients it is about, and only those."
  (setq harness-acp--server-enabled nil)
  (harness-test-load-module 'acp)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-emacs)
  (harness-test-load-module 'tools-shell)
  (require 'harness-emacs-endpoint)
  (harness-add-filter 'permission/decide #'harness-emacs-endpoint-test--allow 10)
  (dolist (client (copy-sequence harness-acp--clients))
    (harness-acp-drop-client client)))

(defun harness-emacs-endpoint-test--label (method params)
  "Return what a test watching METHOD with PARAMS should see.
An MCP message is labelled with the tool it calls, so a test can tell
which tool an Emacs was asked for."
  (if (equal method harness-emacs-endpoint-mcp-method)
      (let* ((message (plist-get params :message))
             (name (plist-get (plist-get message :params) :name)))
        (format "%s/%s%s" method (plist-get message :method)
                (if name (concat "/" name) "")))
    method))

(defun harness-emacs-endpoint-test--connect (lend)
  "Connect an in-process client; it lends this Emacs when LEND.
Return (CONNECTION . SEEN): SEEN is a cons whose car lists the methods
the harness sent the client, newest first.  A client that lends no
Emacs (a phone, say) answers no request; one that does answers the
harness's requests for its Emacs."
  (let ((conn (harness-acp-connect nil))
        (seen (list nil)))
    (harness-acp-set-handler
     conn
     (lambda (method params respond)
       (push (harness-emacs-endpoint-test--label method params) (car seen))
       (unless (and lend (harness-emacs-endpoint-answer method params respond))
         (when respond (harness-acp-respond-error respond -32601 (format "unhandled %s" method))))))
    (harness-test-await (harness-acp-initialize conn (and lend (harness-emacs-endpoint-client-capabilities))))
    (cons conn seen)))

(defun harness-emacs-endpoint-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-test-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input)) 20))

(defun harness-emacs-endpoint-test--asked-p (seen)
  "Non-nil when SEEN, from `harness-emacs-endpoint-test--connect', got a tool's request."
  (cl-some (lambda (method) (or (string-prefix-p "_harness/emacs/" method)
                                (equal method "_harness/client/tool")))
           (car seen)))

;;;; Who is asked

(ert-deftest harness-emacs-endpoint-a-client-that-lends-no-emacs-is-never-asked ()
  "With only a phone-like client, the harness has no Emacs to ask: the
tools about the user's Emacs say so at once, the elisp tool evaluates
in the background as always, and the client gets no tool request."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((phone (harness-emacs-endpoint-test--connect nil)))
      (unwind-protect
          (progn
            (should-not (harness-call 'emacs/attached))
            (dolist (call '(("emacs_buffers") ("emacs_buffer" :name "*scratch*")
                            ("emacs_describe" :symbol "car") ("emacs_messages")))
              (let ((r (apply #'harness-emacs-endpoint-test--call call)))
                (should (plist-get r :is-error))
                (should (string-prefix-p "No Emacs is attached to the harness" (plist-get r :content)))
                (should (string-search "elisp tool" (plist-get r :content)))))
            ;; The debugging tools point elsewhere: a definition can be
            ;; grepped for; a trace has nothing to stand in for it.
            (dolist (call '(("emacs_find_definition" :symbol "car" "grep")
                            ("emacs_trace" :symbol "car" nil)))
              (let ((r (harness-emacs-endpoint-test--call (nth 0 call) (nth 1 call) (nth 2 call))))
                (should (plist-get r :is-error))
                (should (string-prefix-p "No Emacs is attached to the harness" (plist-get r :content)))
                (if (nth 3 call)
                    (should (string-search (nth 3 call) (plist-get r :content)))
                  (should-not (string-search "elisp tool" (plist-get r :content))))))
            (let ((r (harness-emacs-endpoint-test--call "elisp" :code "(+ 1 2)")))
              (should (equal "=> 3" (plist-get r :content)))
              (should (equal "background" (plist-get (plist-get r :meta) :emacs))))
            ;; No Emacs to ask, and the elisp tool would not evaluate
            ;; in one even if there were: a call that asks is refused
            ;; for that reason first.
            (let ((r (harness-emacs-endpoint-test--call "elisp" :code "(+ 1 2)" :emacs "user")))
              (should (plist-get r :is-error))
              (should (string-search "never evaluates in the user's Emacs" (plist-get r :content)))
              (should (string-search "emacs_* tools" (plist-get r :content))))
            (should-not (harness-emacs-endpoint-test--asked-p (cdr phone))))
        (harness-acp-close (car phone))))))

(ert-deftest harness-emacs-endpoint-the-lending-emacs-answers-beside-a-phone ()
  "A phone and an Emacs connected at once: the Emacs is asked, the phone never."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let* ((emacs (harness-emacs-endpoint-test--connect t))
           (phone (harness-emacs-endpoint-test--connect nil))
           (buffer (generate-new-buffer "harness-endpoint-lent")))
      (unwind-protect
          (progn
            ;; The phone spoke last, yet it lends no Emacs.
            (harness-test-await (harness-acp-request (car phone) "_harness/harness/version" nil))
            (let ((attached (harness-call 'emacs/attached)))
              (should (= 1 (length attached)))
              (should (equal (emacs-pid) (plist-get (car attached) :pid)))
              (should (equal emacs-version (plist-get (car attached) :version))))
            (should (string-search "harness-endpoint-lent"
                                   (plist-get (harness-emacs-endpoint-test--call "emacs_buffers") :content)))
            (should (member "_harness/emacs/mcp/tools/call/buffers" (car (cdr emacs))))
            (should-not (harness-emacs-endpoint-test--asked-p (cdr phone))))
        (kill-buffer buffer)
        (harness-acp-close (car phone))
        (harness-acp-close (car emacs))))))

(ert-deftest harness-emacs-endpoint-exactly-one-emacs-answers ()
  "Two Emacsen lent at once: a request goes to one of them, the most
recently active, never to both.  A broadcast would, for instance, open
the same file in every connected Emacs."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((a (harness-emacs-endpoint-test--connect t))
          (b (harness-emacs-endpoint-test--connect t)))
      (unwind-protect
          (progn
            ;; A is where the user is now.
            (harness-test-await (harness-acp-request (car a) "_harness/harness/version" nil))
            (let ((r (harness-emacs-endpoint-test--call "emacs_windows")))
              (should-not (plist-get r :is-error))
              (should (string-search "FRAME" (plist-get r :content))))
            (should (member "_harness/emacs/mcp/tools/call/windows" (car (cdr a))))
            (should-not (member "_harness/emacs/mcp/tools/call/windows" (car (cdr b))))
            ;; Then B: the request follows the user, still to one Emacs.
            (harness-test-await (harness-acp-request (car b) "_harness/harness/version" nil))
            (harness-emacs-endpoint-test--call "emacs_windows")
            (should (member "_harness/emacs/mcp/tools/call/windows" (car (cdr b))))
            (should (= 1 (cl-count "_harness/emacs/mcp/tools/call/windows" (car (cdr a)) :test #'equal))))
        (harness-acp-close (car a))
        (harness-acp-close (car b))))))

(ert-deftest harness-emacs-endpoint-an-unauthenticated-client-lends-nothing ()
  "A client that has not authenticated may advertise an Emacs, but is
not one the harness asks: it could answer for the user's Emacs, and be
shown its buffers, with what it likes."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let* ((sent nil)
           (client (harness-acp-add-client 'test :writer (lambda (_client text) (push text sent))
                                           :remote '(:address "192.0.2.7"))))
      (unwind-protect
          (progn
            (harness-acp-client-receive
             client (harness-json-encode-text
                     (list :jsonrpc "2.0" :id 1 :method "initialize"
                           :params (list :protocolVersion 1
                                         :clientCapabilities (harness-emacs-endpoint-client-capabilities)))))
            (harness-test-wait (lambda () sent) 5 "initialize answer")
            (should-not (harness-call 'emacs/attached))
            (let ((r (harness-emacs-endpoint-test--call "emacs_buffers")))
              (should (string-prefix-p "No Emacs is attached" (plist-get r :content))))
            (should-not (cl-some (lambda (text) (string-search "_harness/emacs/" text)) sent)))
        (harness-acp-drop-client client)))))

(ert-deftest harness-emacs-endpoint-an-emacs-that-leaves-fails-the-call ()
  "An Emacs that disconnects before it answers fails the call, saying so."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((conn (harness-acp-connect nil)))
      ;; The MCP handshake completes; the Emacs goes when a tool is called.
      (harness-acp-set-handler
       conn (lambda (method params respond)
              (if (and (equal method harness-emacs-endpoint-mcp-method)
                       (equal (plist-get (plist-get params :message) :method) "tools/call"))
                  ;; It leaves instead of answering the call.
                  (harness-acp-close conn)
                (harness-emacs-endpoint-answer method params respond))))
      (harness-test-await (harness-acp-initialize conn (harness-emacs-endpoint-client-capabilities)))
      (let ((r (harness-emacs-endpoint-test--call "emacs_buffers")))
        (should (plist-get r :is-error))
        (should (string-prefix-p "The user's Emacs disconnected before it answered." (plist-get r :content)))))))

(defvar harness-ui-connection)
(declare-function harness-ui--advertise "harness-ui")
(declare-function harness-ui--dispatch "harness-ui")

(ert-deftest harness-emacs-endpoint-the-ui-lends-its-emacs-again-after-a-reload ()
  "A connection the UI opened with older code lent nothing; after a
reload the UI advertises its Emacs on it, and its dispatch answers for
that Emacs."
  (harness-emacs-endpoint-test--setup)
  (require 'harness-ui)
  (harness-test-with-temp-state
    (let ((conn (harness-acp-connect nil))
          (buffer (generate-new-buffer "harness-endpoint-reloaded")))
      (unwind-protect
          (progn
            (harness-acp-set-handler conn #'harness-ui--dispatch)
            ;; Older code: ACP's own capabilities only.
            (harness-test-await (harness-acp-initialize conn))
            (should-not (harness-call 'emacs/attached))
            (let ((harness-ui-connection conn))
              (harness-ui--advertise)
              (harness-test-wait (lambda () (harness-call 'emacs/attached)) 5 "the UI's Emacs to be lent"))
            (should (equal (emacs-pid) (plist-get (car (harness-call 'emacs/attached)) :pid)))
            (should (string-search "harness-endpoint-reloaded"
                                   (plist-get (harness-emacs-endpoint-test--call "emacs_buffers") :content))))
        (kill-buffer buffer)
        (harness-acp-close conn)))))

;;;; What the Emacs answers

(ert-deftest harness-emacs-endpoint-answers-data-not-tool-results ()
  "The lent Emacs sends plain data; the tools word it in the harness."
  (require 'harness-emacs-endpoint)
  (let ((buffer (generate-new-buffer "harness-endpoint-data")))
    (unwind-protect
        (progn
          (with-current-buffer buffer (insert "alpha\nbeta\n") (set-buffer-modified-p nil))
          (let ((row (cl-find "harness-endpoint-data" (plist-get (harness-emacs-endpoint-handle "buffers" nil) :buffers)
                              :key (lambda (b) (plist-get b :name)) :test #'equal)))
            (should (equal "fundamental-mode" (plist-get row :mode)))
            (should (eq :false (plist-get row :modified)))
            (should (= 11 (plist-get row :size))))
          (should (equal '(:exists :false) (harness-emacs-endpoint-handle "buffer" '(:name "harness-endpoint-none"))))
          (let ((answer (harness-emacs-endpoint-handle "buffer" '(:name "harness-endpoint-data" :offset 2))))
            (should (equal '("beta") (plist-get answer :lines)))
            (should (= 2 (plist-get answer :first)))
            (should (= 2 (plist-get answer :total))))
          (let ((answer (harness-emacs-endpoint-handle "describe" '(:symbol "car"))))
            (should (eq t (plist-get answer :known)))
            (should (equal "primitive" (plist-get (plist-get answer :function) :kind)))
            (should (string-prefix-p "(car " (plist-get (plist-get answer :function) :signature)))
            (should-not (plist-get answer :variable)))
          (should (eq :false (plist-get (harness-emacs-endpoint-handle "describe" '(:symbol "harness-endpoint-nonesuch-q"))
                                        :known)))
          (let ((answer (harness-emacs-endpoint-handle "definition" '(:symbol "car"))))
            (should (eq t (plist-get answer :known)))
            (should (equal "function" (plist-get answer :type)))
            (should (equal "built-in function" (plist-get answer :kind)))
            (should (eq :false (plist-get answer :advised))))
          (should (eq :false (plist-get (harness-emacs-endpoint-handle "definition" '(:symbol "harness-endpoint-nonesuch-q"))
                                        :known)))
          (let ((answer (harness-emacs-endpoint-handle "trace" '(:action "list"))))
            (should (equal "*trace-output*" (plist-get answer :buffer)))
            (should (integerp (plist-get answer :lines))))
          (should-error (harness-emacs-endpoint-handle "trace" '(:action "eval" :symbol "car")))
          (should-error (harness-emacs-endpoint-handle "shell" nil)))
      (kill-buffer buffer))))

(ert-deftest harness-emacs-endpoint-a-change-is-for-the-file-it-was-checked-for ()
  "`insert' and `save' refuse a buffer that visits another file than the one named.
The harness checks that the session may write the file a buffer visits
before it asks to change the buffer, and says which file that was; the
Emacs makes sure the buffer still visits it, so a buffer that came to
visit another file between the check and the change is left alone.  A
request that names no file is not checked, and the empty string stands
for a buffer that visits none."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let* ((root (file-name-as-directory (harness-test-temp-dir)))
           (file (expand-file-name "checked.txt" root))
           (other (expand-file-name "other.txt" root))
           (visiting nil)
           (none (generate-new-buffer "harness-endpoint-checked-none")))
      (unwind-protect
          (progn
            (with-temp-file file (insert "one\n"))
            (setq visiting (find-file-noselect file t))
            (let ((name (buffer-name visiting)))
              ;; The file it was checked for: the change is made.
              (should (equal 1 (plist-get (harness-emacs-endpoint-handle
                                           "insert" (list :name name :text "!" :file file))
                                          :inserted)))
              ;; Another file, or none, is not the file it was checked for.
              (dolist (wrong (list other "" "/etc/passwd"))
                (let ((err (should-error (harness-emacs-endpoint-handle
                                          "insert" (list :name name :text "x" :file wrong)))))
                  (should (string-search "not the file this change was checked for" (cadr err))))
                (should-error (harness-emacs-endpoint-handle "save" (list :name name :file wrong))))
              (should (equal "!one\n" (with-current-buffer visiting (buffer-string))))
              (set-buffer-modified-p nil)
              ;; A buffer that visits none matches the empty string only.
              (should (equal 1 (plist-get (harness-emacs-endpoint-handle
                                           "insert" (list :name "harness-endpoint-checked-none" :text "a" :file ""))
                                          :inserted)))
              (should-error (harness-emacs-endpoint-handle
                             "insert" (list :name "harness-endpoint-checked-none" :text "b" :file file)))
              (should (equal "a" (with-current-buffer none (buffer-string))))
              ;; And a save writes the file it was checked for, nothing else.
              (with-current-buffer visiting (goto-char (point-max)) (insert "two\n") (set-buffer-modified-p t))
              (should-error (harness-emacs-endpoint-handle "save" (list :name name :file other)))
              (should (equal "one\n" (harness-read-file file)))
              (should (equal file (plist-get (harness-emacs-endpoint-handle "save" (list :name name :file file))
                                             :path)))
              (should (equal "!one\ntwo\n" (harness-read-file file)))
              ;; Without a file in the request, nothing is checked.
              (should (equal 1 (plist-get (harness-emacs-endpoint-handle
                                           "insert" (list :name "harness-endpoint-checked-none" :text "c"))
                                          :inserted)))))
        (when (buffer-live-p visiting) (with-current-buffer visiting (set-buffer-modified-p nil)) (kill-buffer visiting))
        (kill-buffer none)
        (delete-directory root t)))))

(defun harness-emacs-endpoint-test--log-buffer (name)
  "Make buffer NAME hold 300 lines, with strings to look for in some.
\"Naming failed\" is on lines 1, 51, 101, 151, 201 and 251, and
\"rename done\" on 71, 141, 211 and 281."
  (let ((buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (dotimes (i 300)
        (insert (format "line %03d %s\n" (1+ i)
                        (cond ((zerop (% i 50)) "Naming failed")
                              ((zerop (% i 70)) "rename done")
                              (t "plain"))))))
    buffer))

(defun harness-emacs-endpoint-test--lines-of (answer)
  "Return the line numbers of the matches in ANSWER, a search."
  (mapcar (lambda (m) (plist-get m :line)) (plist-get answer :matches)))

(ert-deftest harness-emacs-endpoint-a-buffer-is-searched-and-read-from-its-end ()
  "`buffer' gives the lines that hold given strings, or the last lines.
The strings are looked for as they are, ignoring case, never as patterns
\(a pattern written to backtrack would freeze this Emacs, which answers on
its only thread); a search is bounded in what it looks through and in
what it gives; and it asks for little: a few short strings of one line."
  (harness-emacs-endpoint-test--setup)
  (let ((buffer (harness-emacs-endpoint-test--log-buffer "harness-endpoint-search"))
        (name "harness-endpoint-search"))
    (unwind-protect
        (progn
          ;; From the end: the last lines, and the range a limit alone gives.
          (let ((answer (harness-emacs-endpoint-handle "buffer" (list :name name :tail t :limit 3))))
            (should (= 300 (plist-get answer :total)))
            (should (= 298 (plist-get answer :first)))
            (should (equal '("line 298 plain" "line 299 plain" "line 300 plain") (plist-get answer :lines))))
          (should (= 201 (plist-get (harness-emacs-endpoint-handle "buffer" (list :name name :tail t :limit 100))
                                    :first)))
          (should (= 1 (plist-get (harness-emacs-endpoint-handle "buffer" (list :name name :tail t :limit 9999))
                                  :first)))
          ;; Lines that hold a string, with their numbers, whatever the case.
          (let ((answer (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("NAMING")))))
            (should (= 6 (plist-get answer :matchCount)))
            (should (equal '(1 51 101 151 201 251) (harness-emacs-endpoint-test--lines-of answer)))
            (should (equal "line 051 Naming failed" (plist-get (nth 1 (plist-get answer :matches)) :text)))
            (should (equal 300 (plist-get answer :total)))
            (should (= 1 (plist-get answer :searchedFrom)))
            (should (equal '("NAMING") (plist-get answer :terms)))
            (should (eq :false (plist-get answer :truncated))))
          ;; Any of several, once each, in order.
          (should (equal '(1 51 71 101 141 151 201 211 251 281)
                         (harness-emacs-endpoint-test--lines-of
                          (harness-emacs-endpoint-handle
                           "buffer" (list :name name :contains '("naming" "Rename" "naming"))))))
          ;; A limit takes the first matches, or with tail the last.
          (let ((answer (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("naming" "rename") :limit 3))))
            (should (equal '(1 51 71) (harness-emacs-endpoint-test--lines-of answer)))
            (should (= 10 (plist-get answer :matchCount))))
          (should (equal '(251 281)
                         (harness-emacs-endpoint-test--lines-of
                          (harness-emacs-endpoint-handle
                           "buffer" (list :name name :contains '("naming" "rename") :limit 2 :tail t)))))
          (let ((answer (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("naming") :limit 0))))
            (should (= 6 (plist-get answer :matchCount)))
            (should-not (plist-get answer :matches)))
          ;; Nothing found is an answer.
          (let ((answer (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("no such text")))))
            (should (= 0 (plist-get answer :matchCount)))
            (should-not (plist-get answer :matches)))
          ;; Strings, not patterns: a dot is a dot, and a bracket breaks nothing.
          (with-current-buffer buffer (goto-char (point-max)) (insert "a.b [x] a(b\naxb\n"))
          (should (equal '(301) (harness-emacs-endpoint-test--lines-of
                                 (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("a.b"))))))
          (should (equal '(301) (harness-emacs-endpoint-test--lines-of
                                 (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("[x]" "a(b"))))))
          (should (equal '() (harness-emacs-endpoint-test--lines-of
                              (harness-emacs-endpoint-handle "buffer" (list :name name :contains '(".*"))))))
          ;; A buffer narrowed to a few lines is searched whole, and point stays.
          (with-current-buffer buffer (goto-char 5) (narrow-to-region 1 30))
          (should (equal '(281) (harness-emacs-endpoint-test--lines-of
                                 (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("line 281"))))))
          (should (= 5 (with-current-buffer buffer (point))))
          ;; What is given back is bounded: a line is cut, and the characters
          ;; stop at the budget, saying so.
          (with-current-buffer buffer (widen) (goto-char (point-max))
                               (insert (concat "long " (make-string 2000 ?x) "\n")))
          (let ((answer (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("long ")))))
            (should (= harness-emacs-endpoint--search-line-chars
                       (length (plist-get (car (plist-get answer :matches)) :text)))))
          (let ((answer (harness-emacs-endpoint-handle
                         "buffer" (list :name name :contains '("line 0") :maxChars 120))))
            (should (eq t (plist-get answer :truncated)))
            (should (< 0 (length (plist-get answer :matches)) 10))
            (should (< 10 (plist-get answer :matchCount))))
          ;; A buffer that does not exist.
          (should (equal '(:exists :false)
                         (harness-emacs-endpoint-handle "buffer" '(:name "harness-endpoint-none" :contains ("x")))))
          ;; What it asks for: a few short strings of one line.
          (dolist (bad (list '("") '("a\nb") '("a\rb") (make-list 6 "x")
                             (list (make-string 201 ?x)) 42 '(1 2)))
            (should-error (harness-emacs-endpoint-handle "buffer" (list :name name :contains bad))))
          (should (equal '(2) (harness-emacs-endpoint-test--lines-of
                               (harness-emacs-endpoint-handle "buffer" (list :name name :contains "line 002"))))))
      (kill-buffer buffer))))

(ert-deftest harness-emacs-endpoint-a-search-looks-through-a-bounded-end-of-the-buffer ()
  "A search looks through the last stretch of a buffer and says from which line.
So a very long buffer cannot keep this Emacs busy: the search of a
buffer is bounded by what it looks through, not by what it finds."
  (harness-emacs-endpoint-test--setup)
  (let ((buffer (harness-emacs-endpoint-test--log-buffer "harness-endpoint-scan"))
        (name "harness-endpoint-scan")
        (everything (harness-emacs-endpoint-test--lines-of
                     (let ((b (get-buffer "harness-endpoint-scan")))
                       (ignore b) nil))))
    (ignore everything)
    (unwind-protect
        (let ((full (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("naming" "rename")))))
          (should (= 10 (plist-get full :matchCount)))
          (should (= 1 (plist-get full :searchedFrom)))
          ;; Looking through about the last fifth of it.
          (let* ((harness-emacs-endpoint--search-scan-chars 1500)
                 (answer (harness-emacs-endpoint-handle "buffer" (list :name name :contains '("naming" "rename")))))
            (should (> (plist-get answer :searchedFrom) 200))
            (should (< (plist-get answer :matchCount) 10))
            (should (> (plist-get answer :matchCount) 0))
            (should (cl-every (lambda (n) (>= n (plist-get answer :searchedFrom)))
                              (harness-emacs-endpoint-test--lines-of answer)))
            ;; The numbers are the buffer's own lines.
            (should (member 281 (harness-emacs-endpoint-test--lines-of answer)))
            (should (equal "line 281 rename done"
                           (plist-get (car (last (plist-get answer :matches))) :text)))))
      (kill-buffer buffer))))

(ert-deftest harness-emacs-endpoint-reads-are-bounded ()
  "Nothing big crosses from the user's Emacs: a long buffer is read in
ranges, a long line is cut, and a big value is printed only in part."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((conn (harness-test-connect-ui-client))
          (buffer (generate-new-buffer "harness-endpoint-long"))
          (harness-tools-max-output-chars 1500))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (dotimes (i 300) (insert (format "line %03d of the long buffer\n" (1+ i)))))
            (let* ((c (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long") :content))
                   (next (and (string-match "read on with offset \\([0-9]+\\)" c)
                              (string-to-number (match-string 1 c)))))
              (should next)
              (should (< 1 next 300))
              (should (string-search "lines 1-" c))
              (should (< (length c) harness-tools-max-output-chars))
              (let ((c2 (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long"
                                                                      :offset next)
                                   :content)))
                (should (string-prefix-p (format "%6d\tline %03d" next next) c2))))
            ;; One line longer than a whole read is cut, and the read goes on after it.
            (with-current-buffer buffer (erase-buffer) (insert (make-string 5000 ?x) "\nshort\n"))
            (let ((c (plist-get (harness-emacs-endpoint-test--call "emacs_buffer" :name "harness-endpoint-long") :content)))
              (should (string-search "read on with offset 2" c))
              (should (< (length c) harness-tools-max-output-chars)))
            ;; A long list is printed in part by the user's Emacs.
            (defvar harness-emacs-endpoint-test--long (number-sequence 1 100000))
            (let ((c (plist-get (harness-emacs-endpoint-test--call "emacs_describe" :symbol "harness-emacs-endpoint-test--long")
                                :content)))
              (should (string-search "value: (1 2 3" c))
              (should (< (length c) 800))))
        (kill-buffer buffer)
        (harness-acp-close conn)))))

;;;; No request evaluates code

;; The lent Emacs once answered an `eval' request too, which ran the code
;; a model wrote in the user's own Emacs, outside every sandbox.  It does
;; not any more; these tests keep it that way.

(defvar harness-emacs-endpoint-test--ran nil
  "Set by code a test hands the lent Emacs to evaluate, if it ever runs.")

(declare-function harness-acp-error-value-p "harness-acp")
(declare-function harness-acp-error-value-message "harness-acp")

(ert-deftest harness-emacs-endpoint-has-a-fixed-vocabulary-without-eval ()
  "The lent Emacs answers eleven requests of data and bounded work, and none
takes code to run: there is no `eval', no option that would turn one on,
and none of the machinery that ran one is left."
  (require 'harness-emacs-endpoint)
  (should (equal '("buffers" "windows" "buffer" "open" "insert" "save"
                   "describe" "definition" "trace" "messages" "snapshot")
                 (mapcar #'car harness-emacs-endpoint--methods)))
  (should-not (assoc "eval" harness-emacs-endpoint--methods))
  ;; Every request is answered at once: nothing is left to answer later.
  (should-not (boundp 'harness-emacs-endpoint--deferred-methods))
  ;; The option and its predicate are gone, not just off.
  (should-not (fboundp 'harness-emacs-eval-p))
  (should-not (boundp 'harness-emacs-eval))
  (should-not (custom-variable-p 'harness-emacs-eval))
  ;; Nor the guarded evaluation, or the bridge that let the code call
  ;; the harness back.
  (dolist (fn '(harness-emacs-endpoint--eval harness-emacs-endpoint--eval-run
                harness-emacs-endpoint--eval-start harness-emacs-endpoint--forwarder
                harness-acp-call-lisp))
    (should-not (fboundp fn)))
  (should-not (boundp 'harness-call-fallback-function)))

(ert-deftest harness-emacs-endpoint-refuses-eval-as-any-unknown-request ()
  "Asked to evaluate, the lent Emacs gives the error it gives any request
it does not know, and runs nothing."
  (harness-emacs-endpoint-test--setup)
  (setq harness-emacs-endpoint-test--ran nil)
  (let ((params (list :code "(setq harness-emacs-endpoint-test--ran t)"))
        (responses nil))
    (let ((err (should-error (harness-emacs-endpoint-handle "eval" params))))
      (should (string-search "This Emacs answers no request eval" (error-message-string err))))
    (should (harness-emacs-endpoint-answer "_harness/emacs/eval" params
                                           (lambda (r) (push r responses) t)))
    (should (= 1 (length responses)))
    (should (harness-acp-error-value-p (car responses)))
    (should (string-search "This Emacs answers no request eval"
                           (harness-acp-error-value-message (car responses))))
    (should-not harness-emacs-endpoint-test--ran)))

(ert-deftest harness-emacs-endpoint-the-harness-cannot-ask-the-lent-emacs-to-evaluate ()
  "A request to evaluate, sent as the harness sends the others, is refused
by the lent Emacs: the promise rejects with its message, and the Emacs
still answers the requests it knows."
  (harness-emacs-endpoint-test--setup)
  (harness-test-with-temp-state
    (let ((conn (harness-test-connect-ui-client)))
      (unwind-protect
          (progn
            (setq harness-emacs-endpoint-test--ran nil)
            (let ((r (condition-case err
                         (harness-test-await
                          (harness-call 'emacs/request "eval"
                                        (list :code "(setq harness-emacs-endpoint-test--ran t)"))
                          20)
                       (error (list 'failed (harness-tools-reason err))))))
              (should (eq 'failed (car r)))
              (should (string-search "Unknown tool: eval" (cadr r))))
            (should-not harness-emacs-endpoint-test--ran)
            (should (plist-get (harness-test-await (harness-call 'emacs/request "buffers" nil) 20)
                               :buffers)))
        (harness-acp-close conn)))))

(ert-deftest harness-emacs-endpoint-still-advertises-the-emacs ()
  "An Emacs lends itself as before: its version, process and host under
`_harness.emacs', and none of ACP's own file or terminal capabilities.
The advertisement offers no way to evaluate."
  (require 'harness-emacs-endpoint)
  (let* ((capabilities (harness-emacs-endpoint-client-capabilities))
         (lent (plist-get capabilities :_harness))
         (emacs (plist-get lent :emacs)))
    (should (equal emacs-version (plist-get emacs :version)))
    (should (equal (emacs-pid) (plist-get emacs :pid)))
    (should (equal (system-name) (plist-get emacs :host)))
    (should (equal '(:emacs) (cl-loop for (key _) on lent by #'cddr collect key)))
    (should (equal '(:version :pid :host) (cl-loop for (key _) on emacs by #'cddr collect key)))
    (should (eq :false (plist-get capabilities :terminal)))
    (should (eq :false (plist-get (plist-get capabilities :fs) :readTextFile)))
    (should (eq :false (plist-get (plist-get capabilities :fs) :writeTextFile)))))

(ert-deftest harness-emacs-endpoint-an-init-file-that-still-sets-the-old-option-is-harmless ()
  "`(setq harness-emacs-eval nil)' in an init file written before the
option was removed sets a variable nothing reads: it defines no option,
offers no tool and changes no answer."
  (harness-emacs-endpoint-test--setup)
  (unwind-protect
      (dolist (value '(nil t))
        (set 'harness-emacs-eval value)
        (should-not (custom-variable-p 'harness-emacs-eval))
        (should-not (harness-tool-get "emacs_eval"))
        (should-error (harness-emacs-endpoint-handle "eval" '(:code "(+ 1 2)"))))
    (makunbound 'harness-emacs-eval)))

;;;; Chores of the UI

(ert-deftest harness-emacs-endpoint-global-config-is-saved-by-the-ui ()
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (harness-test-load-module 'project)
    (harness-test-load-module 'config)
    (harness-test-connect-ui-client)
    ;; Like a normal session: customize refuses to save under "emacs -q".
    (let* ((init-file-user "")
           (user-init-file (expand-file-name "init.el" harness-state-directory))
           (custom-file (expand-file-name "custom.el" harness-state-directory))
           (harness-model harness-model))
      (harness-call 'config/set 'harness-model "demo:other" :scope 'global)
      (should (equal "demo:other" harness-model))
      (harness-test-wait (lambda () (file-exists-p custom-file)) 5 "custom file")
      (should (string-search "demo:other" (harness-read-file custom-file))))))

(ert-deftest harness-emacs-endpoint-customize-save-refuses-foreign-options ()
  (require 'harness-emacs-endpoint)
  (should-error (harness-emacs-endpoint-customize-save "fill-column" "70"))
  (should-error (harness-emacs-endpoint-customize-save nil "70")))

(provide 'harness-emacs-endpoint-test)
;;; harness-emacs-endpoint-test.el ends here
