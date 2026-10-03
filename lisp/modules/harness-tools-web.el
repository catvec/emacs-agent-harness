;;; harness-tools-web.el --- Web search and fetch tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; `web_search' asks a pluggable search provider for results and
;; `web_fetch' downloads a page and renders it to plain text with shr.
;; Both go through `harness-http' (asynchronous curl) so nothing blocks.
;;
;; Search providers are functions (QUERY COUNT) returning a promise of
;; result plists (:title :url :snippet), registered in
;; `harness-websearch-providers'.  The built-in `brave' provider talks
;; to the Brave Search API; its key comes from `harness-brave-api-key',
;; the BRAVE_API_KEY environment variable, or auth-source (host
;; api.search.brave.com), in that order.  Add another provider with
;; `harness-websearch-register-provider' and select it with
;; `harness-websearch-provider'.
;;
;; Some model providers search the web themselves: Claude Code has its
;; WebSearch tool, GitHub Copilot CLI its web_search.  Until a search
;; provider here is ready to search (Brave without a key is not), a
;; session on such a provider uses that search in place of web_search,
;; so searching works out of the box; `harness-websearch-builtin' says
;; when.  The provider's search is still a web_search call to the
;; harness: its permission rules decide it and the transcript shows it
;; (see `tools/builtin' and `tools/authorize').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'auth-source)
(require 'shr)
(require 'dom)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-tools)

(defcustom harness-websearch-provider 'brave
  "Search provider used by web_search.
A key of `harness-websearch-providers'."
  :type 'symbol :group 'harness)

(defcustom harness-brave-api-key nil
  "Brave Search API subscription token.
When nil the BRAVE_API_KEY environment variable and auth-source (host
api.search.brave.com) are consulted."
  :type '(choice (const nil) string) :group 'harness)

(defconst harness-tools-web--fetch-max-chars 20000
  "Default number of characters web_fetch returns.")

(defconst harness-tools-web--fetch-timeout 30
  "Seconds a web_fetch may take.")

(defconst harness-tools-web--user-agent "Mozilla/5.0 (X11; Linux x86_64) emacs-agent-harness/3.0"
  "User-Agent header sent by web_fetch.")

(defconst harness-tools-web--search-max-count 20
  "Largest number of results web_search asks a provider for.")

(defcustom harness-websearch-builtin 'fallback
  "When a session searches the web with its model provider's own search.
Claude Code (WebSearch) and GitHub Copilot CLI (web_search) can search
the web themselves.  A session on such a provider can use that search
in place of web_search:
  `fallback'  while `harness-websearch-provider' cannot search (Brave
              without an API key, say), so searching works before
              anything is set up and the configured provider takes
              over once it is;
  `always'    whenever the session's provider has a search of its own;
  `never'     never: web_search always uses `harness-websearch-provider'.
The provider's search is decided by the permission rules for web_search
and shows as web_search calls."
  :type '(choice (const :tag "While web_search has no working search provider" fallback)
                 (const :tag "Whenever the model's provider can search" always)
                 (const :tag "Never" never))
  :group 'harness)

(defvar harness-websearch-providers nil
  "Alist of provider name (symbol) to function (QUERY COUNT) returning a promise.
The promise resolves to a list of (:title STRING :url STRING :snippet STRING).")

(defvar harness-websearch-ready-functions nil
  "Alist of provider name (symbol) to a function saying whether it can search.
The function takes no arguments and returns non-nil when the provider
has what it needs (an API key, say).  A provider without one is ready
whenever it is registered.")

(defun harness-websearch-register-provider (name fn &optional ready)
  "Register FN as the search provider NAME (a symbol).
READY, when given, is a function of no arguments that returns non-nil
when the provider can search now, for instance because its API key is
set; see `harness-websearch-ready-p'.  It runs before turns, so it must
be quick."
  (setf (alist-get name harness-websearch-providers) fn)
  (setf (alist-get name harness-websearch-ready-functions nil 'remove) ready)
  name)

(defun harness-websearch-ready-p (&optional provider)
  "Non-nil when web_search can search with PROVIDER.
PROVIDER defaults to `harness-websearch-provider'.  It must be
registered, and its readiness function (see
`harness-websearch-register-provider') must say yes."
  (let* ((provider (or provider harness-websearch-provider))
         (ready (alist-get provider harness-websearch-ready-functions)))
    (and (alist-get provider harness-websearch-providers)
         (or (null ready)
             (condition-case err
                 (funcall ready)
               (error
                (harness-log 'warn "web search: checking provider %s failed: %s"
                             provider (harness-error-message err))
                nil)))
         t)))

;;;; Brave

(defconst harness-brave-search-host "api.search.brave.com")

(defconst harness-tools-web--auth-source-ttl 300
  "Seconds the readiness check trusts what auth-source said about the Brave key.
Looking a key up may decrypt a file, and ask for its passphrase, so the
check that runs before every turn does it this seldom.")

(defvar harness-tools-web--auth-source-seen nil
  "When auth-source was last asked for the Brave key, and whether it had one.
A cons (FLOAT-TIME . FOUND), or nil before the first lookup.")

(defun harness-tools-web--auth-source-key (host)
  "Return the secret stored in auth-source for HOST, or nil."
  (condition-case nil
      (let* ((found (car (auth-source-search :host host :max 1 :require '(:secret))))
             (secret (and found (plist-get found :secret))))
        (cond ((functionp secret) (funcall secret))
              ((stringp secret) secret)))
    (error nil)))

(defun harness-tools-web--brave-set-key ()
  "Return the Brave API key from the customization or the environment, or nil."
  (let ((env (getenv "BRAVE_API_KEY")))
    (or (and (stringp harness-brave-api-key) (not (string-empty-p harness-brave-api-key)) harness-brave-api-key)
        (and env (not (string-empty-p env)) env))))

(defun harness-tools-web--brave-stored-key ()
  "Return the Brave API key stored in auth-source, or nil.
Remember whether there is one, for `harness-tools-web--brave-ready-p'."
  (let ((key (harness-tools-web--auth-source-key harness-brave-search-host)))
    (setq harness-tools-web--auth-source-seen (cons (float-time) (and key t)))
    key))

(defun harness-tools-web--brave-key ()
  "Return the Brave API key from the customization, the environment or auth-source."
  (or (harness-tools-web--brave-set-key)
      (harness-tools-web--brave-stored-key)))

(defun harness-tools-web--brave-ready-p ()
  "Non-nil when Brave has an API key.
The customization and the environment are read every time; auth-source
is asked again only once `harness-tools-web--auth-source-ttl' seconds
have passed since it was last asked."
  (or (and (harness-tools-web--brave-set-key) t)
      (let ((seen harness-tools-web--auth-source-seen))
        (if (and seen (< (- (float-time) (car seen)) harness-tools-web--auth-source-ttl))
            (cdr seen)
          (and (harness-tools-web--brave-stored-key) t)))))

(defun harness-tools-web--strip-html (text)
  "Remove tags from TEXT and decode the common entities."
  (let ((s (replace-regexp-in-string "<[^>]*>" "" (or text ""))))
    (dolist (pair '(("&amp;" . "&") ("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"")
                    ("&#39;" . "'") ("&#x27;" . "'") ("&nbsp;" . " ")))
      (setq s (string-replace (car pair) (cdr pair) s)))
    (string-trim s)))

(defun harness-tools-web--brave-search (query count)
  "Search Brave for QUERY, returning a promise of COUNT results."
  (let ((key (harness-tools-web--brave-key)))
    (if (null key)
        (harness-rejected (list 'harness-error "No Brave Search API key: set harness-brave-api-key, the BRAVE_API_KEY environment variable, or an auth-source entry for api.search.brave.com"))
      (harness-then
       (harness-http-request-json
        (format "https://%s/res/v1/web/search?q=%s&count=%d"
                harness-brave-search-host (url-hexify-string query) count)
        :headers (list (cons "Accept" "application/json")
                       (cons "X-Subscription-Token" key))
        :timeout harness-tools-web--fetch-timeout)
       (lambda (json)
         (mapcar (lambda (r)
                   (list :title (harness-tools-web--strip-html (plist-get r :title))
                         :url (plist-get r :url)
                         :snippet (harness-tools-web--strip-html (plist-get r :description))))
                 (harness-plist-get-in json '(:web :results))))))))

(harness-websearch-register-provider 'brave #'harness-tools-web--brave-search
                                     #'harness-tools-web--brave-ready-p)

;;;; web_search

(defun harness-tools-web--format-results (results query)
  "Format RESULTS for QUERY as a numbered list."
  (if (null results)
      (format "No results for %s" query)
    (let ((n 0))
      (mapconcat (lambda (r)
                   (cl-incf n)
                   (format "%d. %s\n   %s%s" n (or (plist-get r :title) "(untitled)")
                           (or (plist-get r :url) "")
                           (let ((s (plist-get r :snippet)))
                             (if (and s (not (string-empty-p s))) (concat "\n   " s) ""))))
                 results "\n\n"))))

(defun harness-tools-web--search (input _ctx)
  "Handler for web_search with INPUT; returns a promise."
  (let* ((query (plist-get input :query))
         (count (let ((c (plist-get input :count)))
                  (min harness-tools-web--search-max-count (max 1 (if (numberp c) (truncate c) 5)))))
         (fn (alist-get harness-websearch-provider harness-websearch-providers)))
    (cond
     ((or (not (stringp query)) (string-blank-p query)) (harness-tool-error "Missing query"))
     ((null fn) (harness-tool-error (format "Unknown web search provider %s; known: %s"
                                            harness-websearch-provider
                                            (mapconcat (lambda (p) (symbol-name (car p))) harness-websearch-providers ", "))))
     (t
      (harness-then
       (harness-as-promise (funcall fn query count))
       (lambda (results)
         (harness-tool-ok (harness-tools-web--format-results results query)
                          :meta (list :provider harness-websearch-provider :count (length results))))
       (lambda (err)
         (harness-tool-error (format "Web search failed (%s): %s" harness-websearch-provider
                                     (harness-error-message err)))))))))

(harness-define-tool "web_search"
  :label "Web search"
  :description "Search the web. Returns a numbered list of results with title, URL and snippet; use web_fetch to read a result."
  :schema '(:type "object"
            :properties (:query (:type "string" :description "The search query")
                         :count (:type "integer" :description "Number of results, 1-20. Default 5"))
            :required ("query"))
  :kind 'net
  :subject (lambda (input) (harness-first-line (plist-get input :query) 60))
  :handler #'harness-tools-web--search)

;;;; The model provider's own search

(defun harness-tools-web--use-builtin-p ()
  "Non-nil when a model provider's own search should stand in for web_search.
See `harness-websearch-builtin'."
  (pcase harness-websearch-builtin
    ('always t)
    ('never nil)
    (_ (not (harness-websearch-ready-p)))))

(defun harness-tools-web--builtin-tools (names _session offered)
  "Add web_search to NAMES when the model provider's own search should run it.
OFFERED lists the harness tools the provider has counterparts of.  A
filter on `agent/builtin-tools' (see `tools/builtin')."
  (if (and (member "web_search" offered)
           (not (member "web_search" names))
           (harness-tools-web--use-builtin-p))
      (cons "web_search" names)
    names))

(defun harness-tools-web--init ()
  "Offer web_search to model providers that search themselves (idempotent)."
  (harness-add-filter 'agent/builtin-tools #'harness-tools-web--builtin-tools))

(harness-tools-web--init)

;;;; web_fetch

(defun harness-tools-web--html-p (headers body)
  "Non-nil when the response with HEADERS and BODY is HTML."
  (let ((ct (cdr (assoc "content-type" headers))))
    (or (and ct (string-match-p "html\\|xml" ct))
        (and (null ct) (string-match-p "\\`[ \t\n\r]*<\\(!doctype\\|html\\)" (downcase (substring body 0 (min 200 (length body)))))))))

(defun harness-tools-web--render-html (body)
  "Render HTML BODY to plain text with shr.  Return (TITLE . TEXT)."
  (if (not (and (fboundp 'libxml-available-p) (libxml-available-p)))
      (cons nil (harness-tools-web--strip-html body))
    (let* ((dom (with-temp-buffer
                  (insert body)
                  (libxml-parse-html-region (point-min) (point-max))))
           (title (let ((node (car (dom-by-tag dom 'title))))
                    (and node (string-trim (mapconcat (lambda (c) (if (stringp c) c "")) (dom-children node) ""))))))
      (cons (and title (not (string-empty-p title)) title)
            (with-temp-buffer
              (let ((shr-width 80) (shr-use-fonts nil) (shr-inhibit-images t))
                (shr-insert-document dom))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (string-trim (replace-regexp-in-string "\n\\{3,\\}" "\n\n" text))))))))

(defun harness-tools-web--fetch (input _ctx)
  "Handler for web_fetch with INPUT; returns a promise."
  (let ((url (plist-get input :url))
        (max-chars (let ((m (plist-get input :max_chars)))
                     (if (and (numberp m) (> m 0)) (truncate m) harness-tools-web--fetch-max-chars))))
    (cond
     ((or (not (stringp url)) (string-blank-p url)) (harness-tool-error "Missing url"))
     ((not (string-match-p "\\`https?://" url)) (harness-tool-error (format "Only http and https URLs are supported: %s" url)))
     (t
      (harness-with-promise (resolve reject)
        (harness-http-request
         url
         :headers (list (cons "User-Agent" harness-tools-web--user-agent)
                        (cons "Accept" "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8"))
         :timeout harness-tools-web--fetch-timeout
         :callback
         (lambda (status headers body err)
           (funcall
            resolve
            (cond
             (err (harness-tool-error (format "Fetch failed for %s: %s" url (if (consp err) (format "%s" (cadr err)) err))))
             ((or (null status) (< status 200) (>= status 300))
              (harness-tool-error (format "HTTP %s for %s%s" status url
                                          (if (and body (not (string-empty-p body)))
                                              (concat "\n" (harness-truncate-end (harness-tools-web--strip-html body) 500))
                                            ""))))
             (t
              (let* ((html (harness-tools-web--html-p headers body))
                     (rendered (if html (harness-tools-web--render-html body) (cons nil (or body ""))))
                     (text (cdr rendered))
                     (total (length text))
                     (shown (if (> total max-chars) (substring text 0 max-chars) text)))
                (harness-tool-ok
                 (concat (format "URL: %s\n" url)
                         (if (car rendered) (format "Title: %s\n" (car rendered)) "")
                         (format "Type: %s\n\n" (or (cdr (assoc "content-type" headers)) (if html "text/html" "text/plain")))
                         shown
                         (if (> total max-chars)
                             (format "\n\n[Truncated: %d of %d characters shown. Raise max_chars to read more]" max-chars total)
                           ""))
                 :meta (list :status status :chars total :html html)))))))))))))

(harness-define-tool "web_fetch"
  :label "Fetch page"
  :description "Fetch a URL and return its content as plain text (HTML is rendered, scripts and styles dropped). Long pages are cut at max_chars (default 20000)."
  :schema '(:type "object"
            :properties (:url (:type "string" :description "The http(s) URL to fetch")
                         :max_chars (:type "integer" :description "Maximum characters of text to return. Default 20000"))
            :required ("url"))
  :kind 'net
  :subject (lambda (input) (harness-truncate-middle (or (plist-get input :url) "") 70))
  :handler #'harness-tools-web--fetch)

(harness-define-module 'tools-web
  :doc "Web search (pluggable providers, Brave built in; else the model provider's own search) and Fetch page (rendered with shr)."
  :requires '(tools)
  :init #'harness-tools-web--init)

(provide 'harness-tools-web)
;;; harness-tools-web.el ends here
