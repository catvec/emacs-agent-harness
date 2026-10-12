;;; harness-ui-search-test.el --- Tests for the search of the sessions  -*- lexical-binding: t; -*-

;;; Commentary:

;; The search's results over the in-process harness: C-c h g reads a
;; query and shows the sessions that match, what was found highlighted;
;; m, a, s and + search again another way; n and p go from match to
;; match; RET opens the session at a match, older pages of its history
;; loaded until the match shows, with point on what was found -- also
;; in a folded run of tool calls and past the part of a long output
;; shown at first.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-ui--sessions)
(defvar harness-ui-map)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-provider-demo--delay)
(defvar harness-session-search-index)
(defvar harness-session-search-embedding-model)
(defvar harness-session-search-embedding-dimensions)
(defvar harness-ui-search-default-mode)
(defvar harness-ui-search-default-scope)
(defvar harness-ui-search-max-sessions)
(defvar harness-ui-search--buffer-name)
(defvar harness-ui-search--result)
(defvar harness-ui-search--loading)
(defvar harness-ui-search--error)
(defvar harness-ui-search--mode)
(defvar harness-ui-search--project)
(defvar harness-ui-search--query)
(defvar harness-ui-search--max-sessions)
(defvar harness-ui-search-mode-map)
(defvar harness-chat--buffers)
(defvar harness-chat--blocks)
(defvar harness-chat--order)
(defvar harness-chat--goto)
(defvar harness-chat--found)
(defvar harness-chat--loading)
(defvar harness-chat--groups)
(defvar harness-chat--history-limit)
(defvar harness-chat--history-page)
(declare-function harness-search-sessions "harness-ui-search")
(declare-function harness-ui-search-next "harness-ui-search")
(declare-function harness-ui-search-previous "harness-ui-search")
(declare-function harness-ui-search-open "harness-ui-search")
(declare-function harness-ui-search-cycle-mode "harness-ui-search")
(declare-function harness-ui-search-toggle-scope "harness-ui-search")
(declare-function harness-ui-search-new "harness-ui-search")
(declare-function harness-ui-search-more "harness-ui-search")
(declare-function harness-ui-search-visit "harness-ui-search")
(declare-function harness-ui-search-hit-regexp "harness-ui-search")
(declare-function harness-ui-search--insert-session "harness-ui-search")
(declare-function harness-session-search-emacs-regexp "harness-session-search")
(declare-function harness-ui-visit-session "harness-ui")
(declare-function harness-ui-chat-goto-node "harness-ui-chat")
(declare-function harness-chat--buffer-for "harness-ui-chat")
(declare-function harness-chat-buffer "harness-ui-chat")
(declare-function harness-chat-block-start "harness-ui-chat")
(declare-function harness-chat-block-group "harness-ui-chat")
(declare-function harness-chat-block-show-all "harness-ui-chat")
(declare-function harness-chat-group-expanded "harness-ui-chat")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function transient-get-suffix "transient")

(defmacro harness-ui-search-test-with (&rest body)
  "Load the harness with its search, ACP, the chat and the search's results; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent usage session-search acp
                          ui ui-chat ui-search))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-ui--sessions)
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-acp-token nil)
           (harness-session-search-index t)
           (harness-session-search-embedding-model nil)
           (harness-session-search-embedding-dimensions nil)
           (harness-ui-search-default-mode "text")
           (harness-ui-search-default-scope 'all)
           (default-directory dir))
       ;; Reads fold into a run of calls, as the chat's tests have them.
       (harness-define-tool "read_file" :label "Read file" :description "read" :kind 'read :coalescable t
                            :subject (lambda (input) (plist-get input :path))
                            :handler (lambda (input _ctx) (format "contents of %s" (plist-get input :path))))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer harness-ui-search--buffer-name) (kill-buffer harness-ui-search--buffer-name))
         (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) harness-chat--buffers)
         (clrhash harness-chat--buffers)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-search-test-session (name project &rest nodes)
  "Create session NAME in directory PROJECT with NODES, plists; return its id."
  (let ((sid (plist-get (harness-call 'session/create :cwd project :model "demo:scripted" :name name) :id)))
    (dolist (node nodes) (harness-call 'session/append sid node))
    sid))

(defun harness-ui-search-test-project ()
  "A new directory, a project of its own."
  (file-name-as-directory (harness-test-temp-dir)))

(defun harness-ui-search-test-wait ()
  "Wait for the search shown to come back; return the buffer's text."
  (with-current-buffer harness-ui-search--buffer-name
    (harness-test-wait (lambda () (and (not harness-ui-search--loading)
                                       (or harness-ui-search--result harness-ui-search--error)))
                       30 "the search")
    (should-not harness-ui-search--error)
    (buffer-string)))

(defun harness-ui-search-test-search (query &optional mode)
  "Search for QUERY in MODE from the current buffer; return the results' text."
  (harness-search-sessions query mode)
  (harness-ui-search-test-wait))

(defun harness-ui-search-test-line ()
  "The line point is on in the results, without properties."
  (with-current-buffer harness-ui-search--buffer-name
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

(defun harness-ui-search-test-matched (text)
  "The parts of TEXT drawn as what a search found."
  (let (found (pos 0))
    (while (setq pos (text-property-not-all pos (length text) 'face nil text))
      (let ((end (or (next-single-property-change pos 'face text) (length text)))
            (face (get-text-property pos 'face text)))
        (when (memq 'harness-ui-search-match-face (ensure-list face))
          (push (substring-no-properties text pos end) found))
        (setq pos end)))
    (nreverse found)))

(defun harness-ui-search-test-open-here ()
  "Open the match at point in the results; return the chat buffer once it shows it."
  (with-current-buffer harness-ui-search--buffer-name
    (let ((sid (get-text-property (point) 'harness-ui-search-session)))
      (harness-ui-search-open)
      (let ((buf (harness-chat--buffer-for sid)))
        (should buf)
        (harness-test-wait (lambda () (with-current-buffer buf
                                        (and (not harness-chat--loading) (null harness-chat--goto)
                                             harness-chat--order)))
                           30 "the chat at the match")
        buf))))

(defun harness-ui-search-test-looking-at (buf regexp)
  "Non-nil when point in BUF, and in its window, is on REGEXP, highlighted."
  (with-current-buffer buf
    (let ((case-fold-search t)
          (window (get-buffer-window buf t)))
      (and (looking-at regexp)
           (or (null window) (= (window-point window) (point)))
           (cl-some (lambda (ov) (and (overlay-buffer ov) (= (overlay-start ov) (point))
                                      (eq (overlay-get ov 'face) 'harness-chat-found-face)))
                    harness-chat--found)))))

;;;; The results

(ert-deftest harness-ui-search-shows-what-matches ()
  "A search lists the sessions that match, best first, their matches marked."
  (harness-ui-search-test-with
    (let ((project (harness-ui-search-test-project)))
      (harness-ui-search-test-session "Parser work" project
                                      '(:kind user :content "The parser crashes on unicode input")
                                      '(:kind assistant :content "Fixed the crash: the tokenizer read past the end"))
      (harness-ui-search-test-session "Docs pass" project
                                      '(:kind user :content "Rewrite the README for the new commands"))
      (harness-ui-search-test-session "Crash triage" project
                                      '(:kind user :content "Look at the crash reports"))
      (let ((text (harness-ui-search-test-search "crash")))
        (should (string-match-p "2 sessions match “crash”" text))
        (should (string-search "Parser work" text))
        (should (string-search "Crash triage" text))
        (should (string-search "(its name matches)" text))
        (should-not (string-search "Docs pass" text))
        ;; Words match in any form, and the forms found are marked.
        (should (equal '("crash" "crashes")
                       (sort (delete-dups (mapcar #'downcase (harness-ui-search-test-matched text))) #'string<)))
        (with-current-buffer harness-ui-search--buffer-name
          (should (derived-mode-p 'harness-ui-search-mode))
          ;; Point starts on the best session, at its best match.
          (should (get-text-property (point) 'harness-ui-search-node))
          (let ((first (harness-ui-search-test-line)))
            (harness-ui-search-next)
            (should-not (equal first (harness-ui-search-test-line)))
            (should (get-text-property (point) 'harness-ui-search-node))
            (harness-ui-search-previous)
            (should (equal first (harness-ui-search-test-line))))))
      ;; Nothing found says so.
      (should (string-search "No session matches “zeppelin”" (harness-ui-search-test-search "zeppelin"))))))

(ert-deftest harness-ui-search-searches-again-another-way ()
  "m changes the mode, a the project, s the query and + how many sessions show."
  (harness-ui-search-test-with
    (let ((here (harness-ui-search-test-project))
          (there (harness-ui-search-test-project)))
      (harness-ui-search-test-session "Here" here '(:kind user :content "call foo.bar(baz) twice"))
      (harness-ui-search-test-session "There" there '(:kind user :content "call foo.bar(qux) once"))
      (dotimes (i 3)
        (harness-ui-search-test-session (format "Filler %d" i) there
                                        (list :kind 'user :content (format "foo number %d" i))))
      (let ((default-directory here))
        (should (string-search "5 sessions match" (harness-ui-search-test-search "foo"))))
      (with-current-buffer harness-ui-search--buffer-name
        ;; Literal, then regexp.
        (harness-ui-search-cycle-mode)
        (should (equal "literal" harness-ui-search--mode))
        (harness-ui-search-new "foo.bar(")
        (let ((text (harness-ui-search-test-wait)))
          (should (string-search "2 sessions match" text))
          (should (equal '("foo.bar(" "foo.bar(") (harness-ui-search-test-matched text))))
        (harness-ui-search-cycle-mode)
        (should (equal "regexp" harness-ui-search--mode))
        (harness-ui-search-new "bar\\((baz|quux)\\)")
        (let ((text (harness-ui-search-test-wait)))
          (should (string-search "1 session matches" text))
          (should (string-search "Here" text))
          (should-not (string-search "There" text)))
        ;; Only the project it was started from, and back.
        (harness-ui-search-cycle-mode)
        (harness-ui-search-cycle-mode)
        (should (equal "text" harness-ui-search--mode))
        (harness-ui-search-new "call")
        (should (string-search "2 sessions match" (harness-ui-search-test-wait)))
        (harness-ui-search-toggle-scope)
        (should (equal here harness-ui-search--project))
        (let ((text (harness-ui-search-test-wait)))
          (should (string-search "1 session in" text))
          (should (string-search "Here" text))
          (should-not (string-search "There" text)))
        (harness-ui-search-toggle-scope)
        (should-not harness-ui-search--project)
        (should (string-search "2 sessions match" (harness-ui-search-test-wait)))
        ;; A few at a time, then more.
        (let ((harness-ui-search-max-sessions 2))
          (harness-ui-search-new "foo")
          (let ((text (harness-ui-search-test-wait)))
            (should (string-search "the best 2 shown" text))
            (should (string-search "3 more sessions match" text)))
          (harness-ui-search-more)
          (should (= 4 harness-ui-search--max-sessions))
          (should (string-search "1 more session matches" (harness-ui-search-test-wait))))))))

(ert-deftest harness-ui-search-is-on-the-keys ()
  "C-c h g searches, from anywhere, and so does g in the harness menu."
  (harness-ui-search-test-with
    (should (eq (lookup-key harness-ui-map (kbd "g")) #'harness-search-sessions))
    ;; A suffix is (CLASS . PLIST) since transient 0.8, (LEVEL CLASS PLIST) before.
    (let ((suffix (transient-get-suffix 'harness-menu "g")))
      (should (eq 'harness-search-sessions
                  (plist-get (if (keywordp (cadr suffix)) (cdr suffix) (car (last suffix))) :command))))
    (should (eq (lookup-key harness-ui-search-mode-map (kbd "RET")) #'harness-ui-search-open))))

;;;; Opening a session at a hit

(ert-deftest harness-ui-search-visit-opens-the-session-at-the-node ()
  "The session opens, then, with a node, its chat shows the node, point on
the regexp; without a node it only opens."
  (harness-ui-search-test-with
    (let ((calls nil))
      (cl-letf (((symbol-function 'harness-ui-visit-session)
                 (lambda (sid &rest _) (push (list 'visit sid) calls) nil))
                ((symbol-function 'harness-ui-chat-goto-node)
                 (lambda (&rest args) (push (cons 'goto args) calls) nil)))
        (harness-ui-search-visit "s-1" "n-1" "needle")
        (harness-ui-search-visit "s-2")
        (harness-ui-search-visit "s-3" "n-3"))
      (should (equal '((visit "s-1") (goto "n-1" "s-1" "needle")
                       (visit "s-2")
                       (visit "s-3") (goto "n-3" "s-3" nil))
                     (nreverse calls))))))

(ert-deftest harness-ui-search-open-visits-the-match-at-point ()
  "RET opens the session of the match at point at its node, on the words found."
  (harness-ui-search-test-with
    (let* ((project (harness-ui-search-test-project))
           (sid (harness-ui-search-test-session "Parser work" project
                                                '(:kind user :content "The parser crashes on unicode input"))))
      (harness-ui-search-test-search "crash")
      (with-current-buffer harness-ui-search--buffer-name
        (let ((node (get-text-property (point) 'harness-ui-search-node))
              (called nil))
          (should node)
          (cl-letf (((symbol-function 'harness-ui-search-visit) (lambda (&rest args) (setq called args))))
            (harness-ui-search-open))
          (should (equal (list sid node) (seq-take called 2)))
          (should (string-match-p (nth 2 called) "crashes")))))))

(ert-deftest harness-ui-search-hit-regexp-says-what-was-found ()
  "The regexp matches what the snippet marks, in the forms found, longest first,
any run of spaces as any other; with nothing marked it is the query, as the
literal or regexp search took it."
  (harness-ui-search-test-with
    (let* ((snippet "…why the merge queue dropped a Commit…")
           (merge (string-search "merge" snippet))
           (queue (string-search "queue" snippet))
           (commit (string-search "Commit" snippet)))
      ;; Words marked one by one: each, as found there, in any case, the
      ;; longer first.
      (let ((re (harness-ui-search-hit-regexp
                 (list :snippet snippet :ranges (list (list merge (+ merge 5)) (list commit (+ commit 6)))))))
        (should (equal "commit\\|merge" re))
        (should (string-match-p re "COMMIT")))
      ;; A phrase, spaces as any spaces; the longest alternative first.
      (let ((re (harness-ui-search-hit-regexp
                 (list :snippet snippet :ranges (list (list queue (+ queue 5)) (list merge (+ queue 5)))))))
        (should (equal "merge[[:space:]]+queue\\|queue" re))
        (should (string-match-p re "merge \n queue")))
      ;; What a regexp would read as one is quoted; a mark outside the snippet is no mark.
      (should (equal "foo\\.bar("
                     (harness-ui-search-hit-regexp (list :snippet "call foo.bar( twice" :ranges '((5 13))))))
      (should-not (harness-ui-search-hit-regexp (list :snippet "short" :ranges '((3 30) (-1 2) (nil 1)))))
      ;; Nothing marked: the query, as the mode took it.
      (let ((hit (list :snippet "call foo.bar( twice")))
        (should (equal "foo\\.bar(" (harness-ui-search-hit-regexp hit "foo.bar(" "literal")))
        (let ((re (harness-ui-search-hit-regexp hit "bar\\((baz|quux)\\)" "regexp")))
          (should (equal (harness-session-search-emacs-regexp "bar\\((baz|quux)\\)") re))
          (should (string-match-p re "bar(baz)"))
          (should-not (string-match-p re "bar(qux)")))
        ;; In any other mode, or with no query, there is nothing to find.
        (should-not (harness-ui-search-hit-regexp hit "foo.bar(" "text"))
        (should-not (harness-ui-search-hit-regexp hit "foo.bar("))
        (should-not (harness-ui-search-hit-regexp hit nil "literal"))
        (should-not (harness-ui-search-hit-regexp hit "" "literal"))))))

(ert-deftest harness-ui-search-results-hand-over-their-query-and-mode ()
  "The results buffer gives the regexp of a hit with nothing marked its own
query and mode: a literal search's text is what RET puts point on."
  (harness-ui-search-test-with
    (with-temp-buffer
      (setq-local harness-ui-search--query "foo.bar(")
      (setq-local harness-ui-search--mode "literal")
      (harness-ui-search--insert-session
       (list :id "s-1" :name "Calls" :hits (list (list :node "n-1" :snippet "call foo.bar( twice"))))
      (let ((pos (text-property-not-all (point-min) (point-max) 'harness-ui-search-find nil)))
        (should pos)
        (should (equal "foo\\.bar(" (get-text-property pos 'harness-ui-search-find)))
        (should (equal "n-1" (get-text-property pos 'harness-ui-search-node)))))))

(ert-deftest harness-ui-search-opens-the-session-at-the-match ()
  "RET opens the session with point on what was found, far back as it may be."
  (harness-ui-search-test-with
    (let* ((project (harness-ui-search-test-project))
           (harness-chat--history-limit 10)
           (harness-chat--history-page 10)
           (sid (harness-ui-search-test-session "Long" project
                                                '(:kind user :content "Where is the needle in this haystack?"))))
      (dotimes (i 45)
        (harness-call 'session/append sid (list :kind 'assistant :content (format "Straw number %d." i))))
      (harness-ui-search-test-search "needle")
      (with-current-buffer harness-ui-search--buffer-name
        (should (equal sid (get-text-property (point) 'harness-ui-search-session))))
      ;; The chat's history timer, 50 ms after a page, drops the oldest pages
      ;; that lie far above its windows (`harness-chat--drop-earlier'), by
      ;; their start -- which a batch Emacs, never redisplaying, does not move
      ;; to the match.  It would race the checks below (which look in every
      ;; 25 ms) and drop the match itself: a pause of the process, a collection
      ;; of its garbage, decides.  Paging to the match is the test, not dropping.
      (cl-letf (((symbol-function 'harness-chat--manage-history) #'ignore))
        (let ((buf (harness-ui-search-test-open-here)))
          (with-current-buffer buf
            ;; Every page back to the first message is loaded, and no more.
            (should (= 46 (length harness-chat--order)))
            (should (harness-ui-search-test-looking-at buf "needle"))))))))

(ert-deftest harness-ui-search-opens-what-is-folded ()
  "A match in a folded run of calls opens the run; one in a long output shows it all."
  (harness-ui-search-test-with
    (let* ((project (harness-ui-search-test-project))
           (long (concat (mapconcat (lambda (i) (format "line %d of the log" i)) (number-sequence 1 400) "\n")
                         "\nzebra crossing at the very end"))
           (sid (harness-ui-search-test-session "Reads" project '(:kind user :content "Read the files"))))
      (dotimes (i 4)
        (let ((call (format "c%d" i)))
          (harness-call 'session/append sid (list :kind 'tool-call :tool "read_file" :call-id call
                                                  :input (list :path (format "f%d.log" i))
                                                  :title (format "Read file: f%d.log" i)))
          (harness-call 'session/append sid (list :kind 'tool-result :call-id call
                                                  :output (if (= i 2) long (format "short output %d" i))))))
      (harness-call 'session/append sid '(:kind assistant :content "Read them all."))
      (harness-ui-search-test-search "zebra")
      (let ((buf (harness-ui-search-test-open-here)))
        (with-current-buffer buf
          (should (harness-ui-search-test-looking-at buf "zebra"))
          (let ((block (gethash (get-text-property (point) 'harness-chat-node) harness-chat--blocks)))
            (should (harness-chat-block-show-all block))
            (should (harness-chat-group-expanded (gethash (harness-chat-block-group block) harness-chat--groups))))
          (should (equal "zebra" (buffer-substring-no-properties (point) (+ (point) 5)))))))))

(ert-deftest harness-ui-search-says-a-match-is-off-the-branch ()
  "A node the session's current branch does not reach is looked for, then reported."
  (harness-ui-search-test-with
    (let* ((project (harness-ui-search-test-project))
           (sid (harness-ui-search-test-session "Branches" project '(:kind user :content "first try")))
           (off (plist-get (harness-call 'session/append sid '(:kind assistant :content "a dead end")) :id))
           (root (car (harness-call 'session/nodes sid))))
      (harness-call 'session/set-head sid (plist-get root :id))
      (harness-call 'session/append sid '(:kind assistant :content "the way on"))
      (let ((buf (harness-chat-buffer sid))
            (messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (when fmt (push (apply #'format-message fmt args) messages)))))
          (harness-ui-chat-goto-node off sid "dead")
          (harness-test-wait (lambda () (with-current-buffer buf
                                          (and (not harness-chat--loading) (null harness-chat--goto))))
                             10 "the search for the node"))
        (should (cl-some (lambda (m) (string-match-p "not on this session.s current branch" m)) messages))
        (with-current-buffer buf
          (should-not harness-chat--found))))))

(provide 'harness-ui-search-test)
;;; harness-ui-search-test.el ends here
