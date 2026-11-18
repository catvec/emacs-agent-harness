;;; demo.el --- Show the provider diagnostics lines for four attempts -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs the real OpenAI-compatible completion path
;; (`harness-openai--complete') against a fake HTTP layer, so every line
;; below is written by the code the harness runs, not by the demo.  No
;; request leaves the process: `harness-http-request' is replaced for the
;; duration and replies with a synthetic SSE stream, and the endpoint's
;; key is a literal test string.
;;
;; Four attempts in one session:
;;
;;   1. a first request, so there is nothing to compare against;
;;   2. the same request again: `prefix=identical';
;;   3. one appended user message: `prefix=appended', with the previous
;;      checkpoints preserved;
;;   4. the same conversation with a changed tool description:
;;      `prefix=diverged' at the tool-schema boundary.
;;
;; The prompt text in the fixture is a marker; the demo asserts that no
;; part of it, no tool text, and no key byte reaches a line, and prints
;; that check with the lines.

;;; Code:

(require 'harness-http)
(require 'harness-provider-openai)
(require 'harness-provider-diagnostics)

(defvar harness-state-directory)
(defvar harness-log-hook)
(defvar harness-log-level)
(defvar harness-log-filter-function)

(defconst provider-diagnostics-demo--prompt-marker
  "SECRET-PROMPT-TEXT-do-not-log"
  "Marker text the demo looks for in the log.")

(defconst provider-diagnostics-demo--tool-marker
  "SECRET-TOOL-DESCRIPTION-do-not-log"
  "Marker text in the tool schema the demo looks for in the log.")

(defvar provider-diagnostics-demo--lines nil
  "The diagnostic lines this run produced, oldest first.")

(defun provider-diagnostics-demo--sse (&rest payloads)
  "Return SSE text for PAYLOADS, strings or plists."
  (mapconcat (lambda (payload)
               (format "data: %s\n\n"
                       (if (stringp payload) payload (harness-json-encode payload))))
             payloads ""))

(defun provider-diagnostics-demo--response ()
  "Return the synthetic response body of one streamed completion."
  (list
   :status 200
   :headers '(("x-request-id" . "req-demo-1"))
   :chunks
   (list
    (provider-diagnostics-demo--sse
     (list :id "gen-demo-1" :object "chat.completion.chunk"
           :model "deepseek/deepseek-v4.1-flash-1017"
           :provider "Morph"
           :choices (list (list :index 0 :delta (list :content "Hello")
                                :finish_reason nil))))
    (provider-diagnostics-demo--sse
     (list :id "gen-demo-1" :object "chat.completion.chunk"
           :model "deepseek/deepseek-v4.1-flash-1017"
           :provider "Morph"
           :choices (list (list :index 0 :delta (list)
                                :finish_reason "stop"))
           :usage (list :prompt_tokens 1234 :completion_tokens 12 :cost 0.0004
                        :prompt_tokens_details (list :cached_tokens 1024)))))))

(defun provider-diagnostics-demo--fake-http (url &rest args)
  "Stand in for `harness-http-request' on URL with ARGS; answer offline."
  (let ((handle (make-harness-http-handle
                 :url url :callback (plist-get args :callback)
                 :on-chunk (plist-get args :on-chunk)
                 :on-headers (plist-get args :on-headers)
                 :started (float-time)))
        (response (provider-diagnostics-demo--response)))
    (harness-run-soon
     (lambda ()
       (unless (harness-http-handle-cancelled handle)
         (when (plist-get args :on-headers)
           (funcall (plist-get args :on-headers) (plist-get response :status)
                    (plist-get response :headers)))
         (when (plist-get args :on-chunk)
           (dolist (chunk (plist-get response :chunks))
             (funcall (plist-get args :on-chunk) chunk)))
         (funcall (plist-get args :callback) (plist-get response :status) nil "" nil))))
    handle))

(defconst provider-diagnostics-demo--endpoint
  '(:id demo-router :label "Demo router"
    :base-url "https://openrouter.example/api/v1"
    :api-key "sk-demo-not-a-real-key" :flavor openrouter)
  "An OpenRouter-shaped endpoint whose host never answers: HTTP is faked.")

(defun provider-diagnostics-demo--request (messages tools)
  "Return a completion request with MESSAGES and TOOLS for the demo session."
  (list :model "demo-router:deepseek/deepseek-v4.1-flash-1017"
        :session (list :id "demo")
        :system (concat "You are a demo. " provider-diagnostics-demo--prompt-marker ".")
        :messages messages
        :tools tools
        :max-tokens 64))

(defun provider-diagnostics-demo--complete (request)
  "Run REQUEST through the provider path and wait for it to finish."
  (let ((done nil))
    (setq request (plist-put request :on-event
                             (lambda (event)
                               (when (eq (plist-get event :type) 'done)
                                 (setq done t)))))
    (cl-letf (((symbol-function 'harness-http-request)
               #'provider-diagnostics-demo--fake-http))
      (harness-openai--complete provider-diagnostics-demo--endpoint request))
    (let ((deadline (+ (float-time) 5)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.02)))
    done))

(defun provider-diagnostics-demo--tools (&optional description)
  "Return tool specs whose description is DESCRIPTION or a marker."
  (list (list :name "read_file"
              :description (or description
                               (concat "Read a file. "
                                       provider-diagnostics-demo--tool-marker))
              :schema '(:type "object"
                        :properties (:path (:type "string"))
                        :required ["path"]))))

(defconst provider-diagnostics-demo--buffer-name "*provider-diagnostics demo*"
  "Buffer `provider-diagnostics-demo-present' writes its lines into.")

(defun provider-diagnostics-demo-present ()
  "Run the demo and show its lines in a buffer, which it returns.
`provider-diagnostics-demo-run' prints to standard output instead, for
a batch run; this is the same run with the lines where a person can
read them."
  (interactive)
  (let ((lines (provider-diagnostics-demo-run))
        (buffer (get-buffer-create provider-diagnostics-demo--buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Provider diagnostics: four attempts, offline.\n\
Nothing was sent anywhere; the HTTP layer was faked.\n\n"))
        (dolist (line lines)
          (insert line "\n\n"))
        (insert "leak check: no prompt marker, tool description, key or API key in any line\n")
        (goto-char (point-min))
        (special-mode)))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(defun provider-diagnostics-demo-run ()
  "Run the four attempts and return the diagnostic lines, oldest first."
  (let ((dir (file-name-as-directory (make-temp-file "provider-diagnostics-demo-" t)))
        (harness-log-hook nil)
        (harness-log-level 'info)
        (harness-log-filter-function nil)
        (harness-provider-diagnostics-enabled t)
        (harness-provider-diagnostics-key-file nil)
        (harness-provider-diagnostics--key 'unset)
        (harness-provider-diagnostics--last (make-hash-table :test 'equal))
        (harness-provider-diagnostics--last-order nil)
        (harness-provider-diagnostics--sequence 0)
        (harness-provider-diagnostics--warned nil)
        (provider-diagnostics-demo--lines nil))
    (unwind-protect
        (progn
          (setq harness-state-directory dir
                harness-log-hook
                (list (lambda (_level message)
                        (when (string-prefix-p "provider-diagnostics:" message)
                          (push message provider-diagnostics-demo--lines)))))
          (let ((first (list (list :role "user"
                                   :content provider-diagnostics-demo--prompt-marker)))
                (appended (list (list :role "user"
                                      :content provider-diagnostics-demo--prompt-marker)
                                (list :role "assistant" :content "Hi.")
                                (list :role "user" :content "And again."))))
            ;; 1: first, 2: identical retry, 3: appended, 4: tool change.
            (provider-diagnostics-demo--complete
             (provider-diagnostics-demo--request first (provider-diagnostics-demo--tools)))
            (provider-diagnostics-demo--complete
             (provider-diagnostics-demo--request first (provider-diagnostics-demo--tools)))
            (provider-diagnostics-demo--complete
             (provider-diagnostics-demo--request appended (provider-diagnostics-demo--tools)))
            (provider-diagnostics-demo--complete
             (provider-diagnostics-demo--request
              appended (provider-diagnostics-demo--tools "Read a file, carefully."))))
          (setq provider-diagnostics-demo--lines
                (nreverse provider-diagnostics-demo--lines))
          ;; The key is never in a line, in any form it could take.
          (let* ((key-text (harness-read-file (harness-provider-diagnostics-key-file)))
                 (key (harness-provider-diagnostics--decode-key key-text))
                 (key-hex (harness-provider-diagnostics--hex key))
                 (all (mapconcat #'identity provider-diagnostics-demo--lines "\n")))
            (dolist (secret (list provider-diagnostics-demo--prompt-marker
                                  provider-diagnostics-demo--tool-marker
                                  key-text (string-trim key-text) key-hex
                                  "sk-demo-not-a-real-key"))
              (when (and secret (not (string-empty-p secret))
                         (string-match-p (regexp-quote secret) all))
                (error "A secret reached the log: %S" secret)))
            (princ (format "key file: %s (mode %o), key=%s, lines=%d\n\n"
                           (harness-provider-diagnostics-key-file)
                           (file-modes (harness-provider-diagnostics-key-file))
                           (harness-provider-diagnostics--key-id key)
                           (length provider-diagnostics-demo--lines))))
          (dolist (line provider-diagnostics-demo--lines)
            (princ (concat line "\n\n")))
          (princ "leak check: no prompt marker, tool description, key or API key in any line\n")
          provider-diagnostics-demo--lines)
      (ignore-errors (delete-directory dir t)))))

(provide 'provider-diagnostics-demo)
;;; demo.el ends here
