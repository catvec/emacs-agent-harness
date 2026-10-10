;;; harness-ui-version-test.el --- Tests for the version page  -*- lexical-binding: t; -*-

;;; Commentary:

;; The page drawn from reports shaped as the version module makes them:
;; the verdict, the origins and the commits the harness lacks, the hints
;; on what to do, the commit this Emacs loaded beside the harness
;; process's.  Then how it follows the harness: reports announced, a
;; new connection, failed checks.  Then the icon nagging while the
;; harness is behind, in the mode line notifier and the header lines of
;; chats and the board.  Last, the whole way: the UI asking the version
;; module over its ACP connection about real repositories.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-revision)
(require 'harness-ui)
(require 'harness-ui-chat)
(require 'harness-ui-tasks)
(require 'harness-ui-notify)
(require 'harness-ui-version)

(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-version-origins)
(defvar harness-ui--sessions)
(declare-function harness-acp--drop-client "harness-acp")

;;;; Reports

(defconst harness-ui-version-test--clone "/srv/straight/repos/harness/"
  "Where the reports say the harness was loaded from.")

(defun harness-ui-version-test--hash (char)
  "Return a commit hash made of CHAR."
  (make-string 40 char))

(defun harness-ui-version-test--commit (char subject age)
  "Return commit CHAR with SUBJECT, made AGE seconds ago."
  (list :commit (harness-ui-version-test--hash char) :subject subject :date (- (float-time) age)))

(defun harness-ui-version-test--origin (name kind status &rest props)
  "Return the origin NAME of KIND with STATUS, and PROPS, which win."
  (harness-plist-merge (list :name name :kind kind :status status
                             :location (pcase kind
                                         ("remote" "https://git.sr.ht/~catvec/emacs-agent-harness")
                                         ("loaded" harness-ui-version-test--clone)
                                         (_ "/srv/src/harness/"))
                             :branch "main")
                       props))

(defun harness-ui-version-test--report (verdict &rest origins)
  "Return a report with VERDICT on ORIGINS; the harness runs commit a."
  (list :checked (float-time) :version "3.0.0" :verdict verdict
        :running (list :directory harness-ui-version-test--clone :loaded (- (float-time) 7200)
                       :commit (harness-ui-version-test--hash ?a) :branch "main" :dirty nil
                       :subject "First" :date (- (float-time) 86400))
        :origins origins))

(defun harness-ui-version-test--loaded (&optional status)
  "Return the loaded checkout's origin, with STATUS (default same)."
  (harness-ui-version-test--origin "loaded" "loaded" (or status "same")
                                   :commit (harness-ui-version-test--hash ?a) :missing 0 :extra 0))

(defun harness-ui-version-test--newer (name kind)
  "Return origin NAME of KIND, twelve commits ahead of the harness."
  (harness-ui-version-test--origin
   name kind "newer" :commit (harness-ui-version-test--hash ?c) :subject "Third" :missing 12 :extra 0
   :missing-commits (list (harness-ui-version-test--commit ?c "Third" 3600)
                          (harness-ui-version-test--commit ?b "Second" 7200))))

(defun harness-ui-version-test--behind ()
  "Return a report finding local and sourcehut twelve commits ahead."
  (harness-ui-version-test--report "behind" (harness-ui-version-test--loaded)
                                   (harness-ui-version-test--newer "local" "local")
                                   (harness-ui-version-test--newer "sourcehut" "remote")))

;;;; The page

(defmacro harness-ui-version-test-with-page (report &rest body)
  "Draw REPORT on a version page shown in a window, and run BODY there.
The harness runs in this Emacs unless BODY binds the address."
  (declare (indent 1))
  `(let ((harness-ui-version--report ,report)
         (harness-ui-version--checking nil)
         (harness-ui-version--error nil)
         (harness-ui-version--waiting-for nil)
         (harness-ui-version--reloaded nil)
         (harness-ui-version--nag-shown nil)
         (harness-ui-connection-address nil)
         (buffer (get-buffer-create "*harness version test*")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (harness-ui-version-mode)
           (harness-ui-version--render)
           ,@body)
       (kill-buffer buffer))))

(defun harness-ui-version-test--text ()
  "Return the page's text."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun harness-ui-version-test--prose ()
  "Return the page's text with its lines joined, as filled text reads."
  (replace-regexp-in-string "[ \n]+" " " (harness-ui-version-test--text)))

(defun harness-ui-version-test--count (regexp)
  "Return how many times REGEXP matches on the page."
  (let ((text (harness-ui-version-test--text)) (start 0) (n 0))
    (while (string-match regexp text start)
      (setq n (1+ n) start (match-end 0)))
    n))

(defun harness-ui-version-test--buttons ()
  "Return the labels of the page's buttons."
  (let ((pos (point-min)) labels)
    (while (setq pos (next-button pos))
      (push (button-label (button-at pos)) labels))
    (nreverse labels)))

(defun harness-ui-version-test--header ()
  "Return the page's header line as a string."
  (apply #'concat header-line-format))

(defun harness-ui-version-test--face-of (text)
  "Return the face of TEXT's first occurrence on the page."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (get-text-property (match-beginning 0) 'face)))

(ert-deftest harness-ui-version-shows-the-commits-the-harness-lacks ()
  (harness-ui-version-test-with-page (harness-ui-version-test--behind)
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "Not the latest: local and sourcehut have commits the harness lacks\\." text))
      (should (eq 'harness-caution-face (harness-ui-version-test--face-of "Not the latest")))
      (should (string-match-p "not the latest" (harness-ui-version-test--header)))
      ;; What runs: its commit, and when it was loaded; where from is the
      ;; loaded checkout's line.
      (should (string-match-p "^ Running +aaaaaaa  First +1d ago$" text))
      (should (string-match-p "^ +loaded 2h ago$" text))
      (should (string-match-p "loaded checkout +aaaaaaa  the commit running" text))
      (should (string-match-p (concat "^ +" (regexp-quote harness-ui-version-test--clone) ", main$") text))
      (should (string-match-p "local +ccccccc  12 commits the harness lacks" text))
      (should (string-match-p "^ +/srv/src/harness/, main$" text))
      (should (string-match-p "^ +ccccccc  Third +1h ago$" text))
      (should (string-match-p "^ +bbbbbbb  Second +2h ago$" text))
      (should (string-match-p "and 10 more, merges included" text))
      ;; An origin at the same commit does not list it all again.
      (should (string-match-p "sourcehut +ccccccc  12 commits the harness lacks" text))
      (should (string-match-p "https://git.sr.ht/~catvec/emacs-agent-harness, main" text))
      (should (string-match-p "the same commits as local" text))
      (should (= 1 (harness-ui-version-test--count "Second")))
      (should (string-match-p "Checked just now; the harness checks by itself every half hour\\." text))
      (should (equal '("[Check now]") (harness-ui-version-test--buttons))))
    ;; What to do: the remote has them, so pull them into the clone.
    (should (string-match-p (concat "To run the commits of sourcehut, pull them into "
                                    (regexp-quote harness-ui-version-test--clone) ", then reload\\.")
                            (harness-ui-version-test--prose)))))

(ert-deftest harness-ui-version-draws-a-report-that-came-as-json ()
  ;; From the harness process the report comes over TCP, as JSON: nil
  ;; and empty lists come back as null, t as true.
  (let* ((report (harness-ui-version-test--report
                  "behind" (harness-ui-version-test--loaded)
                  (harness-ui-version-test--origin "local" "local" "diverged"
                                                   :commit (harness-ui-version-test--hash ?d) :dirty t
                                                   :missing 2 :extra 1 :extra-commits nil
                                                   :missing-commits (list (harness-ui-version-test--commit ?d "Fourth" 60)))
                  (harness-ui-version-test--newer "sourcehut" "remote")))
         (sent (harness-json-parse (harness-json-encode-text report)))
         (direct nil))
    (harness-ui-version-test-with-page report
      (setq direct (harness-ui-version-test--text)))
    (should (string-match-p "/srv/src/harness/, main, with uncommitted changes" direct))
    (harness-ui-version-test-with-page sent
      (should (equal direct (harness-ui-version-test--text))))))

(ert-deftest harness-ui-version-says-how-to-pull-into-straight ()
  (let ((harness-directory "/srv/straight/build-31.1/harness/"))
    (harness-ui-version-test-with-page (harness-ui-version-test--behind)
      (should (string-match-p "pull them into /srv/straight/repos/harness/ (M-x straight-pull-package RET harness), then reload\\."
                              (harness-ui-version-test--prose))))))

(ert-deftest harness-ui-version-shows-commits-not-fetched-yet ()
  ;; The repository the clone pulls from, GitHub here, has a commit no
  ;; local repository holds: the harness lacks it, uncounted.
  (let ((harness-directory "/srv/straight/build-31.1/harness/"))
    (harness-ui-version-test-with-page
        (harness-ui-version-test--report
         "behind" (harness-ui-version-test--loaded)
         (harness-ui-version-test--origin "github" "remote" "ahead" :commit (harness-ui-version-test--hash ?e)
                                          :location "https://github.com/catvec/emacs-agent-harness.git"
                                          :upstream t))
      (let ((text (harness-ui-version-test--text)))
        (should (string-match-p "Not the latest: github has commits the harness lacks\\." text))
        (should (string-match-p "github +eeeeeee  commits the harness lacks (not fetched, so not counted)" text))
        (should (eq 'harness-caution-face (harness-ui-version-test--face-of "commits the harness lacks (not")))
        (should (string-match-p (concat "^ +https://github.com/catvec/emacs-agent-harness.git, main, "
                                        "which the loaded checkout pulls from$")
                                text)))
      (should (string-match-p (concat "To run the commits of github, pull them into /srv/straight/repos/harness/ "
                                      "(M-x straight-pull-package RET harness), then reload\\.")
                              (harness-ui-version-test--prose))))))

(ert-deftest harness-ui-version-says-to-reload-a-checkout-that-moved-on ()
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "behind"
       (harness-ui-version-test--origin "loaded" "loaded" "newer" :commit (harness-ui-version-test--hash ?c)
                                        :missing 2 :extra 0
                                        :missing-commits (list (harness-ui-version-test--commit ?c "Third" 60)
                                                               (harness-ui-version-test--commit ?b "Second" 120)))
       (harness-ui-version-test--newer "sourcehut" "remote"))
    (let ((prose (harness-ui-version-test--prose)))
      (should (string-match-p "Not the latest: loaded checkout and sourcehut have commits" prose))
      (should (string-match-p "The checkout the harness was loaded from has moved on: reload to run what it holds now\\."
                              prose))
      ;; Pulling would not help: the checkout has them already.
      (should-not (string-match-p "pull them" prose)))
    (should (equal '("[Reload harness]" "[Check now]") (harness-ui-version-test--buttons)))
    (should (eq #'harness-reload
                (save-excursion (goto-char (next-button (point-min)))
                                (let ((called nil))
                                  (cl-letf (((symbol-function 'harness-reload) (lambda () (interactive) (setq called 'harness-reload))))
                                    (push-button)
                                    (and called #'harness-reload))))))
    ;; A harness elsewhere is not reloaded from here.
    (let ((harness-ui-connection-address "box:7000"))
      (harness-ui-version--render)
      (should (equal '("[Check now]") (harness-ui-version-test--buttons))))))

(ert-deftest harness-ui-version-says-to-push-what-only-a-checkout-has ()
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "behind" (harness-ui-version-test--loaded)
       (harness-ui-version-test--newer "local" "local")
       (harness-ui-version-test--origin "sourcehut" "remote" "same" :commit (harness-ui-version-test--hash ?a)
                                        :missing 0 :extra 0))
    (let ((prose (harness-ui-version-test--prose)))
      (should (string-match-p "Not the latest: local has commits the harness lacks\\." prose))
      (should (string-match-p "sourcehut aaaaaaa the commit running" prose))
      (should (string-match-p "Local has commits sourcehut lacks: push them, then pull them into /srv/straight/repos/harness/\\."
                              prose)))))

(ert-deftest harness-ui-version-says-what-it-could-not-tell ()
  ;; The latest, of every origin.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "latest" (harness-ui-version-test--loaded)
       (harness-ui-version-test--origin "local" "local" "older" :commit (harness-ui-version-test--hash ?0)
                                        :missing 0 :extra 1 :dirty t
                                        :extra-commits (list (harness-ui-version-test--commit ?a "First" 86400))))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "Running the latest: no origin has a commit the harness lacks\\." text))
      (should (eq 'harness-success-face (harness-ui-version-test--face-of "Running the latest")))
      (should (string-match-p "the latest" (harness-ui-version-test--header)))
      (should (string-match-p "local +0000000  lacks 1 commit the harness runs" text))
      (should (string-match-p "/srv/src/harness/, main, with uncommitted changes" text))
      (should (string-match-p "commits the harness runs that it lacks:\n +aaaaaaa  First" text))))
  ;; The latest of what could be read.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "latest" (harness-ui-version-test--loaded)
       (harness-ui-version-test--origin "sourcehut" "remote" "error"
                                        :error "unable to access 'https://git.sr.ht/': Could not resolve host"))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "No origin read has a commit the harness lacks, but sourcehut could not be read\\." text))
      (should (eq 'harness-caution-face (harness-ui-version-test--face-of "No origin read")))
      (should (string-match-p "sourcehut +unable to access" text))
      (should (eq 'harness-failure-face (harness-ui-version-test--face-of "unable to access")))))
  ;; A commit no local repository holds.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "unknown" (harness-ui-version-test--loaded)
       (harness-ui-version-test--origin "sourcehut" "remote" "unknown" :commit (harness-ui-version-test--hash ?f)))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "Cannot tell how sourcehut compares: no local repository holds both commits\\." text))
      (should (string-match-p "sourcehut +fffffff  no local repository holds both it and the commit running" text)))
    (should (string-match-p "cannot tell" (harness-ui-version-test--header))))
  ;; Diverged.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "behind" (harness-ui-version-test--loaded)
       (harness-ui-version-test--origin "local" "local" "diverged" :commit (harness-ui-version-test--hash ?d)
                                        :missing 2 :extra 1
                                        :missing-commits (list (harness-ui-version-test--commit ?d "Fourth" 60))))
    (should (string-match-p "local +ddddddd  diverged: 2 commits the harness lacks; it lacks 1 the harness runs"
                            (harness-ui-version-test--text))))
  ;; A harness loaded from no checkout.
  (harness-ui-version-test-with-page
      (list :checked (float-time) :version "3.0.0" :verdict "unknown"
            :running (list :directory "/srv/elpa/harness-3.0.0/" :loaded (- (float-time) 7200)
                           :error "/srv/elpa/harness-3.0.0/ is not a git checkout of its own")
            :origins (list (harness-ui-version-test--origin "sourcehut" "remote" "unknown"
                                                            :commit (harness-ui-version-test--hash ?c))))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "Cannot tell: the harness was not loaded from a git checkout (/srv/elpa/harness-3.0.0/ is not a git checkout of its own)\\." text))
      (should (string-match-p "Running +version 3.0.0, from no git checkout" text))
      (should (string-match-p "loaded 2h ago from /srv/elpa/harness-3.0.0/" text))
      (should (string-match-p "sourcehut +ccccccc  cannot be compared" text))
      (should-not (string-match-p "pull them" text)))))

(ert-deftest harness-ui-version-compares-this-emacs-with-the-harness-process ()
  (let ((harness-revision--loaded (harness-resolved (list :directory harness-ui-version-test--clone
                                                          :loaded (- (float-time) 120)
                                                          :commit (harness-ui-version-test--hash ?9)))))
    (harness-ui-version-test-with-page (harness-ui-version-test--behind)
      ;; In this Emacs: no other commit to compare.
      (should-not (string-match-p "this Emacs" (harness-ui-version-test--text)))
      (let ((harness-ui-connection-address 'process))
        (harness-ui-version--render)
        (let ((text (harness-ui-version-test--text)))
          (should (string-match-p "^ +the harness process, loaded 2h ago$" text))
          (should (string-match-p "this Emacs runs 9999999, loaded 2m ago: not the harness process's commit\\." text))
          (should (equal '("[Reload harness]" "[Check now]") (harness-ui-version-test--buttons)))))
      ;; A harness elsewhere: this Emacs cannot reload it.
      (let ((harness-ui-connection-address "box:7000"))
        (harness-ui-version--render)
        (should (string-match-p "this Emacs runs 9999999" (harness-ui-version-test--text)))
        (should (equal '("[Check now]") (harness-ui-version-test--buttons))))
      (let ((harness-ui-connection-address 'process)
            (harness-revision--loaded (harness-resolved (list :loaded (- (float-time) 120)
                                                              :commit (harness-ui-version-test--hash ?a)))))
        (harness-ui-version--render)
        (should (string-match-p "this Emacs: the same commit, loaded 2m ago" (harness-ui-version-test--text))))
      ;; Not known yet: the page draws without it, and again once it is.
      (let* ((harness-ui-connection-address 'process)
             (pending (harness-make-promise))
             (harness-revision--loaded pending))
        (harness-ui-version--render)
        (should-not (string-match-p "this Emacs" (harness-ui-version-test--text)))
        (harness-resolve pending (list :loaded (float-time) :commit (harness-ui-version-test--hash ?a)))
        (should (string-match-p "this Emacs: the same commit, loaded just now" (harness-ui-version-test--text)))))))

(ert-deftest harness-ui-version-follows-the-harness ()
  (let ((requests nil)
        (answer nil))
    (cl-letf (((symbol-function 'harness-ui-request)
               (lambda (method params)
                 (push (list method params) requests)
                 (setq answer (harness-make-promise)))))
      (harness-ui-version-test-with-page nil
        ;; No report yet.
        (should (string-match-p "Checking the running harness against its origins…" (harness-ui-version-test--text)))
        (should (equal "Version" (harness-ui-version-menu-label)))
        ;; A report the harness announces is drawn as it comes.
        (harness-ui-version--on-event "version/checked" (list (harness-ui-version-test--behind)))
        (should (string-match-p "Not the latest" (harness-ui-version-test--text)))
        (should (equal "Version (not the latest)" (substring-no-properties (harness-ui-version-menu-label))))
        (harness-ui-version--on-event "session/created" (list "s1"))
        (should (string-match-p "Not the latest" (harness-ui-version-test--text)))
        ;; g asks for a check, once however often it is pressed.
        (execute-kbd-macro (kbd "g"))
        (execute-kbd-macro (kbd "g"))
        (should (equal '(("_harness/version/check" (:max-age 0))) requests))
        (should (string-match-p "checking" (harness-ui-version-test--header)))
        (should-not (member "[Check now]" (harness-ui-version-test--buttons)))
        (harness-resolve answer (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded)))
        (should (string-match-p "Running the latest" (harness-ui-version-test--text)))
        (should (equal "Version" (harness-ui-version-menu-label)))
        ;; A failed check is said, under the last report.
        (harness-ui-version-refresh)
        (harness-reject answer '(harness-error "the harness is busy"))
        (should (string-match-p "Running the latest" (harness-ui-version-test--text)))
        (should (string-match-p "The last check failed: the harness is busy" (harness-ui-version-test--text)))
        ;; Another harness: its report is asked for, the old one forgotten.
        (setq requests nil)
        (harness-ui-version--on-connected)
        (should (equal '(("_harness/version/check" (:max-age 60))) requests))
        (should (string-match-p "Checking the running harness" (harness-ui-version-test--text)))
        (harness-reject answer '(harness-error "no such method"))
        (should (string-match-p "The check failed: no such method" (harness-ui-version-test--text)))))))

(ert-deftest harness-ui-version-page-keys ()
  (should (eq #'harness-ui-version-refresh (lookup-key harness-ui-version-mode-map (kbd "g"))))
  (should (eq #'harness-menu (lookup-key harness-ui-version-mode-map (kbd "?"))))
  (should (eq #'forward-button (lookup-key harness-ui-version-mode-map (kbd "TAB"))))
  (should (eq #'quit-window (lookup-key harness-ui-version-mode-map (kbd "q"))))
  (should (equal "Version" (car (get 'harness-ui-version-mode 'harness-menu-group)))))

;;;; The nag icon

(defmacro harness-ui-version-test-with-nag (report &rest body)
  "Run BODY with REPORT the last report and the nag icon in all its places.
No page shows.  The mode line notifier is on, with no session active."
  (declare (indent 1))
  `(let ((harness-ui-version--report ,report)
         (harness-ui-version--checking nil)
         (harness-ui-version--error nil)
         (harness-ui-version--waiting-for nil)
         (harness-ui-version--reloaded nil)
         (harness-ui-version--nag-shown nil)
         (harness-ui-version-nag-places '(mode-line chat-header board-header))
         (harness-chat-header-end-functions nil)
         (harness-ui-tasks-header-functions nil)
         (harness-ui-notify-segment-functions nil)
         (harness-notify-mode t)
         (harness-ui-notify--string "")
         (harness-ui--sessions (make-hash-table :test 'equal)))
     (harness-ui-version--init-nag)
     ,@body))

(defun harness-ui-version-test--icon ()
  "The nag icon's text, as it reads in batch: its symbol fallback."
  (substring-no-properties (harness-ui-icon 'harness-icon-update)))

(defun harness-ui-version-test--places ()
  "Where the nag icon shows now: a list of mode-line, chat-header, board-header."
  (let ((icon (regexp-quote (harness-ui-version-test--icon))))
    (append
     (and (string-match-p (concat "\\` harness " icon " \\'") harness-ui-notify--string)
          '(mode-line))
     (and (string-match-p (concat "  " icon "  \\[menu\\]")
                          (with-temp-buffer (harness-chat--header most-positive-fixnum)))
          '(chat-header))
     (and (string-match-p (concat "  " icon "  \\[BTW\\]")
                          (with-temp-buffer (harness-ui-tasks--header most-positive-fixnum)))
          '(board-header)))))

(ert-deftest harness-ui-version-nag-icon ()
  "While the harness is behind, the icon nags; hovering says why, a click shows the page."
  (harness-ui-version-test-with-nag (harness-ui-version-test--behind)
    (let ((nag (harness-ui-version-nag))
          (shown 0))
      (should (equal (harness-ui-version-test--icon) nag))
      (should (eq 'harness-caution-face (get-text-property 0 'face nag)))
      ;; An image with `mouse-face' shows as a box.
      (should-not (get-text-property 0 'mouse-face nag))
      (should (equal "The harness is not the latest: local and sourcehut have commits it lacks (mouse-1: what to do)"
                     (funcall (get-text-property 0 'help-echo nag) nil nil 0)))
      (cl-letf (((symbol-function 'harness-version) (lambda () (interactive) (cl-incf shown))))
        (dolist (key (list [header-line mouse-1] [mode-line mouse-1] [mouse-1] (kbd "RET")))
          (funcall (lookup-key (get-text-property 0 'local-map nag) key))))
      (should (= 4 shown)))
    ;; One origin with commits the harness lacks.
    (setq harness-ui-version--report
          (harness-ui-version-test--report "behind" (harness-ui-version-test--loaded)
                                           (harness-ui-version-test--newer "sourcehut" "remote")))
    (should (equal "The harness is not the latest: sourcehut has commits it lacks (mouse-1: what to do)"
                   (harness-ui-version--nag-help)))))

(ert-deftest harness-ui-version-nags-only-while-behind ()
  (dolist (report (list nil
                        (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded))
                        (harness-ui-version-test--report
                         "unknown" (harness-ui-version-test--loaded)
                         (harness-ui-version-test--origin "sourcehut" "remote" "unknown"))))
    (harness-ui-version-test-with-nag report
      (should-not (harness-ui-version-nag))
      (harness-ui-notify-refresh)
      (should-not (harness-ui-version-test--places))
      ;; The notifier has nothing to show either.
      (should (equal "" harness-ui-notify--string)))))

(ert-deftest harness-ui-version-nags-in-every-place ()
  "The icon shows in the notifier, a chat's header before [menu], and the board's."
  (harness-ui-version-test-with-nag nil
    (harness-ui-notify-refresh)
    (should-not (harness-ui-version-test--places))
    ;; A report finding the harness behind: the icon shows at once, the
    ;; notifier too though no session is active.
    (harness-ui-version--on-event "version/checked" (list (harness-ui-version-test--behind)))
    (should (equal '(mode-line chat-header board-header) (harness-ui-version-test--places)))
    (should (equal "Version (not the latest)" (substring-no-properties (harness-ui-version-menu-label))))
    ;; In a narrow chat it makes room after the spend, before the name.
    (with-temp-buffer
      (let* ((full (harness-chat--header most-positive-fixnum))
             (gone (lambda (regexp)
                     ;; The widest header without REGEXP.
                     (cl-loop for width downfrom (harness-ui-header-string-width full) to 1
                              unless (string-match-p regexp (harness-chat--header width))
                              return width))))
        (should (> (funcall gone "\\$0")
                   (funcall gone (regexp-quote (harness-ui-version-test--icon)))
                   (funcall gone "unnamed")))))
    ;; With sessions, it shows before their counts.
    (puthash "s1" '(:session-id "s1" :status "running") harness-ui--sessions)
    (harness-ui-notify-refresh)
    (should (string-match-p (concat "\\` harness " (regexp-quote (harness-ui-version-test--icon)) " .+1 \\'")
                            harness-ui-notify--string))
    (clrhash harness-ui--sessions)
    ;; A report finding it the latest: the icon goes.
    (harness-ui-version--on-event "version/checked"
                                  (list (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded))))
    (should-not (harness-ui-version-test--places))
    (should (equal "" harness-ui-notify--string))
    (should (equal "Version" (harness-ui-version-menu-label)))))

(ert-deftest harness-ui-version-nag-goes-when-the-harness-reloads ()
  "The harness may run the commits it lacked once it reloads: the icon goes until it checks again."
  (harness-ui-version-test-with-nag nil
    (harness-ui-version--on-event "version/checked" (list (harness-ui-version-test--behind)))
    (should (equal '(mode-line chat-header board-header) (harness-ui-version-test--places)))
    (harness-ui-version--on-event "harness/reloaded" nil)
    (should-not (harness-ui-version-nag))
    (should-not (harness-ui-version-test--places))
    (should (equal "" harness-ui-notify--string))
    (should (equal "Version" (harness-ui-version-menu-label)))
    ;; The check after the reload still finds it behind: back it comes.
    (harness-ui-version--on-event "version/checked" (list (harness-ui-version-test--behind)))
    (should (equal '(mode-line chat-header board-header) (harness-ui-version-test--places)))))

(ert-deftest harness-ui-version-nag-places ()
  (harness-ui-version-test-with-nag (harness-ui-version-test--behind)
    (dolist (places '((mode-line) (chat-header) (board-header) (chat-header board-header)))
      (setq harness-ui-version-nag-places places)
      (harness-ui-version--nag-changed t)
      (should (equal places (harness-ui-version-test--places))))
    ;; Nowhere: the harness menu still says so.
    (setq harness-ui-version-nag-places nil)
    (harness-ui-version--nag-changed t)
    (should-not (harness-ui-version-test--places))
    (should (equal "" harness-ui-notify--string))
    (should (equal "Version (not the latest)" (substring-no-properties (harness-ui-version-menu-label))))))

(ert-deftest harness-ui-version-nag-on-connecting ()
  "A UI connecting asks the harness for its last report, which checks nothing."
  (let ((requests nil)
        (answer nil))
    (cl-letf (((symbol-function 'harness-ui-request)
               (lambda (method params)
                 (push (list method params) requests)
                 (setq answer (harness-make-promise)))))
      (harness-ui-version-test-with-nag (harness-ui-version-test--behind)
        ;; Another harness: the last one's report is forgotten, with its icon.
        (harness-ui-version--on-connected)
        (should (equal '(("_harness/version/report" nil)) requests))
        (should-not (harness-ui-version-test--places))
        (harness-resolve answer (harness-ui-version-test--behind))
        (should (equal '(mode-line chat-header board-header) (harness-ui-version-test--places)))
        ;; A harness that has not checked yet answers nil: the icon waits.
        (harness-ui-version--on-connected)
        (harness-resolve answer nil)
        (should-not harness-ui-version--report)
        (should-not (harness-ui-version-test--places))
        ;; A report announced before the answer is newer than it.
        (harness-ui-version--on-connected)
        (harness-ui-version--on-event "version/checked"
                                      (list (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded))))
        (harness-resolve answer (harness-ui-version-test--behind))
        (should (equal "latest" (plist-get harness-ui-version--report :verdict)))
        (should-not (harness-ui-version-test--places))
        ;; A harness without `version/report': nothing to show, nothing said.
        (harness-ui-version--on-connected)
        (harness-reject answer '(harness-error "no such method"))
        (should-not harness-ui-version--error)
        (should-not (harness-ui-version-test--places))))))

(ert-deftest harness-ui-version-nag-wiring ()
  "The module adds the icon's hooks as it starts, and takes them away as it stops."
  (let ((requests nil)
        (harness-ui-event-functions nil)
        (harness-ui-redraw-hook nil)
        (harness-ui-connected-hook nil)
        (harness-ui-map (make-sparse-keymap)))
    (cl-letf (((symbol-function 'harness-ui-request)
               (lambda (method params)
                 (push (list method params) requests)
                 (harness-resolved (harness-ui-version-test--behind))))
              ((symbol-function 'harness-ui-connected-p) (lambda () t)))
      (harness-ui-version-test-with-nag nil
        (setq harness-chat-header-end-functions nil
              harness-ui-tasks-header-functions nil
              harness-ui-notify-segment-functions nil)
        ;; Started while connected: it asks for the last report.
        (harness-ui-version--init)
        (should (equal '(("_harness/version/report" nil)) requests))
        (should (memq #'harness-ui-version--chat-header harness-chat-header-end-functions))
        (should (memq #'harness-ui-version--board-header harness-ui-tasks-header-functions))
        (should (memq #'harness-ui-version--notify-segment harness-ui-notify-segment-functions))
        (should (memq #'harness-ui-version--on-event harness-ui-event-functions))
        (should (equal '(mode-line chat-header board-header) (harness-ui-version-test--places)))
        (harness-ui-version--shutdown)
        (should-not harness-chat-header-end-functions)
        (should-not harness-ui-tasks-header-functions)
        (should-not harness-ui-notify-segment-functions)
        (should-not harness-ui-event-functions)
        (should-not harness-ui-version--report)
        (should (equal "" harness-ui-notify--string))))))

;;;; The whole way

(defun harness-ui-version-test--git (dir &rest args)
  "Run git ARGS in DIR and return its output, trimmed; signal on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" (string-join args " ") (buffer-string)))
      (string-trim (buffer-string)))))

(defun harness-ui-version-test--commit-in (dir subject)
  "Commit a change with SUBJECT in DIR."
  (with-temp-file (expand-file-name "CHANGES" dir) (insert subject "\n"))
  (harness-ui-version-test--git dir "add" "-A")
  (harness-ui-version-test--git dir "commit" "-q" "-m" subject))

(defun harness-ui-version-test--repositories (base)
  "Make an upstream harness in BASE and a clone of it; return (UPSTREAM . CLONE).
The clone is made from a file:// URL, as straight.el clones from the
recipe's, so its main tracks that URL."
  (let ((upstream (file-name-as-directory (expand-file-name "upstream" base)))
        (clone (file-name-as-directory (expand-file-name "clone" base))))
    (make-directory (expand-file-name "lisp" upstream) t)
    (harness-ui-version-test--git upstream "init" "-q" "-b" "main")
    (harness-ui-version-test--git upstream "config" "user.name" "Harness Test")
    (harness-ui-version-test--git upstream "config" "user.email" "test@example.invalid")
    (harness-ui-version-test--git upstream "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "harness.el" upstream) (insert ";; a harness\n"))
    (with-temp-file (expand-file-name "lisp/harness-core.el" upstream) (insert ";; its core\n"))
    (harness-ui-version-test--commit-in upstream "first")
    (harness-ui-version-test--git base "clone" "-q" (concat "file://" (directory-file-name upstream)) clone)
    (cons upstream clone)))

(ert-deftest harness-ui-version-asks-the-harness-over-acp ()
  (skip-unless (executable-find "git"))
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (let ((harness-acp--server-enabled nil))
      (dolist (m '(acp ui version ui-version)) (harness-test-load-module m)))
    (let* ((base (harness-test-temp-dir))
           (repos (harness-ui-version-test--repositories base))
           (upstream (car repos))
           (harness-directory (cdr repos))
           (harness-revision--loaded nil)
           ;; The repository the clone pulls from is found by itself.
           ;; The upstream's own checkout holds both commits: the commits
           ;; are related there, as in a development checkout.
           (harness-version-origins (list (list :name "dev" :location upstream)))
           (harness-ui-version--report nil)
           (harness-ui-version--checking nil)
           (harness-ui-version--error nil)
           (harness-ui-version--waiting-for nil)
           (harness-ui-version--reloaded nil)
           (harness-ui-version--nag-shown nil)
           (page nil))
      (cl-flet ((wait-for (regexp)
                  (harness-test-wait (lambda ()
                                       (and (not (harness-ui-version--checking-p))
                                            (string-match-p regexp (with-current-buffer page
                                                                     (harness-ui-version-test--prose)))))
                                     30 regexp)))
        (unwind-protect
            (save-window-excursion
              (should (eq #'harness-version (lookup-key harness-ui-map (kbd "v"))))
              (harness-ui-version-test--commit-in upstream "second")
              (harness-version)
              (setq page (get-buffer harness-ui-version--buffer-name))
              (wait-for "Not the latest: dev and upstream have commits the harness lacks\\.")
              (with-current-buffer page
                (should (string-match-p "upstream +[0-9a-f]\\{7\\}  1 commit the harness lacks"
                                        (harness-ui-version-test--text)))
                (should (string-match-p (concat "^ +file://" (regexp-quote (directory-file-name upstream))
                                                ", main, which the loaded checkout pulls from$")
                                        (harness-ui-version-test--text)))
                (should (string-match-p "  second  " (harness-ui-version-test--text))))
              ;; The icon nags.  A UI connecting now is given the report
              ;; as it is.
              (should (harness-ui-version-nag))
              (let ((harness-ui-version--report nil))
                (harness-ui-version--fetch)
                (harness-test-wait (lambda () harness-ui-version--report) 10 "the last report")
                (should (equal "behind" (plist-get harness-ui-version--report :verdict)))
                (should (harness-ui-version-nag)))
              ;; A check the harness makes by itself reaches the page.
              (harness-ui-version-test--commit-in upstream "third")
              (harness-call 'version/check 0)
              (wait-for "upstream [0-9a-f]\\{7\\} 2 commits the harness lacks .* the same commits as dev")
              ;; So does one the page asks for.
              (harness-ui-version-test--commit-in upstream "fourth")
              (with-current-buffer page
                (goto-char (point-min))
                (search-forward "[Check now]")
                (push-button (match-beginning 0)))
              (wait-for "upstream [0-9a-f]\\{7\\} 3 commits the harness lacks"))
          (when page (kill-buffer page))
          (harness-modules-shutdown)
          (dolist (c (copy-sequence harness-acp--clients)) (harness-acp--drop-client c))
          (delete-directory base t))))))

(provide 'harness-ui-version-test)
;;; harness-ui-version-test.el ends here
