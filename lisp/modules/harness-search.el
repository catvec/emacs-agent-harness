;;; harness-search.el --- Web search tool -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The `websearch' tool, implemented on top of a small provider registry so
;; a user (or another module) can drop in any search backend.  The built-in
;; provider talks to the Brave Search API and needs a key in
;; `harness-search-brave-api-key' (defaults to $BRAVE_API_KEY).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-util)
(require 'harness-core)
(require 'harness-http)
(require 'harness-tools)

(defcustom harness-search-brave-api-key (getenv "BRAVE_API_KEY")
  "API key for the Brave Search API.
Defaults to the BRAVE_API_KEY environment variable."
  :type '(choice string (const nil)))

(defcustom harness-search-default-count 5
  "Results returned when the model does not ask for a count."
  :type 'natnum)

(defcustom harness-search-max-count 20
  "Maximum results a single search may return (Brave's limit)."
  :type 'natnum)

(defcustom harness-search-timeout 20
  "Seconds before a web search is given up."
  :type 'number)

(defcustom harness-search-result-chars 300
  "Maximum characters of each result description."
  :type 'natnum)

(cl-defstruct (harness-search-provider
               (:constructor harness-search-provider-create))
  name description function)

(defvar harness-search--providers (make-hash-table :test #'equal)
  "Registered search providers, name -> provider.")

(defvar harness-search--order nil
  "Provider names in registration order (first is used by default).")

(defun harness-search-register-provider (name &rest properties)
  "Register a search provider NAME.
PROPERTIES: :function (QUERY COUNT) returning a deferred of result
plists (:title :url :description), :description for tool help."
  (puthash name
           (harness-search-provider-create
            :name name
            :description (plist-get properties :description)
            :function (plist-get properties :function))
           harness-search--providers)
  (unless (member name harness-search--order)
    (setq harness-search--order (append harness-search--order (list name))))
  name)

(defun harness-search-unregister-provider (name)
  "Remove provider NAME."
  (remhash name harness-search--providers)
  (setq harness-search--order (remove name harness-search--order))
  nil)

(defun harness-search-providers ()
  "Return the registered provider names."
  (seq-filter (lambda (name) (gethash name harness-search--providers))
              harness-search--order))

(defun harness-search--provider (&optional name)
  "Return provider NAME, defaulting to the first registered one."
  (gethash (or name (car (harness-search-providers))) harness-search--providers))

;;; Built-in Brave provider

(defun harness-search--strip-html (text)
  "Remove tags and decode the common entities in TEXT."
  (when text
    (let ((clean (replace-regexp-in-string "<[^>]*>" "" text)))
      (dolist (pair '(("&amp;" . "&") ("&lt;" . "<") ("&gt;" . ">")
                      ("&quot;" . "\"") ("&#39;" . "'") ("&#x27;" . "'")
                      ("&apos;" . "'") ("&nbsp;" . " ")))
        (setq clean (replace-regexp-in-string (regexp-quote (car pair)) (cdr pair) clean)))
      (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " clean)))))

(defun harness-search-brave (query count)
  "Search the web with the Brave Search API.
Returns a deferred of result plists."
  (if (or (null harness-search-brave-api-key)
          (string-empty-p harness-search-brave-api-key))
      (let ((deferred (harness-deferred-new)))
        (harness-deferred-reject
         deferred
         (list 'harness-user-error
               "Web search is not configured: set BRAVE_API_KEY (or harness-search-brave-api-key)."))
        deferred)
    (let ((url (format "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"
                       (url-hexify-string query)
                       (min count harness-search-max-count))))
      (harness-deferred-then
       (harness-http-fetch url
                           :headers `(("Accept" . "application/json")
                                      ("X-Subscription-Token" . ,harness-search-brave-api-key))
                           :timeout harness-search-timeout)
       (lambda (response)
         (let* ((status (harness-http-response-status response))
                (body (harness-http-response-body response)))
           (unless (and status (>= status 200) (< status 300))
             (signal 'harness-user-error
                     (list (format "Brave search failed with HTTP %s" status))))
           (let* ((parsed (json-parse-string body :object-type 'plist))
                  (web (plist-get parsed :web))
                  (results (append (plist-get web :results) nil)))
             (mapcar (lambda (result)
                       (list :title (harness-search--strip-html (plist-get result :title))
                             :url (plist-get result :url)
                             :description (harness-search--strip-html
                                           (plist-get result :description))))
                     results))))))))

;;; The tool

(defun harness-search--format (query results)
  "Format RESULTS for QUERY as the tool's text."
  (if (null results)
      (format "No web results for “%s”." query)
    (concat (format "Web results for “%s”:\n" query)
            (string-join
             (cl-loop for result in results
                      for index from 1
                      collect (format "%d. %s\n   %s\n   %s"
                                      index
                                      (or (plist-get result :title) "(untitled)")
                                      (or (plist-get result :url) "")
                                      (truncate-string-to-width
                                       (or (plist-get result :description) "")
                                       harness-search-result-chars nil nil "…")))
             "\n\n"))))

(defun harness-search-tool (arguments _context)
  "Tool handler: search the web with the active provider."
  (let* ((query (plist-get arguments :query))
         (count (or (plist-get arguments :count) harness-search-default-count))
         (provider (harness-search--provider)))
    (cond
     ((or (null query) (string-empty-p (string-trim query)))
      (harness-tool-error-result "A web search needs a query."))
     ((null provider)
      (harness-tool-error-result
       "No web search provider is configured.  Set BRAVE_API_KEY (or register one with `harness-search-register-provider')."))
     (t
      (harness-deferred-then
       (funcall (harness-search-provider-function provider)
                (string-trim query) (max 1 (min count harness-search-max-count)))
       (lambda (results)
         (harness-search--format (string-trim query) results))
       (lambda (error)
         (harness-tool-error-result
          (format "Web search failed: %s"
                  (if (and (listp error) (stringp (cadr error)))
                      (cadr error)
                    (format "%S" error))))))))))

(defun harness-search-setup ()
  "Set up the web search module."
  (harness-search-register-provider
   "brave"
   :description "Brave Search API"
   :function #'harness-search-brave)
  (harness-tool-register
   "websearch"
   :description "Search the web and get titles, URLs and snippets. Use it for current information not in the repository."
   :schema '(:type "object"
             :properties (:query (:type "string" :description "Search query.")
                          :count (:type "integer"
                                  :description "How many results (default 5, max 20)."))
             :required ["query"])
   :kind 'read
   :read-only t
   :handler #'harness-search-tool))

(defun harness-search-teardown ()
  "Tear down the web search module."
  (harness-tool-unregister "websearch")
  (harness-search-unregister-provider "brave"))

(harness-module-define 'harness-search
  :version harness-version
  :description "Web search tool with drop-in providers (Brave built in)."
  :requires '((harness-core "0.1.0")
              (harness-http "0.1.0")
              (harness-tools "0.1.0"))
  :provides '(harness-search)
  :setup #'harness-search-setup
  :teardown #'harness-search-teardown)

(provide 'harness-search)
;;; harness-search.el ends here
