;;; harness-logseq-test.el --- Tests for the Logseq markdown graph client -*- lexical-binding: t; -*-

;;; Commentary:

;; The client writes and reads a Logseq graph as the user's editor does:
;; one `- ' bullet per block, `key:: value' properties under it, pages
;; under `pages/' and days under `journals/'.  These tests keep to that
;; shape: what is written is read back, searched, linked and paginated,
;; and a name Logseq would refuse is normalized before it becomes a file.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-logseq-directory)
(defvar harness-logseq-pages-directory)
(defvar harness-logseq-journals-directory)

(defmacro harness-logseq-test-with (&rest body)
  "Run BODY with a fresh Logseq graph in `harness-logseq-directory'."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let ((harness-logseq-directory (expand-file-name "graph/" dir)))
       (dolist (module '(store logseq))
         (harness-test-load-module module))
       ,@body)))

(defun harness-logseq-test--file-content (page)
  "Return the file content of PAGE in the test graph."
  (harness-read-file (harness-logseq-page-file page harness-logseq-directory)))

(ert-deftest harness-logseq-status-says-when-there-is-no-graph ()
  "A root without pages is unavailable and says why; nothing is created."
  (harness-logseq-test-with
    (let ((status (harness-call 'logseq/status)))
      (should-not (plist-get status :available))
      (should (equal "no-page-directory" (plist-get status :reason))))
    (should-not (file-directory-p (expand-file-name "pages" harness-logseq-directory)))))

(ert-deftest harness-logseq-writes-a-bullet-with-properties ()
  "A block is one `- ' bullet, its properties indented under it."
  (harness-logseq-test-with
    (let ((block (harness-call 'logseq/block-add
                               "Projects/harness" "The build is `scripts/test.sh'."
                               (list :properties '(("workspace" . "Home")
                                                   ("source-session" . "s-1"))))))
      (should (equal "Projects/harness" (plist-get block :page)))
      (should (plist-get block :id))
      (should (file-exists-p (harness-logseq-page-file "Projects/harness"
                                                       harness-logseq-directory)))
      (let ((content (harness-logseq-test--file-content "Projects/harness")))
        (should (string-prefix-p "- The build is `scripts/test.sh'." content))
        (should (string-match-p "^  workspace:: Home$" content))
        (should (string-match-p "^  source-session:: s-1$" content))
        (should (string-match-p "^  id:: " content))
        (should (string-match-p "^  learned-at:: " content))
        ;; What the Logseq skill forbids is never written.
        (should-not (string-match-p "^#" content))
        (should-not (string-match-p "^---" content))
        (should-not (string-match-p "^[^- \t\n]" content)))
      (let ((page (harness-call 'logseq/page "Projects/harness")))
        (should (equal "Projects/harness" (plist-get page :name)))
        (should (equal "Home" (harness-logseq-block-property
                               (car (plist-get page :blocks)) "workspace")))))))

(ert-deftest harness-logseq-normalizes-page-names ()
  "A name Logseq would rewrite is cleaned; `/` is a namespace."
  (should (equal "Threads/Kitchen renovation"
                 (harness-logseq-page-name "Threads/Kitchen   renovation")))
  (should (equal "Threads/a b cd"
                 (harness-logseq-page-name "Threads/a [b] #c|d")))
  (should (equal "Untitled" (harness-logseq-page-name "")))
  (should (equal "a/b" (harness-logseq-page-name "a//b")))
  (harness-logseq-test-with
    (harness-call 'logseq/page-add "Threads/a b" "text")
    (should (file-exists-p
             (expand-file-name "pages/Threads/a b.md" harness-logseq-directory)))))

(ert-deftest harness-logseq-journals-live-under-journals ()
  "A day's name writes to `journals/', and reading marks the page a journal."
  (harness-logseq-test-with
    (let* ((name (harness-logseq-journal-name))
           (block (harness-call 'logseq/block-add name "Remember the grout."
                                (list :journal t
                                      :properties '(("role" . "user"))))))
      (should (plist-get block :journal))
      (should (file-exists-p
               (expand-file-name (concat "journals/" name ".md")
                                 harness-logseq-directory)))
      (should-not (file-exists-p
                   (expand-file-name (concat "pages/" name ".md")
                                     harness-logseq-directory)))
      (let ((page (harness-call 'logseq/page name)))
        (should (plist-get page :journal))
        (should (equal "Remember the grout." (plist-get (car (plist-get page :blocks))
                                                        :text)))))))

(ert-deftest harness-logseq-property-set-updates-the-first-block ()
  "A property is set on the page's identity block, adding one when absent."
  (harness-logseq-test-with
    (harness-call 'logseq/page-add "Threads/Kitchen" nil
                  (list :properties '(("workspace" . "Home")
                                      ("workspace-status" . "active"))))
    (harness-call 'logseq/property-set "Threads/Kitchen" "workspace-status" "parked")
    (harness-call 'logseq/property-set "Threads/Kitchen" "last-touched" "2026-11-07")
    (let* ((page (harness-call 'logseq/page "Threads/Kitchen"))
           (first (car (plist-get page :blocks))))
      (should (equal "parked" (harness-logseq-block-property first "workspace-status")))
      (should (equal "2026-11-07" (harness-logseq-block-property first "last-touched")))
      (should (= 1 (length (plist-get page :blocks)))))
    ;; A page property block set twice is not duplicated.
    (harness-call 'logseq/property-set "Threads/Kitchen" "workspace-status" "active")
    (let ((content (harness-logseq-test--file-content "Threads/Kitchen")))
      (should (= 1 (cl-count-if (lambda (line) (string-match-p "workspace-status::" line))
                                (split-string content "\n")))))))

(ert-deftest harness-logseq-search-ranks-and-filters ()
  "A search matches words in blocks, ranks the best, and filters by workspace."
  (harness-logseq-test-with
    (harness-call 'logseq/page-add "Threads/Kitchen" nil
                  (list :properties '(("workspace-id" . "w-1"))))
    (harness-call 'logseq/page-add "Threads/Kitchen" "Chose quartz for the countertop."
                  (list :properties '(("workspace-id" . "w-1")
                                      ("role" . "assistant"))))
    (harness-call 'logseq/page-add "Threads/Taxes" "The countertop quote is a tax write-off."
                  (list :properties '(("workspace-id" . "w-2"))))
    (let ((found (harness-call 'logseq/search "countertop quartz")))
      (should found)
      ;; Two words matched beat one.
      (should (string-match-p "quartz" (plist-get (car found) :text)))
      (should (string-match-p "<<" (plist-get (car found) :snippet)))
      (should (cl-find-if (lambda (block)
                            (string-match-p "Taxes" (format "%s" (plist-get block :page))))
                          found)))
    (let ((mine (harness-call 'logseq/search "countertop" (list :workspace "w-1"))))
      (should (= 1 (length mine)))
      (should (string-match-p "quartz" (plist-get (car mine) :text))))
    ;; A thread search names one page.
    (let ((page (harness-call 'logseq/search "countertop"
                              (list :pages '("Threads/Taxes")))))
      (should (= 1 (length page)))
      (should (equal "Threads/Taxes" (plist-get (car page) :page))))
    ;; An empty query, or only stopwords, finds nothing to rank.
    (should-not (harness-call 'logseq/search ""))
    (should-not (harness-call 'logseq/search "what about the"))
    (should-not (harness-call 'logseq/search "and the"))))

(ert-deftest harness-logseq-search-skips-property-blocks-and-journals-on-request ()
  "A block with no words is never a result; journals can be left out."
  (harness-logseq-test-with
    (harness-call 'logseq/page-add "Threads/Kitchen" nil
                  (list :properties '(("workspace-id" . "w-1")))
                  )
    (harness-call 'logseq/block-add (harness-logseq-journal-name)
                  "The grout is warm grey."
                  (list :journal t
                        :properties '(("workspace-id" . "w-1"))))
    (should (harness-call 'logseq/search "warm grey"
                          (list :workspace "w-1")))
    (should-not (harness-call 'logseq/search "warm grey"
                              (list :workspace "w-1" :journals nil)))
    ;; A properties-only block is not a hit even for its own property words.
    (should-not (harness-call 'logseq/search "workspace-id"))))

(ert-deftest harness-logseq-backlinks-find-links-in-properties ()
  "A `[[Page]]' in a block or a property is a backlink."
  (harness-logseq-test-with
    (harness-call 'logseq/block-add "Threads/Kitchen" "Chose quartz."
                  (list :properties '(("thread" . "[[Threads/Kitchen]]"))))
    (harness-call 'logseq/block-add (harness-logseq-journal-name)
                  "Captured a decision."
                  (list :journal t
                        :properties '(("thread" . "[[Threads/Kitchen]]"))))
    (let ((links (harness-call 'logseq/backlinks "Threads/Kitchen")))
      (should (= 2 (length links)))
      (should (cl-find-if (lambda (block) (plist-get block :journal)) links))
      (should (cl-find-if (lambda (block) (equal "Threads/Kitchen"
                                                 (plist-get block :page)))
                          links)))))

(ert-deftest harness-logseq-root-follows-the-environment ()
  "The graph root is the option, else LOGSEQ_HOME, else ~/logseq."
  (let ((harness-logseq-directory nil)
        (old (getenv "LOGSEQ_HOME")))
    (unwind-protect
        (progn
          (setenv "LOGSEQ_HOME" "/tmp/logseq-home/")
          (should (equal (file-name-as-directory (expand-file-name "/tmp/logseq-home/"))
                         (harness-logseq-root)))
          (setenv "LOGSEQ_HOME" nil)
          (should (equal (file-name-as-directory (expand-file-name "~/logseq"))
                         (harness-logseq-root))))
      (setenv "LOGSEQ_HOME" old))))

(ert-deftest harness-logseq-page-list-and-block-time ()
  "Pages are listed newest first, and `learned-at' becomes a time."
  (harness-logseq-test-with
    (harness-call 'logseq/block-add "One" "first" (list :date (encode-time 0 0 12 1 11 2026)))
    (harness-call 'logseq/block-add "Two" "second")
    (let ((pages (harness-call 'logseq/page-list)))
      (should (cl-find-if (lambda (page) (equal "One" (plist-get page :name))) pages))
      (should (cl-find-if (lambda (page) (equal "Two" (plist-get page :name))) pages))
      (should (>= (plist-get (car pages) :updated) 0)))
    (let* ((page (harness-call 'logseq/page "One"))
           (block (car (plist-get page :blocks))))
      (should (equal "first" (plist-get block :text)))
      (should (numberp (harness-logseq--block-time block)))
      (should (equal "2026-11-01 12:00"
                     (harness-logseq-block-property block "learned-at"))))))

(provide 'harness-logseq-test)
;;; harness-logseq-test.el ends here
