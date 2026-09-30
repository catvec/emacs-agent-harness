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

(defcustom harness-web-fetch-max-chars 20000
  "Default number of characters web_fetch returns."
  :type 'integer :group 'harness)

(defcustom harness-web-fetch-timeout 30
  "Seconds a web_fetch may take."
  :type 'number :group 'harness)

(defcustom harness-web-user-agent "Mozilla/5.0 (X11; Linux x86_64) emacs-agent-harness/3.0"
  "User-Agent header sent by web_fetch."
  :type 'string :group 'harness)

(defcustom harness-web-search-max-count 20
  "Largest number of results web_search asks a provider for."
  :type 'integer :group 'harness)

(defvar harness-websearch-providers nil
  "Alist of provider name (symbol) to function (QUERY COUNT) returning a promise.
The promise resolves to a list of (:title STRING :url STRING :snippet STRING).")

(defun harness-websearch-register-provider (name fn)
  "Register FN as the search provider NAME (a symbol)."
  (setf (alist-get name harness-websearch-providers) fn)
  name)

;;;; Brave

(defconst harness-brave-search-host "api.search.brave.com")

(defun harness-tools-web--auth-source-key (host)
  "Return the secret stored in auth-source for HOST, or nil."
  (condition-case nil
      (let* ((found (car (auth-source-search :host host :max 1 :require '(:secret))))
             (secret (and found (plist-get found :secret))))
        (cond ((functionp secret) (funcall secret))
              ((stringp secret) secret)))
    (error nil)))

(defun harness-tools-web--brave-key ()
  "Return the Brave API key from the customization, the environment or auth-source."
  (let ((env (getenv "BRAVE_API_KEY")))
    (or (and (stringp harness-brave-api-key) (not (string-empty-p harness-brave-api-key)) harness-brave-api-key)
        (and env (not (string-empty-p env)) env)
        (harness-tools-web--auth-source-key harness-brave-search-host))))

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
        :timeout harness-web-fetch-timeout)
       (lambda (json)
         (mapcar (lambda (r)
                   (list :title (harness-tools-web--strip-html (plist-get r :title))
                         :url (plist-get r :url)
                         :snippet (harness-tools-web--strip-html (plist-get r :description))))
                 (harness-plist-get-in json '(:web :results))))))))

(harness-websearch-register-provider 'brave #'harness-tools-web--brave-search)

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
                  (min harness-web-search-max-count (max 1 (if (numberp c) (truncate c) 5)))))
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
  :description "Search the web. Returns a numbered list of results with title, URL and snippet; use web_fetch to read a result."
  :schema '(:type "object"
            :properties (:query (:type "string" :description "The search query")
                         :count (:type "integer" :description "Number of results, 1-20. Default 5"))
            :required ("query"))
  :kind 'net
  :title (lambda (input) (format "web_search %s" (harness-truncate-end (plist-get input :query) 60)))
  :handler #'harness-tools-web--search)

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
                     (if (and (numberp m) (> m 0)) (truncate m) harness-web-fetch-max-chars))))
    (cond
     ((or (not (stringp url)) (string-blank-p url)) (harness-tool-error "Missing url"))
     ((not (string-match-p "\\`https?://" url)) (harness-tool-error (format "Only http and https URLs are supported: %s" url)))
     (t
      (harness-with-promise (resolve reject)
        (harness-http-request
         url
         :headers (list (cons "User-Agent" harness-web-user-agent)
                        (cons "Accept" "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8"))
         :timeout harness-web-fetch-timeout
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
  :description "Fetch a URL and return its content as plain text (HTML is rendered, scripts and styles dropped). Long pages are cut at max_chars (default 20000)."
  :schema '(:type "object"
            :properties (:url (:type "string" :description "The http(s) URL to fetch")
                         :max_chars (:type "integer" :description "Maximum characters of text to return. Default 20000"))
            :required ("url"))
  :kind 'net
  :title (lambda (input) (format "web_fetch %s" (harness-truncate-middle (plist-get input :url) 70)))
  :handler #'harness-tools-web--fetch)

(harness-define-module 'tools-web
  :doc "web_search (pluggable providers, Brave built in) and web_fetch (shr rendering)."
  :requires '(tools))

(provide 'harness-tools-web)
;;; harness-tools-web.el ends here
