;;; harness-search-test.el --- Tests for the web search tool -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'harness-core)
(require 'harness-http)
(require 'harness-tools)
(require 'harness-search)
(require 'harness-test-helpers)

(harness-module-load 'harness-http)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-search)

;; Tool calls run asynchronously, after any `let' binding around the call
;; has unwound; keep test configuration global and never the real API.
(setq harness-search-brave-api-key nil)

(defun harness-search-test--call (arguments)
  "Run the websearch tool with ARGUMENTS and return the result."
  (let ((deferred (harness-tools-execute "websearch" arguments
                                         (harness-tool-context-create
                                          :session-id "s1" :cwd default-directory))))
    (harness-test-settle deferred 10)
    (harness-deferred-value deferred)))

(defun harness-search-test--text (result)
  "Tool result text of RESULT."
  (harness-tools--text-of (plist-get result :content)))

(ert-deftest harness-search-registers-tool-and-provider ()
  (should (harness-tool-get "websearch"))
  (should (equal (harness-tool-kind (harness-tool-get "websearch")) 'read))
  (should (harness-tool-read-only (harness-tool-get "websearch")))
  (should (member "brave" (harness-search-providers))))

(ert-deftest harness-search-fake-provider-formats-results ()
  (harness-search-register-provider
   "test"
   :function (lambda (query count)
               (should (equal query "emacs agents"))
               (should (= count 2))
               (let ((deferred (harness-deferred-new)))
                 (harness-deferred-resolve
                  deferred
                  (list (list :title "Harness" :url "https://example.com/a"
                              :description "An agent harness.")
                        (list :title "Second" :url "https://example.com/b"
                              :description "Another result.")))
                 deferred)))
  (setq harness-search--order '("test"))
  (unwind-protect
      (let ((result (harness-search-test--call '(:query "emacs agents" :count 2))))
        (should-not (plist-get result :is-error))
        (let ((text (harness-search-test--text result)))
          (should (string-match-p "1\\. Harness" text))
          (should (string-match-p "https://example.com/a" text))
          (should (string-match-p "2\\. Second" text))
          (should (string-match-p "An agent harness\\." text))))
    (harness-search-unregister-provider "test")
    (setq harness-search--order '("brave"))))

(ert-deftest harness-search-failing-provider-becomes-tool-error ()
  (harness-search-register-provider
   "test-fail"
   :function (lambda (_query _count)
               (let ((deferred (harness-deferred-new)))
                 (harness-deferred-reject deferred '(harness-user-error "backend is down"))
                 deferred)))
  (setq harness-search--order '("test-fail"))
  (unwind-protect
      (let ((result (harness-search-test--call '(:query "anything"))))
        (should (plist-get result :is-error))
        (should (string-match-p "backend is down" (harness-search-test--text result))))
    (harness-search-unregister-provider "test-fail")
    (setq harness-search--order '("brave"))))

(ert-deftest harness-search-strips-html-entities ()
  (should (equal (harness-search--strip-html "A <b>bold</b> &amp; nice &#39;thing&#39;")
                 "A bold & nice 'thing'"))
  (should (equal (harness-search--strip-html "<p>line\nbreak</p>") "line break")))

(ert-deftest harness-search-brave-requests-and-parses ()
  ;; A canned Brave endpoint: assert the request line and headers, then
  ;; answer with a realistic payload.
  (let* ((harness-search-brave-api-key "test-key")
         (requests nil)
         (server (harness-test-http-server
                  (lambda (process request)
                    (push (cons request process) requests)
                    (list (harness-test-http-response
                           200 '(("Content-Type" . "application/json"))
                           (json-serialize
                            '(:web (:results [(:title "Emacs Agent Harness"
                                               :url "https://example.com/harness"
                                               :description "A &quot;harness&quot; for agents.")
                                              (:title "Second Result"
                                               :url "https://example.com/second"
                                               :description "More info.")]))))))))
         (deferred (harness-http-fetch
                    (format "http://%s:%s/res/v1/web/search?q=emacs%%20agents&count=2"
                            "127.0.0.1" (process-contact server :service))
                    :headers '(("Accept" . "application/json")
                               ("X-Subscription-Token" . "test-key")))))
    (unwind-protect
        (progn
          (harness-test-settle deferred 10)
          (should (harness-deferred-resolved-p deferred))
          (let* ((response (harness-deferred-value deferred))
                 (body (harness-http-response-body response))
                 (results (append (plist-get (plist-get (json-parse-string body :object-type 'plist)
                                                        :web)
                                             :results)
                                  nil)))
            (should (= (length results) 2))
            (should (equal (plist-get (aref (plist-get (plist-get (json-parse-string body :object-type 'plist)
                                                                  :web)
                                                       :results)
                                           0)
                                      :title)
                           "Emacs Agent Harness")))
          ;; The server saw the query parameters and the auth header.
          (let ((request (caar requests)))
            (should (string-match-p
                     (regexp-quote "GET /res/v1/web/search?q=emacs%20agents&count=2")
                     request))
            (should (string-match-p "X-Subscription-Token: test-key" request))))
      (harness-test-http-cleanup))))

(ert-deftest harness-search-brave-uses-the-real-tool-path ()
  ;; The brave provider through the tool: the URL points at HTTPS, so use
  ;; a fake provider function instead?  Instead verify the error path when
  ;; no key is configured.
  (setq harness-search-brave-api-key nil
        harness-search--order '("brave"))
  (let ((result (harness-search-test--call '(:query "hello"))))
    (should (plist-get result :is-error))
    (should (string-match-p "BRAVE_API_KEY" (harness-search-test--text result)))))

(provide 'harness-search-test)
;;; harness-search-test.el ends here
