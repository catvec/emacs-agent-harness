;;; harness-ui-watches-test.el --- Tests for the event-watch panel  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session that watches events shows its watches pinned above the
;; compose box: one line per watch still live, with the kinds of event
;; it watches, what it narrows them to, what it has seen and, dim, its
;; prompt.  The panel asks the harness for them (`event-watch/list') the
;; first time it is drawn and when `event-watch/changed' says one
;; changed; the questions share one timer and the drawings another, and
;; a drawing that would show the same text is left out.  No test waits
;; for a timer: the tests call the flush and the drawing themselves.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-ui-session-id)
(defvar harness-compose-redraw-function)
(defvar harness-ui-watches--cache)
(defvar harness-ui-watches--drawn)
(defvar harness-ui-watches--timer)
(defvar harness-ui-watches--draw-timer)
(defvar harness-ui-watches--fetching)
(defvar harness-ui-watches--pending)
(defvar harness-ui-watches--fetched)

(defmacro harness-ui-watches-test-with (&rest body)
  "Load the UI and its watches module with a fresh watch cache."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(ui ui-compose ui-markdown ui-popout ui-chat ui-watches))
         (harness-test-load-module m)))
     (clrhash harness-ui-watches--cache)
     (progn ,@body)))

(defun harness-ui-watches-test--watch (session &rest plist)
  "Add a watch of SESSION to the cache, its fields from PLIST, and return it.
The fields a test does not give are the ones a fresh watch has: no
events seen, no decision made, nothing waiting."
  (let ((watch (append plist
                       (list :id (or (plist-get plist :id) "w-1")
                             :events (or (plist-get plist :events) '("task/done"))
                             :actions (or (plist-get plist :actions) '("wake"))
                             :prompt (or (plist-get plist :prompt) "Watch it.")
                             :once (if (plist-member plist :once) (plist-get plist :once) t)
                             :seen (or (plist-get plist :seen) 0)
                             :decisions (or (plist-get plist :decisions) 0)
                             :queued (or (plist-get plist :queued) 0)))))
    (puthash session (append (gethash session harness-ui-watches--cache) (list watch))
             harness-ui-watches--cache)
    watch))

(defun harness-ui-watches-test--plain (text)
  "Return TEXT without properties, or nil."
  (and (stringp text) (substring-no-properties text)))

(defmacro harness-ui-watches-test-with-chat (spec &rest body)
  "Run BODY with a temp buffer that plays the chat of session \"p\".
SPEC is (CHAT REDRAWS): CHAT is bound to the buffer, REDRAWS to how
many times its tail was drawn, 0 at first.  Drawing the tail draws the
panel as the real chat does (`harness-ui-watches--panel'), which
records what it drew, and counts.  The buffer has had its watches
(`harness-ui-watches--fetched'), so nothing here asks the harness
unless a test stubs the fetch.  No timer or buffer outlives BODY."
  (declare (indent 1))
  (let ((chat (car spec)) (redraws (cadr spec)))
    `(let ((,chat (generate-new-buffer " *watches chat*"))
           (,redraws 0))
       (unwind-protect
           (progn
             (with-current-buffer ,chat
               (setq-local harness-ui-session-id "p")
               (setq-local harness-ui-watches--fetched t)
               (setq-local harness-compose-redraw-function
                           (lambda () (cl-incf ,redraws) (harness-ui-watches--panel))))
             ,@body)
         (when (timerp harness-ui-watches--timer)
           (cancel-timer harness-ui-watches--timer))
         (when (buffer-live-p ,chat) (kill-buffer ,chat))))))

(ert-deftest harness-ui-watches-panel-lists-the-live-watches ()
  "The panel lists every live watch of the session on a line of its own:
the kinds it watches, what it narrows them to, what it has seen and,
dim, its prompt.  A watch of this session says so; one of every project
says that.  A session that watches nothing shows no panel."
  (harness-ui-watches-test-with
    (harness-ui-watches-test--watch
     "p" :id "w-1" :events '("task/done") :target "p"
         :prompt "Watch the board." :seen 3 :decisions 1)
    (harness-ui-watches-test--watch
     "p" :id "w-2" :events '("merge/conflict") :all-projects t :seen 0)
    (harness-ui-watches-test-with-chat (chat redraws)
      (let* ((panel (with-current-buffer chat (harness-ui-watches--panel)))
             (text (harness-ui-watches-test--plain panel)))
        (should (string-match-p "Event watches  2 live" text))
        (should (string-match-p
                 "task/done  ·  this session  ·  3 events · 1 decision"
                 text))
        (should (string-match-p "merge/conflict  ·  every project  ·  0 events · 0 decisions"
                                text))
        ;; The prompt is the line's dim tail.
        (should (string-match-p "1 decision   Watch the board\\.\n" text))
        ;; One line per watch, and the header.
        (should (= 3 (length (split-string text "\n" t))))
        ;; The line says in its tooltip what the watch looks for and may do.
        (let* ((start (string-match "task/done" text))
               (line (get-text-property start 'help-echo panel)))
          (should (string-match-p "Watch the board\\." line))
          (should (string-match-p "Actions: wake" line))
          (should (string-match-p "first decision" line))))
      ;; Nothing to watch, nothing drawn.
      (clrhash harness-ui-watches--cache)
      (should-not (with-current-buffer chat (harness-ui-watches--panel))))))

(ert-deftest harness-ui-watches-panel-draws-again-only-when-it-changed ()
  "A drawing asked for shows the panel again only when its text changed:
the same watches leave the tail alone, a watch that ended or arrived
draws it."
  (harness-ui-watches-test-with
    (let ((watch (harness-ui-watches-test--watch "p" :id "w-1" :target "p")))
      (harness-ui-watches-test-with-chat (chat redraws)
        ;; The first drawing draws the panel.
        (harness-ui-watches--draw-now chat)
        (should (= 1 redraws))
        ;; The same text draws nothing.
        (harness-ui-watches--draw-now chat)
        (should (= 1 redraws))
        ;; Another watch draws it.
        (harness-ui-watches-test--watch "p" :id "w-2" :events '("merge/conflict"))
        (harness-ui-watches--draw-now chat)
        (should (= 2 redraws))
        ;; The watch that ended draws it.
        (puthash "p" (cl-remove-if (lambda (w) (equal "w-1" (plist-get w :id)))
                                   (gethash "p" harness-ui-watches--cache))
                 harness-ui-watches--cache)
        (harness-ui-watches--draw-now chat)
        (should (= 3 redraws))))))

(ert-deftest harness-ui-watches-a-change-asks-for-the-watches-again ()
  "`event-watch/changed' asks for the watches of the session it names, the
changes that come together asking once, and a session that watches
nothing asks only when it is first drawn."
  (harness-ui-watches-test-with
    (harness-ui-watches-test--watch "p" :id "w-1" :target "p")
    (harness-ui-watches-test-with-chat (chat redraws)
      (let ((fetches nil))
        (cl-letf (((symbol-function 'harness-ui-watches--fetch)
                   (lambda (buffer)
                     (push buffer fetches)
                     (with-current-buffer buffer
                       (setq harness-ui-watches--fetched t)))))
          ;; A change asks, once, once the changes settle.
          (harness-ui-watches--on-event "event-watch/changed" '("p" "w-1"))
          (harness-ui-watches--on-event "event-watch/changed" '("p" "w-1"))
          (should (= 1 (length (cl-remove-if-not
                               (lambda (timer) (eq (timer--function timer)
                                                   #'harness-ui-watches--flush))
                               timer-list))))
          (harness-ui-watches--flush chat)
          (should (equal (list chat) fetches))
          ;; Another session's change is none of this chat's.
          (harness-ui-watches--on-event "event-watch/changed" '("q" "w-2"))
          (should-not (timerp harness-ui-watches--timer))
          ;; A panel drawn before its first answer asks on its own, once.
          (with-current-buffer chat
            (setq harness-ui-watches--fetched nil)
            (harness-ui-watches--panel)
            (should (= 2 (length fetches)))
            (harness-ui-watches--panel)
            (should (= 2 (length fetches)))))))))

(provide 'harness-ui-watches-test)
;;; harness-ui-watches-test.el ends here
