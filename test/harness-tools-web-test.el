;;; harness-tools-web-test.el --- Tests for web_search and web_fetch  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)

(defun harness-tools-web-test--allow (_decision next &rest _)
  "Permissive permission filter for tests."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-web-test--setup ()
  "Load the tools modules and allow everything."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-web)
  (harness-add-filter 'permission/decide #'harness-tools-web-test--allow 10))

(defun harness-tools-web-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input)) 20))

(defconst harness-tools-web-test--brave-json
  '(:query (:original "hello world")
    :web (:results ((:title "First <strong>Result</strong>" :url "https://a.example/one"
                     :description "Snippet one &amp; more")
                    (:title "Second" :url "https://b.example/two" :description "Snippet two")))))

(ert-deftest harness-tools-web-search-brave-stubbed ()
  (harness-tools-web-test--setup)
  (harness-test-with-temp-state
    (let ((calls nil)
          (harness-brave-api-key "test-key")
          (harness-websearch-provider 'brave))
      (cl-letf (((symbol-function 'harness-http-request-json)
                 (lambda (url &rest args)
                   (push (cons url args) calls)
                   (harness-resolved harness-tools-web-test--brave-json))))
        (let* ((r (harness-tools-web-test--call "web_search" :query "hello world" :count 2))
               (c (plist-get r :content)))
          (should-not (plist-get r :is-error))
          (should (= 1 (length calls)))
          (let ((url (caar calls)) (args (cdar calls)))
            (should (string-prefix-p "https://api.search.brave.com/res/v1/web/search?q=hello%20world&count=2" url))
            (should (equal "test-key" (cdr (assoc "X-Subscription-Token" (plist-get args :headers))))))
          (should (string-search "1. First Result\n   https://a.example/one\n   Snippet one & more" c))
          (should (string-search "2. Second\n   https://b.example/two\n   Snippet two" c))
          (should (= 2 (plist-get (plist-get r :meta) :count))))
        ;; Default count is 5, and large counts are capped.
        (harness-tools-web-test--call "web_search" :query "x")
        (should (string-search "count=5" (caar calls)))
        (harness-tools-web-test--call "web_search" :query "x" :count 999)
        (should (string-search (format "count=%d" harness-web-search-max-count) (caar calls)))
        ;; No results.
        (cl-letf (((symbol-function 'harness-http-request-json)
                   (lambda (&rest _) (harness-resolved '(:web (:results nil))))))
          (should (string-search "No results" (plist-get (harness-tools-web-test--call "web_search" :query "x") :content))))
        ;; HTTP failures become tool errors.
        (cl-letf (((symbol-function 'harness-http-request-json)
                   (lambda (&rest _) (harness-rejected '(http-error 429 "rate limited")))))
          (let ((r (harness-tools-web-test--call "web_search" :query "x")))
            (should (plist-get r :is-error))
            (should (string-search "Web search failed (brave)" (plist-get r :content)))))))))

(ert-deftest harness-tools-web-search-key-resolution ()
  (harness-tools-web-test--setup)
  (harness-test-with-temp-state
    (let ((process-environment (cons "BRAVE_API_KEY" process-environment))
          (auth-sources nil)
          (harness-brave-api-key nil))
      ;; No key anywhere: a helpful error and no request.
      (cl-letf (((symbol-function 'harness-http-request-json)
                 (lambda (&rest _) (error "must not be called"))))
        (let ((r (harness-tools-web-test--call "web_search" :query "x")))
          (should (plist-get r :is-error))
          (should (string-search "BRAVE_API_KEY" (plist-get r :content)))))
      ;; The environment variable is picked up.
      (let ((process-environment (cons "BRAVE_API_KEY=env-key" process-environment))
            (seen nil))
        (cl-letf (((symbol-function 'harness-http-request-json)
                   (lambda (_url &rest args)
                     (setq seen (cdr (assoc "X-Subscription-Token" (plist-get args :headers))))
                     (harness-resolved '(:web (:results nil))))))
          (harness-tools-web-test--call "web_search" :query "x")
          (should (equal "env-key" seen))))
      ;; The custom variable wins over the environment.
      (let ((process-environment (cons "BRAVE_API_KEY=env-key" process-environment))
            (harness-brave-api-key "custom-key")
            (seen nil))
        (cl-letf (((symbol-function 'harness-http-request-json)
                   (lambda (_url &rest args)
                     (setq seen (cdr (assoc "X-Subscription-Token" (plist-get args :headers))))
                     (harness-resolved '(:web (:results nil))))))
          (harness-tools-web-test--call "web_search" :query "x")
          (should (equal "custom-key" seen)))))))

(ert-deftest harness-tools-web-search-custom-provider ()
  (harness-tools-web-test--setup)
  (harness-test-with-temp-state
    (harness-websearch-register-provider
     'fake (lambda (query count)
             (harness-resolved (list (list :title (format "%s x%d" query count) :url "https://f.example/" :snippet "")))))
    (let ((harness-websearch-provider 'fake))
      (let ((c (plist-get (harness-tools-web-test--call "web_search" :query "q" :count 3) :content)))
        (should (equal "1. q x3\n   https://f.example/" c))))
    ;; A synchronous provider result is accepted too.
    (harness-websearch-register-provider 'sync (lambda (_q _c) (list (list :title "S" :url "u"))))
    (let ((harness-websearch-provider 'sync))
      (should (string-prefix-p "1. S" (plist-get (harness-tools-web-test--call "web_search" :query "q") :content))))
    (let ((harness-websearch-provider 'missing))
      (let ((r (harness-tools-web-test--call "web_search" :query "q")))
        (should (plist-get r :is-error))
        (should (string-search "Unknown web search provider" (plist-get r :content)))))
    (should (plist-get (harness-tools-web-test--call "web_search" :query " ") :is-error))
    (should (eq 'net (harness-tool-kind (harness-tool-get "web_search"))))
    (should (eq 'net (harness-tool-kind (harness-tool-get "web_fetch"))))))

(defun harness-tools-web-test--stub-http (status headers body &optional err)
  "Return a `harness-http-request' replacement answering STATUS HEADERS BODY ERR."
  (lambda (_url &rest args)
    (run-at-time 0 nil (plist-get args :callback) status headers body err)
    nil))

(ert-deftest harness-tools-web-fetch-renders-html ()
  (harness-tools-web-test--setup)
  (skip-unless (libxml-available-p))
  (harness-test-with-temp-state
    (cl-letf (((symbol-function 'harness-http-request)
               (harness-tools-web-test--stub-http
                200 '(("content-type" . "text/html; charset=utf-8"))
                "<html><head><title>Test Page</title><style>p{}</style></head><body><h1>Heading</h1><p>Para &amp; <a href=\"/x\">link</a>.</p><script>var evil = 1;</script><ul><li>one</li><li>two</li></ul></body></html>")))
      (let* ((r (harness-tools-web-test--call "web_fetch" :url "https://example.com/page"))
             (c (plist-get r :content)))
        (should-not (plist-get r :is-error))
        (should (string-prefix-p "URL: https://example.com/page\nTitle: Test Page\nType: text/html; charset=utf-8\n\n" c))
        (should (string-search "Heading" c))
        (should (string-search "Para & link." c))
        (should (string-search "one" c))
        (should-not (string-search "var evil" c))
        (should-not (string-search "p{}" c))
        (should (plist-get (plist-get r :meta) :html))))))

(ert-deftest harness-tools-web-fetch-plain-text-truncation-and-errors ()
  (harness-tools-web-test--setup)
  (harness-test-with-temp-state
    (cl-letf (((symbol-function 'harness-http-request)
               (harness-tools-web-test--stub-http 200 '(("content-type" . "text/plain")) "just text\nline 2")))
      (let ((c (plist-get (harness-tools-web-test--call "web_fetch" :url "http://example.com/t.txt") :content)))
        (should (string-suffix-p "Type: text/plain\n\njust text\nline 2" c))))
    (cl-letf (((symbol-function 'harness-http-request)
               (harness-tools-web-test--stub-http 200 '(("content-type" . "text/plain")) (make-string 100 ?a))))
      (let ((c (plist-get (harness-tools-web-test--call "web_fetch" :url "http://example.com/t.txt" :max_chars 10) :content)))
        (should (string-search "\n\naaaaaaaaaa\n\n[Truncated: 10 of 100 characters shown" c))))
    (cl-letf (((symbol-function 'harness-http-request)
               (harness-tools-web-test--stub-http 404 nil "<html>gone</html>")))
      (let ((r (harness-tools-web-test--call "web_fetch" :url "http://example.com/missing")))
        (should (plist-get r :is-error))
        (should (string-search "HTTP 404" (plist-get r :content)))))
    (cl-letf (((symbol-function 'harness-http-request)
               (harness-tools-web-test--stub-http nil nil "" '(curl "curl exited 6: could not resolve host"))))
      (let ((r (harness-tools-web-test--call "web_fetch" :url "http://nohost.invalid/")))
        (should (plist-get r :is-error))
        (should (string-search "could not resolve host" (plist-get r :content)))))
    (should (plist-get (harness-tools-web-test--call "web_fetch" :url "ftp://example.com/") :is-error))
    (should (plist-get (harness-tools-web-test--call "web_fetch") :is-error))))

(ert-deftest harness-tools-web-search-brave-integration ()
  "Talk to the real Brave API (needs HARNESS_INTEGRATION=1 and a key)."
  (harness-test-skip-unless-integration)
  (harness-tools-web-test--setup)
  (harness-test-with-temp-state
    (skip-unless (harness-tools-web--brave-key))
    (let* ((harness-websearch-provider 'brave)
           (r (harness-tools-web-test--call "web_search" :query "GNU Emacs text editor" :count 3))
           (c (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-match-p "\\`1\\. .+\n   https?://" c))
      (should (string-search "\n\n2. " c))
      (should (<= (plist-get (plist-get r :meta) :count) 3))
      (message "brave integration result:\n%s" c))))

(provide 'harness-tools-web-test)
;;; harness-tools-web-test.el ends here
