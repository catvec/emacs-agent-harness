;;; harness-core-test.el --- Tests for the core data model -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'harness-core)

(ert-deftest harness-core-test-json-round-trip ()
  "JSON survives a write/read round trip for the shapes the harness uses."
  (let* ((object '((model . "x")
                   (messages . (((role . "user") (content . "hi"))))
                   (n . 1.5)
                   (yes . t)
                   (no . :false)
                   (nothing . nil)))
         (text (harness-json-write object))
         (back (harness-json-read text)))
    (should (equal (harness-alist-get :model back) "x"))
    (should (equal (harness-alist-get :nothing back) nil))
    (should (eq (harness-alist-get :no back) :false))
    (should (eq (harness-alist-get :yes back) t))
    (should (equal (harness-alist-get :content (car (harness-alist-get :messages back)))
                   "hi"))))

(ert-deftest harness-core-test-json-escapes ()
  "Strings containing quotes, newlines and non-ASCII round trip."
  (let* ((value "line1\nline2 \"quoted\" \\ ö")
         (back (harness-alist-get :v (harness-json-read
                                      (harness-json-write (list (cons 'v value)))))))
    (should (equal back value))))

(ert-deftest harness-core-test-alist-get-keys ()
  "`harness-alist-get' accepts symbol, keyword and string keys."
  (should (equal (harness-alist-get :foo '((foo . 1))) 1))
  (should (equal (harness-alist-get 'foo '((foo . 1))) 1))
  (should (equal (harness-alist-get "foo" '((foo . 1))) 1))
  (should (equal (harness-alist-get :foo '(("foo" . 2))) 2))
  (should (equal (harness-alist-get :foo '((:foo . 3))) 3))
  (should (equal (harness-alist-get :foo '((bar . 1))) nil)))

(ert-deftest harness-core-test-truncate-head ()
  "Truncating from the head keeps the beginning and says so."
  (let ((out (harness-truncate-string "abcdefghij" 4 nil nil)))
    (should (string-prefix-p "abcd" out))
    (should (string-match-p "truncated" out)))
  (should (equal (harness-truncate-string "abc" 100 nil nil) "abc")))

(ert-deftest harness-core-test-truncate-tail ()
  "Truncating from the tail keeps the end, which is what command output wants."
  (let ((out (harness-truncate-string "abcdefghij" 4 nil t)))
    (should (string-suffix-p "ghij" out))
    (should (string-match-p "truncated" out))))

(ert-deftest harness-core-test-truncate-lines ()
  "Line limits are applied before character limits."
  (let ((out (harness-truncate-string "a\nb\nc\nd\n" nil 2 nil)))
    (should (string-prefix-p "a\nb\n" out))
    (should (string-match-p "truncated" out))))

(ert-deftest harness-core-test-session-append-is-o1 ()
  "Appending keeps the tail pointer in sync and messages in order."
  (let ((session (harness--make-session :id "s" :name "s")))
    (dotimes (i 5)
      (harness-session-append-message
       session (harness-message-create session 'user (format "%d" i))))
    (should (equal (mapcar #'harness-message-content
                           (harness-session-messages session))
                   '("0" "1" "2" "3" "4")))
    (should (eq (harness-session-tail session)
                (last (harness-session-messages session))))
    (should (equal (harness-message-content (harness-session-last-message session)) "4"))))

(ert-deftest harness-core-test-message-ids-are-unique ()
  "Message ids are unique within a session and reset by `set-messages'."
  (let ((session (harness--make-session :id "s" :name "s")))
    (dotimes (_ 3)
      (harness-session-append-message session (harness-message-create session 'user "x")))
    (should (equal (mapcar #'harness-message-id (harness-session-messages session))
                   '("m-1" "m-2" "m-3")))
    (harness-session-set-messages session nil)
    (harness-session-append-message session (harness-message-create session 'user "x"))
    (should (equal (harness-message-id (harness-session-last-message session)) "m-1"))))

(ert-deftest harness-core-test-usage-add ()
  "Usage plists add up, including unknown keys contributed by plugins."
  (let ((sum (harness-usage-add '(:in 10 :out 2 :cost 0.5)
                                '(:in 5 :out 3 :cost 0.25 :requests 1))))
    (should (equal (plist-get sum :in) 15))
    (should (equal (plist-get sum :out) 5))
    (should (= (plist-get sum :cost) 0.75))
    (should (equal (plist-get sum :requests) 1))))

(ert-deftest harness-core-test-tool-call-args ()
  "Tool call arguments parse lazily and are readable by key."
  (let ((call (harness-tool-call-create :name "bash"
                                        :args-string "{\"command\":\"ls -la\"}")))
    (harness-tool-call-parse-args call)
    (should (equal (harness-tool-call-arg call :command) "ls -la"))
    (should (equal (harness-tool-call-arg call :missing "d") "d"))
    (should (string-match-p "bash" (harness-tool-call-summary call)))))

(ert-deftest harness-core-test-tool-call-bad-args ()
  "Malformed arguments do not signal; the call keeps its raw string."
  (let ((call (harness-tool-call-create :name "bash" :args-string "{\"command\":")))
    (should-not (harness-tool-call-parse-args call))
    (should (equal (harness-tool-call-args-string call) "{\"command\":"))))

(ert-deftest harness-core-test-status-helpers ()
  "Status predicates classify the statuses the UI filters on."
  (should (harness-status-blocked-p 'awaiting-approval))
  (should (harness-status-blocked-p 'awaiting-answer))
  (should-not (harness-status-blocked-p 'working))
  (should (harness-status-active-p 'streaming))
  (should (harness-status-active-p 'classifying))
  (should-not (harness-status-active-p 'idle)))

(ert-deftest harness-core-test-formatting ()
  "Counts, costs and relative times render compactly."
  (should (equal (harness-format-count 999) "999"))
  (should (equal (harness-format-count 1500) "1.5k"))
  (should (equal (harness-format-count 2500000) "2.5M"))
  (should (equal (harness-format-cost 0.0123) "$0.0123"))
  (should (equal (harness-format-cost 2.5) "$2.50"))
  (should (equal (harness-format-time (- (float-time) 10)) "now")))

(provide 'harness-core-test)
;;; harness-core-test.el ends here
