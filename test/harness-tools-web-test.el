;;; harness-tools-web-test.el --- Tests for web_search and web_fetch  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)

(defvar harness-brave-api-key)
(defvar harness-websearch-provider)
(defvar harness-websearch-providers)
(defvar harness-websearch-ready-functions)
(defvar harness-websearch-builtin)
(defvar harness-tools-web--auth-source-seen)
(defvar harness-tools-web--auth-source-ttl)

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

;;;; Whether web_search can search, and the model provider's own search

(defmacro harness-tools-web-test--without-key (&rest body)
  "Run BODY with Brave selected, no Brave key anywhere and no auth-source answer kept."
  (declare (indent 0))
  `(let ((process-environment (cons "BRAVE_API_KEY" process-environment))
         (auth-sources nil)
         (harness-brave-api-key nil)
         (harness-websearch-provider 'brave)
         (harness-websearch-builtin 'fallback)
         (harness-tools-web--auth-source-seen nil))
     ,@body))

(ert-deftest harness-tools-web-search-readiness ()
  "web_search can search once its provider has what it needs."
  (harness-tools-web-test--setup)
  (harness-tools-web-test--without-key
    (should-not (harness-websearch-ready-p))
    (let ((harness-brave-api-key "custom-key"))
      (should (harness-websearch-ready-p)))
    (let ((process-environment (cons "BRAVE_API_KEY=env-key" process-environment)))
      (should (harness-websearch-ready-p)))
    ;; An unknown provider cannot search; one without a check always can.
    (should-not (harness-websearch-ready-p 'missing))
    (let ((harness-websearch-providers harness-websearch-providers)
          (harness-websearch-ready-functions harness-websearch-ready-functions))
      (harness-websearch-register-provider 'plain (lambda (_q _c) nil))
      (should (harness-websearch-ready-p 'plain))
      (harness-websearch-register-provider 'keyless (lambda (_q _c) nil) #'ignore)
      (should-not (harness-websearch-ready-p 'keyless))
      (harness-websearch-register-provider 'broken (lambda (_q _c) nil) (lambda () (error "Boom")))
      (should-not (harness-websearch-ready-p 'broken))
      ;; Registered again without a check, it is ready.
      (harness-websearch-register-provider 'keyless (lambda (_q _c) nil))
      (should (harness-websearch-ready-p 'keyless))
      (let ((harness-websearch-provider 'plain))
        (should (harness-websearch-ready-p))))))

(ert-deftest harness-tools-web-search-readiness-asks-auth-source-seldom ()
  "auth-source may decrypt a file, so the check made before turns asks it seldom."
  (harness-tools-web-test--setup)
  (harness-tools-web-test--without-key
    (let ((asked 0) (stored nil))
      (cl-letf (((symbol-function 'harness-tools-web--auth-source-key)
                 (lambda (_host) (cl-incf asked) stored)))
        (should-not (harness-websearch-ready-p))
        (should-not (harness-websearch-ready-p))
        (should (= 1 asked))
        ;; A key stored meanwhile counts once the last answer is old.
        (setq stored "stored-key")
        (should-not (harness-websearch-ready-p))
        (setcar harness-tools-web--auth-source-seen
                (- (float-time) harness-tools-web--auth-source-ttl 1))
        (should (harness-websearch-ready-p))
        (should (= 2 asked))
        ;; A search that looks the key up refreshes the answer.
        (setq stored nil)
        (should-not (harness-tools-web--brave-key))
        (should (= 3 asked))
        (should-not (harness-websearch-ready-p))
        ;; The customization and the environment never wait.
        (let ((harness-brave-api-key "custom-key"))
          (should (harness-websearch-ready-p)))
        (should (= 3 asked))))))

(ert-deftest harness-tools-web-builtin-search-policy ()
  "A model provider's own search stands in for web_search while that cannot search."
  (harness-tools-web-test--setup)
  (harness-tools-web-test--without-key
    (let ((offered '("web_search")))
      (should (equal '("web_search") (harness-tools-web--builtin-tools nil nil offered)))
      (should (equal '("web_search" "other") (harness-tools-web--builtin-tools '("other") nil offered)))
      (should-not (harness-tools-web--builtin-tools nil nil '("something_else")))
      (let ((harness-brave-api-key "custom-key"))
        (should-not (harness-tools-web--builtin-tools nil nil offered))
        (let ((harness-websearch-builtin 'always))
          (should (equal '("web_search") (harness-tools-web--builtin-tools nil nil offered)))))
      (let ((harness-websearch-builtin 'never))
        (should-not (harness-tools-web--builtin-tools nil nil offered))))))

(defmacro harness-tools-web-test--with-session (model &rest body)
  "Run BODY with a session \"s1\" on MODEL, a variable BODY may set.
Models whose name starts with \"searching\" have their own web search."
  (declare (indent 1))
  `(let ((dir (harness-test-temp-dir)))
     (harness-register-method 'session/get (lambda (id) (list :id id :cwd dir :model ,model)))
     (harness-register-method 'provider/capabilities
                              (lambda (m) (and (string-prefix-p "fake:searching" m)
                                               '(:hosted-loop t :builtin-tools ("web_search")))))
     (unwind-protect (progn ,@body)
       (harness-unregister-method 'session/get)
       (harness-unregister-method 'provider/capabilities))))

(ert-deftest harness-tools-web-builtin-search-replaces-web-search ()
  "A session whose provider searches itself has no web_search of the harness's."
  (harness-tools-web-test--setup)
  (let ((model "fake:searching"))
    (harness-tools-web-test--with-session model
      (harness-tools-web-test--without-key
        (cl-flet ((names (sid) (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list sid))))
          (should (equal '("web_search") (harness-call 'tools/builtin "s1")))
          (should-not (member "web_search" (names "s1")))
          (should (member "web_fetch" (names "s1")))
          ;; Listed without a session, every tool is there.
          (should (member "web_search" (names nil)))
          ;; Once Brave has a key, web_search is the harness's again.
          (let ((harness-brave-api-key "custom-key"))
            (should-not (harness-call 'tools/builtin "s1"))
            (should (member "web_search" (names "s1"))))
          ;; A session that may not search the web gets neither.
          (let ((filter (lambda (names _s) (remove "web_search" names))))
            (harness-add-filter 'agent/tools filter)
            (unwind-protect
                (progn (should-not (harness-call 'tools/builtin "s1"))
                       (should-not (member "web_search" (names "s1"))))
              (harness-remove-filter 'agent/tools filter)))
          ;; A provider without a search of its own keeps web_search.
          (setq model "fake:plain")
          (should-not (harness-call 'tools/builtin "s1"))
          (should (member "web_search" (names "s1"))))))))

(ert-deftest harness-tools-authorize-decides-without-running ()
  "A call the provider runs is decided by the permission chain, as the harness tool's."
  (harness-tools-web-test--setup)
  (let* ((seen nil) (decided nil)
         (spy (lambda (decision next request) (push request seen) (funcall next decision)))
         (on-decided (lambda (_sid request decision) (push (cons request decision) decided))))
    (harness-add-filter 'permission/decide spy 5)
    (harness-on 'permission/decided on-decided)
    (unwind-protect
        (cl-letf (((symbol-function 'harness-http-request-json)
                   (lambda (&rest _) (error "Nothing may run"))))
          (let ((d (harness-test-await
                    (harness-call 'tools/authorize "s1" '(:id "c7" :name "web_search" :input (:query "emacs"))))))
            (should (eq 'allow (plist-get d :behavior)))
            (let ((request (car seen)))
              (should (equal "web_search" (plist-get request :tool)))
              (should (eq 'net (plist-get request :kind)))
              (should (equal "c7" (plist-get request :call-id)))
              (should (plist-get request :builtin))
              (should (equal "emacs" (plist-get (plist-get request :input) :query))))
            (should (equal "c7" (plist-get (caar decided) :call-id))))
          ;; A tool the harness lacks is judged by the kind the call names, else as exec.
          (harness-test-await (harness-call 'tools/authorize "s1" '(:id "c8" :name "mystery")))
          (should (eq 'exec (plist-get (car seen) :kind)))
          (harness-test-await (harness-call 'tools/authorize "s1" '(:id "c9" :name "mystery" :kind "read")))
          (should (eq 'read (plist-get (car seen) :kind)))
          ;; A refusal says what to tell the model.
          (let ((deny (lambda (_d next _r)
                        (funcall next '(:behavior deny :reason "not today" :hint "Try later." :final t)))))
            (harness-add-filter 'permission/decide deny 1)
            (unwind-protect
                (let ((d (harness-test-await
                          (harness-call 'tools/authorize "s1" '(:id "c10" :name "web_search" :input (:query "x"))))))
                  (should (eq 'deny (plist-get d :behavior)))
                  (should (equal "not today" (plist-get d :reason)))
                  (should (equal "Denied: not today Try later." (plist-get d :message))))
              (harness-remove-filter 'permission/decide deny)))
          ;; Nobody decides: refused.
          (harness-remove-filter 'permission/decide #'harness-tools-web-test--allow)
          (harness-remove-filter 'permission/decide spy)
          (let ((d (harness-test-await
                    (harness-call 'tools/authorize "s1" '(:id "c11" :name "web_search" :input (:query "x"))))))
            (should (eq 'deny (plist-get d :behavior)))
            (should (equal "Denied: no permission handler answered" (plist-get d :message)))))
      (harness-remove-filter 'permission/decide spy)
      (harness-add-filter 'permission/decide #'harness-tools-web-test--allow 10)
      (harness-off (cons 'permission/decided on-decided)))))

;;;; Corporate mode

(ert-deftest harness-tools-corporate-mode-offers-no-network-tools ()
  "In corporate mode no session gets a tool of kind net, nor its
provider's own search in web_search's place; other tools stay."
  (harness-tools-web-test--setup)
  (harness-test-load-module 'tools-fs)
  (harness-tools-web-test--with-session "fake:searching"
    (harness-tools-web-test--without-key
      (cl-flet ((names (sid) (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list sid))))
        (let ((harness-corporate-mode nil))
          (should (member "web_fetch" (names "s1")))
          (should (equal '("web_search") (harness-call 'tools/builtin "s1"))))
        (let ((harness-corporate-mode t))
          (should-not (member "web_fetch" (names "s1")))
          (should-not (member "web_search" (names "s1")))
          (should (member "read_file" (names "s1")))
          ;; The provider offers its search; it is not turned on.
          (should-not (harness-call 'tools/builtin "s1"))
          ;; Nor is web_search offered once Brave could search.
          (let ((harness-brave-api-key "custom-key"))
            (should-not (member "web_search" (names "s1"))))
          ;; A filter on what sessions get cannot bring them back.
          (let ((filter (lambda (names _s) (append names '("web_fetch" "web_search")))))
            (harness-add-filter 'agent/tools filter)
            (unwind-protect
                (progn (should-not (cl-intersection '("web_fetch" "web_search") (names "s1") :test #'equal))
                       (should-not (harness-call 'tools/builtin "s1")))
              (harness-remove-filter 'agent/tools filter)))
          ;; Listed without a session, for views that name tools, every
          ;; tool is there: no model is offered that list.
          (should (member "web_fetch" (names nil))))))))

(defmacro harness-tools-web-test--watching-permissions (&rest body)
  "Run BODY with every call allowed at once and the permission traffic recorded.
ASKED lists the requests the `permission/decide' chain saw, DECIDED the
\(REQUEST . DECISION) pairs of `permission/decided', FINISHED the
results of `tools/finished', newest first.  Nothing may reach the web."
  (declare (indent 0))
  `(let* ((asked nil) (decided nil) (finished nil)
          (allow-all (lambda (_d next request)
                       (push request asked)
                       (funcall next '(:behavior allow :reason "the test allows everything" :final t))))
          (on-decided (lambda (_sid request decision) (push (cons request decision) decided)))
          (on-finished (lambda (_sid _call result) (push result finished))))
     (harness-add-filter 'permission/decide allow-all 1)
     (harness-on 'permission/decided on-decided)
     (harness-on 'tools/finished on-finished)
     (unwind-protect
         (cl-letf (((symbol-function 'harness-http-request)
                    (lambda (&rest _) (error "Nothing may reach the web")))
                   ((symbol-function 'harness-http-request-json)
                    (lambda (&rest _) (error "Nothing may reach the web"))))
           ,@body)
       (harness-remove-filter 'permission/decide allow-all)
       (harness-off (cons 'permission/decided on-decided))
       (harness-off (cons 'tools/finished on-finished)))))

(ert-deftest harness-tools-corporate-mode-denies-network-calls ()
  "In corporate mode a call to a tool of kind net is denied before the
permission chain, which would allow it, and marked as denied."
  (harness-tools-web-test--setup)
  (harness-test-with-temp-state
    (harness-tools-web-test--watching-permissions
      (let ((harness-corporate-mode t))
        (dolist (call '(("web_fetch" :url "https://example.com/")
                        ("web_search" :query "emacs")))
          (let ((r (apply #'harness-tools-web-test--call call)))
            (should (plist-get r :is-error))
            (should (eq t (plist-get r :denied)))
            (should (equal (concat "Denied: corporate mode: network tools are off "
                                   harness-tools-corporate-hint)
                           (plist-get r :content)))
            ;; Decided as any call is, without asking the chain.
            (should-not asked)
            (let ((request (caar decided)) (decision (cdar decided)))
              (should (equal (car call) (plist-get request :tool)))
              (should (eq 'net (plist-get request :kind)))
              (should (eq 'deny (plist-get decision :behavior)))
              (should (equal "corporate mode: network tools are off" (plist-get decision :reason)))
              (should (string-search "do not try to reach the network another way" (plist-get decision :hint))))
            (should (equal r (car finished))))))
      (should (= 2 (length decided)))
      ;; Out of corporate mode the chain decides, and the call runs.
      (let ((harness-corporate-mode nil)
            (harness-websearch-providers harness-websearch-providers)
            (harness-websearch-ready-functions harness-websearch-ready-functions))
        (harness-websearch-register-provider 'fake (lambda (_q _c) (list (list :title "T" :url "u"))))
        (let* ((harness-websearch-provider 'fake)
               (r (harness-tools-web-test--call "web_search" :query "emacs")))
          (should-not (plist-get r :is-error))
          (should-not (plist-get r :denied))
          (should (equal "web_search" (plist-get (car asked) :tool))))))))

(ert-deftest harness-tools-corporate-mode-denies-provider-searches ()
  "In corporate mode `tools/authorize' denies a call of kind net, which
the chain would allow, and says why; other calls still go to the chain."
  (harness-tools-web-test--setup)
  (harness-tools-web-test--watching-permissions
    (let ((harness-corporate-mode t))
      (let ((d (harness-test-await
                (harness-call 'tools/authorize "s1" '(:id "c20" :name "web_search" :input (:query "x"))))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (equal "corporate mode: network tools are off" (plist-get d :reason)))
        (should (equal (concat "Denied: corporate mode: network tools are off "
                               harness-tools-corporate-hint)
                       (plist-get d :message)))
        (should-not asked)
        (should (equal "c20" (plist-get (caar decided) :call-id)))
        (should (eq 'deny (plist-get (cdar decided) :behavior))))
      ;; A tool the harness lacks, of the kind the call names.
      (should (eq 'deny (plist-get (harness-test-await
                                    (harness-call 'tools/authorize "s1" '(:id "c21" :name "WebFetch" :kind "net")))
                                   :behavior)))
      (should-not asked)
      (should (eq 'allow (plist-get (harness-test-await
                                     (harness-call 'tools/authorize "s1" '(:id "c22" :name "mystery" :kind "read")))
                                    :behavior)))
      (should (equal "c22" (plist-get (car asked) :call-id))))))

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
