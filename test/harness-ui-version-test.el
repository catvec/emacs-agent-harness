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
;; straight.el's caches are special variables; these tests bind them
;; without loading straight.el.
(defvar straight--recipe-cache)
(defvar straight--repo-cache)
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
                             :branch "main"
                             ;; A remote fixture is the repository the
                             ;; checkout pulls from unless a test says
                             ;; otherwise.
                             :upstream (and (equal kind "remote") t))
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
         (harness--last-update nil)
         (harness--updating nil)
         (harness-ui-connection-address nil)
         (buffer (get-buffer-create "*harness version test*")))
     (unwind-protect
         ;; A wide page: what a row says is under test, not how it
         ;; elides at the width batch's frame happens to have.
         (cl-letf (((symbol-function 'harness-ui-version--width) (lambda () 120)))
           (save-window-excursion
             (switch-to-buffer buffer)
             (harness-ui-version-mode)
             (harness-ui-version--render)
             ,@body))
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

;;;; The page

(defun harness-ui-version-test--plugin (name version status &rest props)
  "Return a plugin called NAME, VERSION and STATUS, with PROPS."
  (harness-plist-merge
   (list :name name :version version :status status
         :directory (concat "/srv/straight/repos/harness/lisp/vendor/" name)
         :checkout harness-ui-version-test--clone)
   props))

(defun harness-ui-version-test--with-plugins (verdict plugins &rest origins)
  "Return a report with VERDICT on ORIGINS and PLUGINS."
  (harness-plist-merge (apply #'harness-ui-version-test--report verdict origins)
                       (list :plugins plugins)))

(defun harness-ui-version-test--line (regexp)
  "Return the line of the page matching REGEXP, without properties."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward regexp nil t)
      (buffer-substring-no-properties (line-beginning-position) (line-end-position)))))

(ert-deftest harness-ui-version-shows-one-row-per-origin ()
  "Running, the checkout and the remote have a row each, actions beside them.
A development checkout with unpushed commits has a row of its own, and
the commits the harness lacks are the change-log messages under them."
  (harness-ui-version-test-with-page (harness-ui-version-test--behind)
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "^ ● Not latest$" text))
      (should (string-match-p "^ Running +aaaaaaa  First +1d ago$" text))
      (should (string-match-p (concat "^ Checkout +● aaaaaaa  current +\\[Reload\\] +"
                                      (regexp-quote (directory-file-name harness-ui-version-test--clone)))
                              text))
      (should (string-match-p (concat "^ Remote +● ccccccc  12 commits to pull +\\[Update\\] +"
                                      "https://git.sr.ht/~catvec/emacs-agent-harness")
                              text))
      (should (string-match-p "^ Recent commits$" text))
      (should (string-match-p "^ +ccccccc  Third +1h ago$" text))
      (should (string-match-p "^ +bbbbbbb  Second +2h ago$" text))
      (should (string-match-p "and 10 more" text))
      (should (string-match-p "^ Development$" text))
      (should (string-match-p "^ harness +● ccccccc  12 commits to push +/srv/src/harness" text))
      ;; One listing of the commits, under the remote row.
      (should (= 1 (harness-ui-version-test--count "Third")))
      (should (equal '("[Reload]" "[Update]" "[Check now]")
                     (harness-ui-version-test--buttons)))
      ;; The header line is the version and the verdict, nothing more.
      (should (string-match-p "Harness 3\\.0\\.0 Not latest" (harness-ui-version-test--header))))
    (should (eq 'harness-caution-face (harness-ui-version-test--face-of "Not latest")))))

(ert-deftest harness-ui-version-copy-is-nouns-and-imperatives ()
  "The page says what and does, not why: statuses and actions, no sentences."
  (harness-ui-version-test-with-page (harness-ui-version-test--behind)
    (let ((text (harness-ui-version-test--text)))
      (dolist (sentence '("The checkout the harness was loaded from has moved on"
                          "the harness checks by itself"
                          "To run the commits"
                          "push them, then pull them"
                          "Running the latest:"))
        (should-not (string-match-p (regexp-quote sentence) text)))
      (dolist (line (split-string text "\n" t))
        (should-not (string-match-p "\\.\\'" (string-trim line)))))))

(ert-deftest harness-ui-version-changelog-has-no-file-stats ()
  "A commit is its change-log message: file statistics are not shown."
  (let ((report (harness-ui-version-test--report
                 "behind" (harness-ui-version-test--loaded)
                 (harness-ui-version-test--origin
                  "sourcehut" "remote" "newer"
                  :commit (harness-ui-version-test--hash ?c) :missing 1 :extra 0
                  :missing-commits
                  (list (list :commit (harness-ui-version-test--hash ?c) :subject "Third"
                              :date (- (float-time) 60)
                              :body (concat "Changes:\n- Say 3.0.1\n- Add nothing else\n"
                                            "8 files changed, 196 insertions(+), 44 deletions(-)\n"
                                            "3 deletions(-)")))))))
    (harness-ui-version-test-with-page report
      (let ((text (harness-ui-version-test--text)))
        (should (string-match-p "Changes:" text))
        (should (string-match-p "- Say 3\\.0\\.1" text))
        (should (string-match-p "- Add nothing else" text))
        (should-not (string-match-p "files changed" text))
        (should-not (string-match-p "insertions" text))
        (should-not (string-match-p "deletions" text))))))

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
    (should (string-match-p "(main, uncommitted)" direct))
    (harness-ui-version-test-with-page sent
      (should (equal direct (harness-ui-version-test--text))))))

(ert-deftest harness-ui-version-narrow-page-keeps-its-actions ()
  "At a narrow width the rows still show whole buttons, and fit the window.
Where they are is cut first; the action that changes a status is never
cut, and no line is wider than the window."
  (harness-ui-version-test-with-page (harness-ui-version-test--behind)
    (cl-letf (((symbol-function 'harness-ui-version--width) (lambda () 60)))
      (harness-ui-version--render)
      (let ((text (harness-ui-version-test--text)))
        (should (member "[Reload]" (harness-ui-version-test--buttons)))
        (should (member "[Update]" (harness-ui-version-test--buttons)))
        (should (string-match-p "\[Reload\][ ]*\n" text))
        (should (string-match-p "\[Update\][ ]*\n" text))
        (dolist (line (split-string text "\n"))
          (should (<= (length line) 60)))))))

(ert-deftest harness-ui-version-actions-sit-on-the-rows-they-change ()
  "Reload is on the checkout's row, Update on the remote's; both work."
  (harness-ui-version-test-with-page (harness-ui-version-test--behind)
    ;; The buttons of a row are on its line.
    (should (string-match-p "\\[Reload\\]"
                            (harness-ui-version-test--line "^ Checkout")))
    (should (string-match-p "\\[Update\\]"
                            (harness-ui-version-test--line "^ Remote")))
    ;; And they run what they say.
    (let ((reloaded 0) (updated 0))
      (cl-letf (((symbol-function 'harness-reload) (lambda () (interactive) (cl-incf reloaded)))
                ((symbol-function 'harness-update) (lambda () (interactive) (cl-incf updated))))
        (save-excursion
          (goto-char (point-min))
          (search-forward "[Reload]")
          (push-button (match-beginning 0)))
        (should (= 1 reloaded))
        (save-excursion
          (goto-char (point-min))
          (search-forward "[Update]")
          (push-button (match-beginning 0)))
        (should (= 1 updated))
        (harness-ui-version-update)
        (should (= 2 updated))
        ;; While it runs, no second update is offered.
        (let ((harness--updating t))
          (harness-ui-version--render)
          (should-not (member "[Update]" (harness-ui-version-test--buttons)))
          (should-not (member "[Reload]" (harness-ui-version-test--buttons)))
          (should (string-match-p "Updating…" (harness-ui-version-test--text))))))
    ;; A harness elsewhere is updated where it runs: no row actions here.
    (let ((harness-ui-connection-address "box:7000"))
      (harness-ui-version--render)
      (should (equal '("[Check now]") (harness-ui-version-test--buttons)))
      (should-error (harness-ui-version-update) :type 'user-error))))

(ert-deftest harness-ui-version-shows-commits-not-fetched-yet ()
  "A remote commit no local repository holds is not counted, and is said."
  (let ((report (harness-ui-version-test--report
                 "behind" (harness-ui-version-test--loaded)
                 (harness-ui-version-test--origin "github" "remote" "ahead"
                                                  :commit (harness-ui-version-test--hash ?e)
                                                  :location "https://github.com/catvec/emacs-agent-harness.git"))))
    (harness-ui-version-test-with-page report
      (let ((text (harness-ui-version-test--text)))
        (should (string-match-p "Not latest" text))
        (should (string-match-p "^ Remote +● eeeeeee  not fetched +\\[Update\\]" text))
        (should (string-match-p "https://github.com/catvec/emacs-agent-harness.git" text))
        (should-not (string-match-p "Recent commits" text)))
      (should (member "[Update]" (harness-ui-version-test--buttons))))))

(ert-deftest harness-ui-version-reloads-a-checkout-that-moved-on ()
  "A checkout ahead of the running commit says so, with Reload beside it."
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "behind"
       (harness-ui-version-test--origin "loaded" "loaded" "newer"
                                        :commit (harness-ui-version-test--hash ?c)
                                        :missing 2 :extra 0
                                        :missing-commits
                                        (list (harness-ui-version-test--commit ?c "Third" 60)
                                              (harness-ui-version-test--commit ?b "Second" 120)))
       (harness-ui-version-test--origin "sourcehut" "remote" "same"
                                        :commit (harness-ui-version-test--hash ?c)
                                        :missing 0 :extra 0))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "^ Checkout +● ccccccc  2 commits to load +\\[Reload\\]" text))
      (should (string-match-p "^ Remote +● ccccccc  current +\\[Update\\]" text))
      (should (string-match-p "Recent commits" text)))
    (should (equal '("[Reload]" "[Update]" "[Check now]")
                   (harness-ui-version-test--buttons)))
    (let ((called 0))
      (cl-letf (((symbol-function 'harness-reload) (lambda () (interactive) (cl-incf called))))
        (save-excursion
          (goto-char (point-min))
          (search-forward "[Reload]")
          (push-button (match-beginning 0)))
        (should (= 1 called))))))

(ert-deftest harness-ui-version-a-development-checkout-does-not-make-it-behind ()
  "Only the loaded checkout and its remote decide the verdict.
A development checkout with commits the remote lacks is shown, with
what to push, but the running harness is the latest it can run."
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "latest" (harness-ui-version-test--loaded)
       (harness-ui-version-test--newer "local" "local")
       (harness-ui-version-test--origin "sourcehut" "remote" "same"
                                        :commit (harness-ui-version-test--hash ?a)
                                        :missing 0 :extra 0))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "^ ● Latest$" text))
      (should (string-match-p "^ harness +● ccccccc  12 commits to push" text))
      (should (string-match-p "^ Remote +● aaaaaaa  current +\\[Update\\]" text))
      (should-not (string-match-p "Not latest" text)))
    (should-not (harness-ui-version-behind-p))))

(ert-deftest harness-ui-version-says-what-it-could-not-tell ()
  "Unknown is its own status, not a verdict of latest or behind."
  ;; A development checkout older than the running harness.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "latest" (harness-ui-version-test--loaded)
       (harness-ui-version-test--origin "local" "local" "older"
                                        :commit (harness-ui-version-test--hash ?0)
                                        :missing 0 :extra 1 :dirty t
                                        :extra-commits
                                        (list (harness-ui-version-test--commit ?a "First" 86400))))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "Latest" text))
      (should (string-match-p "^ harness +● 0000000  1 commit ahead" text))
      (should (string-match-p "(main, uncommitted)" text))))
  ;; A remote that could not be read, and no commit to compare.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "unknown" (harness-ui-version-test--loaded)
       (harness-ui-version-test--origin "sourcehut" "remote" "error"
                                        :error "unable to access 'https://git.sr.ht/': Could not resolve host"))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "● Unknown" text))
      (should (string-match-p "^ Remote +[▲●] +unable to access" text))
      (should (eq 'harness-failure-face
                  (harness-ui-version-test--face-of "unable to access")))))
  ;; A commit no local repository holds.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "unknown" (harness-ui-version-test--loaded)
       (harness-ui-version-test--origin "sourcehut" "remote" "unknown"
                                        :commit (harness-ui-version-test--hash ?f)))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "● Unknown" text))
      (should (string-match-p "^ Remote +● fffffff  unknown" text))))
  ;; Diverged.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report
       "behind" (harness-ui-version-test--loaded)
       (harness-ui-version-test--origin "local" "local" "diverged"
                                        :commit (harness-ui-version-test--hash ?d)
                                        :missing 2 :extra 1
                                        :missing-commits
                                        (list (harness-ui-version-test--commit ?d "Fourth" 60))))
    (should (string-match-p "^ harness +● ddddddd  2 commits to pull, 1 to push"
                            (harness-ui-version-test--text))))
  ;; A harness loaded from no checkout.
  (harness-ui-version-test-with-page
      (list :checked (float-time) :version "3.0.0" :verdict "unknown"
            :running (list :directory "/srv/elpa/harness-3.0.0/" :loaded (- (float-time) 7200)
                           :error "/srv/elpa/harness-3.0.0/ is not a git checkout of its own")
            :origins (list (harness-ui-version-test--origin
                            "sourcehut" "remote" "unknown"
                            :commit (harness-ui-version-test--hash ?c))))
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "Running +version 3\\.0\\.0, no git checkout" text))
      (should (string-match-p "Checkout +● +no git checkout" text))
      ;; Nothing to update or reload from here.
      (should (equal '("[Check now]") (harness-ui-version-test--buttons)))))
  ;; No report yet.
  (harness-ui-version-test-with-page nil
    (should (string-match-p "Checking…" (harness-ui-version-test--text)))
    (should (equal '("[Check now]") (harness-ui-version-test--buttons)))))

(ert-deftest harness-ui-version-shows-plugins ()
  "Each plugin has a version, a status and the action that updates it.
A plugin in the harness's checkout is updated with the harness; one in
another checkout through `harness-update-plugin'."
  (let* ((report (harness-ui-version-test--with-plugins
                  "latest"
                  (list (harness-ui-version-test--plugin "change-review" "0.1.0" "same")
                        (harness-ui-version-test--plugin "compose-quote" "0.1.0" "newer" :missing 1)
                        (harness-ui-version-test--plugin "worktree-assume" nil "ahead"
                                                         :commit (harness-ui-version-test--hash ?e)))
                  (harness-ui-version-test--loaded)
                  (harness-ui-version-test--origin "sourcehut" "remote" "same"
                                                   :commit (harness-ui-version-test--hash ?a)
                                                   :missing 0 :extra 0)))
         (other (harness-ui-version-test--plugin
                 "deploy" "2.0.0" "newer" :missing 2
                 :directory "/srv/deploy/.harness/plugins/deploy"
                 :checkout "/srv/deploy/")))
    (harness-ui-version-test-with-page
        (harness-plist-merge report (list :plugins (append (plist-get report :plugins)
                                                           (list other))))
      (let ((text (harness-ui-version-test--text)))
        (should (string-match-p "^ Plugins$" text))
        (should (string-match-p "^ change-review +● 0\\.1\\.0 +current +\\[Update\\]" text))
        (should (string-match-p "^ compose-quote +● 0\\.1\\.0 +1 commit to pull +\\[Update\\]" text))
        (should (string-match-p "^ worktree-assume +● eeeeeee +not fetched +\\[Update\\]" text))
        (should (string-match-p "^ deploy +● 2\\.0\\.0 +2 commits to pull +\\[Update\\]" text)))
      (let ((harness-updates 0) (plugins nil))
        (cl-letf (((symbol-function 'harness-update)
                   (lambda () (interactive) (cl-incf harness-updates)))
                  ((symbol-function 'harness-update-plugin)
                   (lambda (dir name) (push (list dir name) plugins))))
          ;; A plugin in the harness's checkout is updated with the harness.
          (save-excursion
            (goto-char (point-min))
            (search-forward "change-review")
            (search-forward "[Update]")
            (push-button (match-beginning 0)))
          (should (= 1 harness-updates))
          (should-not plugins)
          ;; The deploy plugin is fast-forwarded in its own checkout.
          (save-excursion
            (goto-char (point-min))
            (search-forward " deploy ")
            (search-forward "[Update]")
            (push-button (match-beginning 0)))
          (should (equal '(("/srv/deploy/.harness/plugins/deploy" "deploy")) plugins)))))))

(ert-deftest harness-ui-version-updates-a-straight-install-from-the-page ()
  "A straight.el install is updated from the page, package and all.
straight's repos clone, which `harness-directory' really is (its build
directory is a tree of links into it), counts as much as its build."
  (dolist (dir '("/srv/straight/repos/harness/" "/srv/straight/build-31.1/harness/"))
    (let ((harness-directory dir))
      (should (equal "harness" (harness--straight-package)))
      (should (equal "harness" (harness-ui-version--straight-package)))
      (harness-ui-version-test-with-page (harness-ui-version-test--behind)
        (should (member "[Update]" (harness-ui-version-test--buttons)))))))

(ert-deftest harness-ui-version-names-the-package-straight-registered ()
  "The package is the one straight.el registered, not the clone's directory.
The clone emacs-agent-harness/ keeps package `harness': M-x
straight-pull-package RET emacs-agent-harness would find no package."
  (let ((harness-directory "/srv/straight/repos/emacs-agent-harness/")
        (straight--recipe-cache (make-hash-table :test #'equal))
        (straight--repo-cache (make-hash-table :test #'equal)))
    (let ((recipe (list :package "harness" :local-repo "emacs-agent-harness" :type 'git)))
      (puthash "harness" recipe straight--recipe-cache)
      (puthash "emacs-agent-harness" recipe straight--repo-cache))
    (should (equal "harness" (harness-ui-version--straight-package)))
    ;; straight.el has no recipe for this clone: no package to name.
    (clrhash straight--recipe-cache)
    (clrhash straight--repo-cache)
    (should-not (harness-ui-version--straight-package))))

(ert-deftest harness-ui-version-shows-what-an-update-brought ()
  "The last update's outcome and the commits it brought, with bodies."
  (let ((result (list :state "updated"
                      :from "aaaaaaa" :to "bbbbbbb"
                      :at (- (float-time) 60)
                      :message "Harness updated from aaaaaaa to bbbbbbb (2 commits) and reloaded"
                      :count 2
                      :commits (list (list :commit (harness-ui-version-test--hash ?b)
                                           :subject "Second"
                                           :date (- (float-time) 60)
                                           :body "Why it was done.\n\nHow it was done.")
                                     (list :commit (harness-ui-version-test--hash ?a)
                                           :subject "First"
                                           :date (- (float-time) 120)
                                           :body "A first body.\n2 files changed, 3 insertions(+)")))))
    (harness-ui-version-test-with-page
        (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded))
      (setq harness--last-update result)
      (harness-ui-version--render)
      (let ((text (harness-ui-version-test--text)))
        (should (string-match-p "^ Last update +Updated aaaaaaa → bbbbbbb (2 commits) · 1m ago$" text))
        (should (eq 'harness-success-face
                    (harness-ui-version-test--face-of "Updated aaaaaaa")))
        (should (string-match-p "bbbbbbb  Second" text))
        (should (string-match-p "Why it was done\\." text))
        (should (string-match-p "How it was done\\." text))
        (should (string-match-p "A first body\\." text))
        ;; A commit is its message: no diff or file statistics.
        (should-not (string-match-p "diff --git\\|files changed\\|insertions(+)\\|deletions(-)" text))))
    ;; A reload that was refused offers a restart.
    (harness-ui-version-test-with-page
        (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded))
      (setq harness--last-update (harness-plist-merge result (list :reload '(:refused ("lisp/broken.el")))))
      (let ((harness-ui-connection-address 'process)
            (restarted 0))
        (harness-ui-version--render)
        (should (member "[Restart]" (harness-ui-version-test--buttons)))
        (cl-letf (((symbol-function 'harness-restart) (lambda () (interactive) (cl-incf restarted))))
          (save-excursion
            (goto-char (point-min))
            (search-forward "[Restart]")
            (push-button (match-beginning 0)))
          (should (= 1 restarted))))))
  ;; Up to date: the noun phrase only, no changelog.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded))
    (setq harness--last-update (list :state "up-to-date" :to "bbbbbbb" :count 0
                                     :message "Harness is up to date (bbbbbbb)"
                                     :at (- (float-time) 7200)))
    (harness-ui-version--render)
    (let ((text (harness-ui-version-test--text)))
      (should (string-match-p "Last update +Current (bbbbbbb) · 2h ago" text))
      (should-not (string-match-p "Harness is up to date" text))))
  ;; Failed: its reason in the failure face.
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded))
    (setq harness--last-update (list :state "failed" :error "it has local changes"
                                     :message "Harness update failed: it has local changes"
                                     :at (- (float-time) 60)))
    (harness-ui-version--render)
    (should (string-match-p "Failed: it has local changes" (harness-ui-version-test--text)))
    (should (eq 'harness-failure-face (harness-ui-version-test--face-of "Failed:")))))

(ert-deftest harness-ui-version-shows-a-plugin-update ()
  "A plugin updated in its own checkout says so, and offers the restart.
A plugin's code loads once per process, so an update is not running
until one."
  (harness-ui-version-test-with-page
      (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded))
    (let ((harness-ui-connection-address 'process)
          (harness--last-plugin-update
           (list :state "updated" :name "deploy" :from "1111111" :to "2222222"
                 :at (- (float-time) 60))))
      (harness-ui-version--render)
      (let ((text (harness-ui-version-test--text)))
        (should (string-match-p "^ Last plugin update +deploy 1111111 → 2222222 · 1m ago +\\[Restart\\]$"
                                text))
        (should (member "[Restart]" (harness-ui-version-test--buttons))))
      ;; A plugin updated outside this Emacs' own harness is not restarted here.
      (let ((harness-ui-connection-address "box:7000"))
        (harness-ui-version--render)
        (should-not (member "[Restart]" (harness-ui-version-test--buttons)))))))

(ert-deftest harness-ui-version-dates-the-last-update ()
  "The outcome says when it was made, so an old one reads as old."
  (dolist (case `(("up-to-date" "bbbbbbb" 7200 " · 2h ago")
                  ("up-to-date" "bbbbbbb" 1 " · just now")
                  ("updated" "bbbbbbb" 180 " · 3m ago")
                  ("failed" nil 90000 " · 1d ago")))
    (pcase-let ((`(,state ,to ,age ,suffix) case))
      (harness-ui-version-test-with-page (harness-ui-version-test--behind)
        (setq harness--last-update (list :state state :from "aaaaaaa" :to to :count 0
                                         :error "it has local changes"
                                         :message "..." :at (- (float-time) age)))
        (harness-ui-version--render)
        (should (string-match-p (concat (regexp-quote suffix) "$")
                                (harness-ui-version-test--line "^ Last update")))
        (should (eq 'harness-dim-face (harness-ui-version-test--face-of suffix))))))
  ;; An outcome without a time (from before it was kept) shows none.
  (harness-ui-version-test-with-page (harness-ui-version-test--behind)
    (setq harness--last-update (list :state "up-to-date" :to "bbbbbbb" :message "up to date"))
    (harness-ui-version--render)
    (should (string-match-p "Last update +Current (bbbbbbb)$" (harness-ui-version-test--text)))))

(ert-deftest harness-ui-version-compares-this-emacs-with-the-harness-process ()
  (let ((harness-revision--loaded
         (harness-resolved (list :directory harness-ui-version-test--clone
                                 :loaded (- (float-time) 120)
                                 :commit (harness-ui-version-test--hash ?9)))))
    (harness-ui-version-test-with-page (harness-ui-version-test--behind)
      ;; In this Emacs: no other commit to compare.
      (should-not (string-match-p "this Emacs" (harness-ui-version-test--text)))
      (let ((harness-ui-connection-address 'process))
        (harness-ui-version--render)
        (let ((text (harness-ui-version-test--text)))
          (should (string-match-p "^ +this Emacs 9999999, 2m ago$" text))
          (should (eq 'harness-caution-face
                      (harness-ui-version-test--face-of "this Emacs 9999999")))
          (should (equal '("[Reload]" "[Update]" "[Check now]")
                         (harness-ui-version-test--buttons)))))
      ;; A harness elsewhere: this Emacs cannot reload or update it.
      (let ((harness-ui-connection-address "box:7000"))
        (harness-ui-version--render)
        (should (string-match-p "this Emacs 9999999" (harness-ui-version-test--text)))
        (should (equal '("[Check now]") (harness-ui-version-test--buttons))))
      (let ((harness-ui-connection-address 'process)
            (harness-revision--loaded
             (harness-resolved (list :loaded (- (float-time) 120)
                                     :commit (harness-ui-version-test--hash ?a)))))
        (harness-ui-version--render)
        (should (string-match-p "this Emacs aaaaaaa, 2m ago"
                                (harness-ui-version-test--text))))
      ;; Not known yet: the page draws without it, and again once it is.
      (let* ((harness-ui-connection-address 'process)
             (pending (harness-make-promise))
             (harness-revision--loaded pending))
        (harness-ui-version--render)
        (should-not (string-match-p "this Emacs" (harness-ui-version-test--text)))
        (harness-resolve pending (list :loaded (float-time) :commit (harness-ui-version-test--hash ?a)))
        (should (string-match-p "this Emacs aaaaaaa, just now"
                                (harness-ui-version-test--text)))))))

(ert-deftest harness-ui-version-follows-the-harness ()
  (let ((requests nil)
        (answer nil))
    (cl-letf (((symbol-function 'harness-ui-request)
               (lambda (method params)
                 (push (list method params) requests)
                 (setq answer (harness-make-promise)))))
      (harness-ui-version-test-with-page nil
        ;; No report yet.
        (should (string-match-p "Checking…" (harness-ui-version-test--text)))
        (should (equal "Version" (harness-ui-version-menu-label)))
        ;; A report the harness announces is drawn as it comes.
        (harness-ui-version--on-event "version/checked" (list (harness-ui-version-test--behind)))
        (should (string-match-p "Not latest" (harness-ui-version-test--text)))
        (should (equal "Version (not the latest)" (substring-no-properties (harness-ui-version-menu-label))))
        (harness-ui-version--on-event "session/created" (list "s1"))
        (should (string-match-p "Not latest" (harness-ui-version-test--text)))
        ;; g asks for a check, once however often it is pressed.
        (execute-kbd-macro (kbd "g"))
        (execute-kbd-macro (kbd "g"))
        (should (equal '(("_harness/version/check" (:max-age 0))) requests))
        (should (string-match-p "Check failed\\|Checking"
                                (harness-ui-version-test--header)))
        (should-not (member "[Check now]" (harness-ui-version-test--buttons)))
        (harness-resolve answer (harness-ui-version-test--report "latest" (harness-ui-version-test--loaded)))
        (should (string-match-p "Latest" (harness-ui-version-test--text)))
        (should (equal "Version" (harness-ui-version-menu-label)))
        ;; A failed check is said, under the last report.
        (harness-ui-version-refresh)
        (harness-reject answer '(harness-error "the harness is busy"))
        (should (string-match-p "Latest" (harness-ui-version-test--text)))
        (should (string-match-p "Check failed: the harness is busy" (harness-ui-version-test--text)))
        ;; Another harness: its report is asked for, the old one forgotten.
        (setq requests nil)
        (harness-ui-version--on-connected)
        (should (equal '(("_harness/version/check" (:max-age 60))) requests))
        (should (string-match-p "Checking…" (harness-ui-version-test--text)))
        (harness-reject answer '(harness-error "no such method"))
        (should (string-match-p "Check failed: no such method" (harness-ui-version-test--text)))))))

(ert-deftest harness-ui-version-refreshes-after-an-update ()
  "An update asks for a fresh report: the rows then show what it made current."
  (let ((requests nil)
        (harness--last-update (list :state "updated" :from "aaaaaaa" :to "bbbbbbb"
                                    :count 0 :at (float-time))))
    (cl-letf (((symbol-function 'harness-ui-request)
               (lambda (method params) (push (list method params) requests)
                 (harness-resolved (harness-ui-version-test--report "latest"
                                                                    (harness-ui-version-test--loaded))))))
      (harness-ui-version-test-with-page (harness-ui-version-test--behind)
        (harness-ui-version--on-update)
        (should (equal '(("_harness/version/check" (:max-age 0))) requests))))))

(ert-deftest harness-ui-version-page-keys ()
  (should (eq #'harness-ui-version-refresh (lookup-key harness-ui-version-mode-map (kbd "g"))))
  (should (eq #'harness-ui-version-update (lookup-key harness-ui-version-mode-map (kbd "u"))))
  (should (eq #'harness-reload (lookup-key harness-ui-version-mode-map (kbd "r"))))
  (should (eq #'harness-menu (lookup-key harness-ui-version-mode-map (kbd "?"))))
  (should (eq #'forward-button (lookup-key harness-ui-version-mode-map (kbd "TAB"))))
  ;; q comes from the shared view map, which buries the page.
  (should (eq harness-ui-view-map (keymap-parent harness-ui-version-mode-map)))
  (should (equal "Version" (car (get 'harness-ui-version-mode 'harness-menu-group))))
  (should (equal '(". u" "Update harness" harness-ui-version-update)
                 (aref (cadr (get 'harness-ui-version-mode 'harness-menu-group)) 3))))

(ert-deftest harness-ui-version-page-q-buries ()
  "q on the version page buries it, as it does on every harness view."
  (harness-ui-version-test-with-page (harness-ui-version-test--loaded)
    (should (eq #'harness-ui-quit-view (key-binding (kbd "q"))))))

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
      (should (equal "Not latest: local, sourcehut (mouse-1: open)"
                     (funcall (get-text-property 0 'help-echo nag) nil nil 0)))
      (cl-letf (((symbol-function 'harness-version) (lambda () (interactive) (cl-incf shown))))
        (dolist (key (list [header-line mouse-1] [mode-line mouse-1] [mouse-1] (kbd "RET")))
          (funcall (lookup-key (get-text-property 0 'local-map nag) key))))
      (should (= 4 shown)))
    ;; One origin with commits the harness lacks.
    (setq harness-ui-version--report
          (harness-ui-version-test--report "behind" (harness-ui-version-test--loaded)
                                           (harness-ui-version-test--newer "sourcehut" "remote")))
    (should (equal "Not latest: sourcehut (mouse-1: open)"
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
        (harness-update-hook nil)
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
        (should (memq #'harness-ui-version--on-update harness-update-hook))
        (should (equal '(mode-line chat-header board-header) (harness-ui-version-test--places)))
        (harness-ui-version--shutdown)
        (should-not harness-chat-header-end-functions)
        (should-not harness-ui-tasks-header-functions)
        (should-not harness-ui-notify-segment-functions)
        (should-not harness-ui-event-functions)
        (should-not harness-update-hook)
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
           (harness--last-update nil)
           (harness--updating nil)
           (page nil))
      (cl-flet ((wait-for (regexp)
                  (harness-test-wait (lambda ()
                                       (and (not (harness-ui-version--checking-p))
                                            (string-match-p regexp (with-current-buffer page
                                                                     (harness-ui-version-test--prose)))))
                                     30 regexp)))
        (cl-letf (((symbol-function 'harness-ui-version--width) (lambda () 120)))
          (unwind-protect
              (save-window-excursion
                (should (eq #'harness-version (lookup-key harness-ui-map (kbd "v"))))
              (harness-ui-version-test--commit-in upstream "second")
              (harness-version)
              (setq page (get-buffer harness-ui-version--buffer-name))
              (wait-for "● Not latest")
              (with-current-buffer page
                (should (string-match-p "^ Remote +● [0-9a-f]\\{7\\}  1 commit to pull"
                                        (harness-ui-version-test--text)))
                ;; The development checkout has the commit already, so it
                ;; has nothing to push; the pull is the remote's.
                (should (string-match-p "^ dev +● [0-9a-f]\\{7\\}  pushed"
                                        (harness-ui-version-test--text)))
                (should (string-match-p (concat "^ Remote +● [0-9a-f]\\{7\\}  1 commit to pull +\\[Update\\] +file://"
                                                (regexp-quote (directory-file-name upstream)))
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
              (wait-for "Remote +● [0-9a-f]\\{7\\} +2 commits to pull")
              ;; So does one the page asks for.
              (harness-ui-version-test--commit-in upstream "fourth")
              (with-current-buffer page
                (goto-char (point-min))
                (search-forward "[Check now]")
                (push-button (match-beginning 0)))
              (wait-for "Remote +● [0-9a-f]\\{7\\} +3 commits to pull"))
            (when page (kill-buffer page))
            (harness-modules-shutdown)
            (dolist (c (copy-sequence harness-acp--clients)) (harness-acp--drop-client c))
            (delete-directory base t)))))))

(provide 'harness-ui-version-test)
;;; harness-ui-version-test.el ends here
