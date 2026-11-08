;;; harness-tools-handin-review-test.el --- What a hand-in shows of its design  -*- lexical-binding: t; -*-

;;; Commentary:

;; A hand-in may explain its design as a Markdown document, and may add
;; interactive demos to its evidence.  The document is kept whole in the
;; report, the demo is kept as the reviewer's actions to take, and the
;; report gets a walkthrough brief for a conversation that presents it.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-tools-handin-review-test--task nil
  "The task `task/for-session' answers with.")
(defvar harness-tools-handin-review-test--reports nil
  "The reports `task/hand-in' was given.")

(defmacro harness-tools-handin-review-test-with (&rest body)
  "Load the hand_in tool and run BODY in a temporary session directory."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider tools session agent tools-handin))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (let* ((dir (harness-test-temp-dir))
            (sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id))
            (default-directory dir))
       (setq harness-tools-handin-review-test--task
             (list :id "t1" :prompt "Explain the new parser")
             harness-tools-handin-review-test--reports nil)
       (harness-register-method 'task/for-session
                                (lambda (_sid) harness-tools-handin-review-test--task))
       (harness-register-method 'task/hand-in
                                (lambda (id report)
                                  (push (cons id report) harness-tools-handin-review-test--reports)
                                  t))
       (let ((ctx (list :session-id sid :cwd dir :call-id "h1")))
         ,@body))))

(ert-deftest harness-tools-handin-design-reads-the-whole-document ()
  "A design is snapshotted, named by its place in the worktree, and titled."
  (harness-tools-handin-review-test-with
    (with-temp-file "docs-design.md"
      (insert "# The new parser\n\nIt reads nested quotes, and it says why.\n"))
    (make-directory "docs" t)
    (rename-file "docs-design.md" "docs/design.md" t)
    (let ((design (harness-tools-handin--design
                   (list :path "docs/design.md" :summary "Why the parser changed")
                   ctx)))
      (should (listp design))
      (should (equal "The new parser" (plist-get design :title)))
      (should (equal "docs/design.md" (plist-get design :name)))
      (should (equal "Why the parser changed" (plist-get design :summary)))
      (should (string-match-p "nested quotes" (plist-get design :text)))))
  (harness-tools-handin-review-test-with
    (with-temp-file "plain.md" (insert "# Its heading\n"));
    (let ((design (harness-tools-handin--design "plain.md" ctx)))
      (should (equal "Its heading" (plist-get design :title))))))

(ert-deftest harness-tools-handin-design-refuses-what-is-not-a-document ()
  "A missing, empty, binary, or outside document is refused with its reason."
  (harness-tools-handin-review-test-with
    (should (string-match-p "design: missing.md not found"
                            (harness-tools-handin--design "missing.md" ctx)))
    (with-temp-file "empty.md" (insert "  \n"))
    (should (string-match-p "design: empty.md is empty"
                            (harness-tools-handin--design "empty.md" ctx)))
    (with-temp-file "binary.md" (insert "a\0b"))
    (should (string-match-p "not a text document"
                            (harness-tools-handin--design "binary.md" ctx)))
    (let ((outside (make-temp-file "handin-outside-" nil ".md")))
      (unwind-protect
          (progn
            (with-temp-file outside (insert "# Outside\n"))
            (should (string-match-p "lies outside"
                                    (harness-tools-handin--design outside ctx))))
        (delete-file outside)))
    (should (string-match-p "design needs path"
                            (harness-tools-handin--design '(:title "none") ctx)))))

(ert-deftest harness-tools-handin-demo-keeps-a-command-and-its-narration ()
  "A demo keeps its page, command, working directory, title and narration.
Nothing runs when it is handed in; the command is data."
  (harness-tools-handin-review-test-with
    (make-directory "demo")
    (with-temp-file "demo/index.html" (insert "<html>newton</html>"))
    (let ((demo (harness-tools-handin--demo
                 '(:path "demo/index.html"
                   :title "Newton's cradle"
                   :url "http://localhost:8000"
                   :command ("python3" "-m" "http.server" "8000")
                   :workspace "w-kitchen"
                   :narration "Start on the left ball.")
                 1 ctx)))
      (should (equal "demo" (plist-get demo :kind)))
      (should (equal "Newton's cradle" (plist-get demo :title)))
      (should (equal "demo/index.html" (plist-get demo :name)))
      (should (equal "http://localhost:8000" (plist-get demo :url)))
      (should (equal '("python3" "-m" "http.server" "8000") (plist-get demo :command)))
      (should (equal "demo" (plist-get demo :cwd-name)))
      (should (equal "Start on the left ball." (plist-get demo :narration)))
      ;; A demo can be bound to the workspace whose computer runs it.
      (should (equal "w-kitchen" (plist-get demo :workspace))))
    ;; A path alone is a demo, and its title is the page's name.
    (let ((demo (harness-tools-handin--demo "demo/index.html" 2 ctx)))
      (should (equal "index" (plist-get demo :title)))
      (should (equal "demo" (plist-get demo :cwd-name))))
    ;; A URL alone is a demo too.
    (let ((demo (harness-tools-handin--demo '(:url "https://example.test/run") 3 ctx)))
      (should (equal "https://example.test/run" (plist-get demo :url)))
      (should (string-match-p "example.test/run" (plist-get demo :title))))))

(ert-deftest harness-tools-handin-numbers-its-demos ()
  "Demos are numbered among the demos, not among the evidence, and the brief
says which computer a bound demo runs on."
  (let* ((items (harness-tools-handin--demo-ids
                 (list (list :kind "note" :text "a note")
                       (list :kind "demo" :title "first")
                       (list :kind "image" :path "/tmp/x.png")
                       (list :kind "demo" :title "second" :workspace "w-1")))))
    (should (equal "demo-1" (plist-get (nth 1 items) :id)))
    (should (equal "demo-2" (plist-get (nth 3 items) :id)))
    (should-not (plist-member (nth 0 items) :id)))
  (let* ((report (list :evidence (list (list :kind "demo" :title "first")
                                       (list :kind "demo" :title "second"
                                             :workspace "w-kitchen" :narration "Go"))))
         (task (list :id "t1" :prompt "Show the cradle" :project "/tmp"))
         (brief (harness-tools-handin--walkthrough
                 (list :evidence (harness-tools-handin--demo-ids
                                  (plist-get report :evidence)))
                 task)))
    (should (string-match-p "on the workspace computer w-kitchen" brief))
    (should (string-match-p "second" brief))))

(ert-deftest harness-tools-handin-demo-refuses-what-it-cannot-show ()
  "A demo needs a way to show it, and its paths stay in the session's directories."
  (harness-tools-handin-review-test-with
    (should (string-match-p "demo needs a path, a url or a command"
                            (harness-tools-handin--demo '(:title "none") 1 ctx)))
    (should (string-match-p "not an http or https URL"
                            (harness-tools-handin--demo '(:url "file:///etc/passwd") 2 ctx)))
    (should (string-match-p "not a list of arguments"
                            (harness-tools-handin--demo '(:command "python3 -m http.server") 3 ctx)))
    (let ((outside (make-temp-file "handin-demo-" nil ".html")))
      (unwind-protect
          (progn
            (with-temp-file outside (insert "<html>outside</html>"))
            (should (string-match-p "lies outside"
                                    (harness-tools-handin--demo (list :path outside) 4 ctx))))
        (delete-file outside)))
    (should (string-match-p "not a directory"
                            (harness-tools-handin--demo '(:url "http://localhost" :cwd "nope") 5 ctx)))
    (should (string-match-p "not found"
                            (harness-tools-handin--demo '(:path "missing.html") 6 ctx)))))

(ert-deftest harness-tools-handin-records-the-design-demo-and-walkthrough ()
  "The report keeps the design, the demo, and the brief that presents them."
  (harness-tools-handin-review-test-with
    (make-directory "demo")
    (with-temp-file "design.md"
      (insert "# The new parser\n\nIt reads nested quotes.\n"))
    (with-temp-file "demo/index.html" (insert "<html>newton</html>"))
    (let ((result (harness-test-await
                   (harness-tools-handin--hand-in
                    (list :problem "Nested quotes"
                          :summary "# Done"
                          :design '(:path "design.md" :summary "Why it changed")
                          :evidence (list (list :demo '(:path "demo/index.html"
                                                        :title "Newton's cradle"
                                                        :narration "Start on the left ball."))))
                    ctx))))
      (should-not (plist-get result :is-error))
      (should (plist-get result :end-turn))
      (let* ((report (cdr (assoc "t1" harness-tools-handin-review-test--reports)))
             (design (plist-get report :design))
             (demo (car (plist-get report :evidence)))
             (walk (plist-get report :walkthrough)))
        (should (equal "design.md" (plist-get design :name)))
        (should (equal "The new parser" (plist-get design :title)))
        (should (equal "demo" (plist-get demo :kind)))
        (should (equal "Newton's cradle" (plist-get demo :title)))
        (should (stringp walk))
        (should (string-match-p "design.md" walk))
        (should (string-match-p "Newton's cradle" walk))
        (should (string-match-p "Start on the left ball" walk))
        ;; The report rides the result for the transcript.
        (should (equal report (plist-get (plist-get result :meta) :report)))))))

(provide 'harness-tools-handin-review-test)
;;; harness-tools-handin-review-test.el ends here
