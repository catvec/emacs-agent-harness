;;; harness-provider-openai.el --- OpenAI-compatible provider -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://github.com/noahhuppert/emacs-agent-harness

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The reference provider: `POST {base-url}/chat/completions' with
;; `stream: true'.  Covers LiteLLM, DeepSeek, OpenAI, Groq, Together, vLLM,
;; llama.cpp's server, Ollama's OpenAI endpoint, OpenRouter and anything else
;; that speaks the same dialect.
;;
;; Two details are worth knowing:
;;
;; - Reasoning traces (`reasoning_content' / `reasoning' deltas) are streamed
;;   to the caller but never sent back in a request; DeepSeek rejects requests
;;   that contain them.
;; - The JSON of each finished message is cached on the message's meta plist,
;;   so sending a 200 message transcript re-encodes only the new messages.
;;   Finished messages are immutable, which is what makes the cache safe.
;;
;; See DESIGN.md section 5.5.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-http)
(require 'harness-provider)

(defcustom harness-openai-default-max-tokens nil
  "Value sent as `max_tokens' when a request does not specify one.
Nil omits the field, letting the server decide."
  :type '(choice (const :tag "Server default" nil) integer)
  :group 'harness-providers)

(cl-defstruct (harness-provider-openai (:include harness-provider)
                                       (:constructor harness-provider-openai--make)
                                       (:copier nil))
  "An OpenAI-compatible chat completions endpoint.")

(defun harness-provider-openai-create (spec)
  "Build an OpenAI-compatible provider from configuration plist SPEC."
  (harness-provider-openai--make
   :name (harness-plist-or-alist-get :name spec)
   :kind 'openai
   :label (or (harness-plist-or-alist-get :label spec)
              (format "%s" (harness-plist-or-alist-get :name spec)))
   :base-url (or (harness-plist-or-alist-get :base-url spec)
                 "https://api.openai.com/v1")
   :api-key (harness-plist-or-alist-get :api-key spec)
   :api-key-env (harness-plist-or-alist-get :api-key-env spec)
   :headers (harness-plist-or-alist-get :headers spec)
   :caps (harness-plist-or-alist-get :capabilities spec)
   :options spec))

(harness-register-provider-kind 'openai #'harness-provider-openai-create)

(defun harness-provider-openai--url (provider path)
  "Return PROVIDER's base URL joined with PATH."
  (concat (string-remove-suffix "/" (or (harness-provider-base-url provider)
                                        ""))
          path))

(defun harness-provider-openai--headers (provider stream)
  "Return the request headers for PROVIDER.
STREAM selects the server-sent-events Accept header."
  (append (harness-provider-headers provider)
          (list (cons "Content-Type" "application/json")
                (cons "Accept" (if stream "text/event-stream" "application/json")))
          (when-let* ((key (harness-provider-resolve-api-key provider)))
            (list (cons "Authorization" (concat "Bearer " key))))))

(cl-defmethod harness-provider-capabilities ((_provider harness-provider-openai))
  "OpenAI-compatible endpoints stream text, tools, reasoning and usage."
  '(:streaming t :tools t :reasoning t :images nil
    :usage-in-stream t :system-role system))

(cl-defmethod harness-provider-cancel ((_provider harness-provider-openai) handle)
  "Cancel the underlying HTTP request HANDLE."
  (when handle (harness-http-cancel handle)))


;;; Wire format

(defun harness-provider-openai--wire-message (message)
  "Convert MESSAGE to the OpenAI wire representation (an alist).
Return nil for messages that must not be sent."
  (let ((role (harness-message-role message))
        (content (or (harness-message-content message) ""))
        (calls (harness-message-tool-calls message)))
    (pcase role
      ('system (list (cons 'role "system") (cons 'content content)))
      ('user (list (cons 'role "user") (cons 'content content)))
      ('tool (list (cons 'role "tool")
                   (cons 'tool_call_id (or (harness-message-tool-call-id message) ""))
                   (cons 'content (if (string-empty-p content) "(no output)" content))))
      ('assistant
       (cond
        ((and (string-empty-p content) (null calls)) nil)
        (t (append (list (cons 'role "assistant")
                         (cons 'content content))
                   ;; NOTE: reasoning traces are deliberately dropped; several
                   ;; backends reject requests that echo them back.
                   (when calls
                     (list (cons 'tool_calls
                                 (harness-json-array
                                  (mapcar #'harness-provider-openai--wire-tool-call
                                         calls)))))))))
      (_ nil))))

(defun harness-provider-openai--wire-tool-call (tool-call)
  "Convert TOOL-CALL to the OpenAI `tool_calls' entry shape."
  (list (cons 'id (or (harness-tool-call-id tool-call) ""))
        (cons 'type "function")
        (cons 'function
              (list (cons 'name (or (harness-tool-call-name tool-call) ""))
                    (cons 'arguments (or (harness-tool-call-args-string tool-call)
                                         "{}"))))))

(defun harness-provider-openai--message-json (message)
  "Return MESSAGE as a JSON string, cached on finished messages."
  (or (plist-get (harness-message-meta message) :wire-json)
      (let ((json (harness-json-write (harness-provider-openai--wire-message message))))
        (when (eq (harness-message-status message) 'complete)
          (setf (harness-message-meta message)
                (plist-put (harness-message-meta message) :wire-json json)))
        json)))

(defun harness-provider-openai--system-json (system)
  "Return the JSON for a system prompt string SYSTEM."
  (harness-json-write (list (cons 'role "system") (cons 'content system))))

(defun harness-provider-openai--request-body (request)
  "Serialise REQUEST to an OpenAI chat completions JSON body.

The messages array is assembled from cached per-message JSON strings so that a
long conversation is not re-encoded on every turn."
  (let* ((messages (harness-provider-request-messages request))
         (system (harness-provider-request-system request))
         (tools (harness-provider-request-tools request))
         (encoded (delq nil (mapcar #'harness-provider-openai--message-json messages)))
         (fields nil))
    (when (and system (not (string-empty-p system)))
      ;; The system prompt goes first; `encoded' is already in transcript
      ;; order, so it must not be reversed here.
      (setq encoded (cons (harness-provider-openai--system-json system) encoded)))
    (push (format "\"model\":%s"
                  (harness-json-write (harness-provider-request-model request)))
          fields)
    (push "\"stream\":true" fields)
    (push "\"stream_options\":{\"include_usage\":true}" fields)
    (push (format "\"messages\":[%s]" (string-join encoded ",")) fields)
    (when tools
      (push (format "\"tools\":%s" (harness-json-write tools)) fields))
    (when (harness-provider-request-temperature request)
      (push (format "\"temperature\":%s"
                    (harness-json-write (harness-provider-request-temperature request)))
            fields))
    (let ((max-tokens (or (harness-provider-request-max-tokens request)
                          harness-openai-default-max-tokens)))
      (when max-tokens
        (push (format "\"max_tokens\":%s" (harness-json-write max-tokens)) fields)))
    (concat "{" (string-join (nreverse fields) ",") "}")))

(defun harness-provider-openai--parse-usage (usage)
  "Convert wire USAGE to a harness usage plist."
  (when (listp usage)
    (let ((cached (let ((details (harness-alist-get :prompt_tokens_details usage)))
                    (or (and details (harness-alist-get :cached_tokens details)) 0))))
      (list :in (or (harness-alist-get :prompt_tokens usage) 0)
            :out (or (harness-alist-get :completion_tokens usage) 0)
            :cache-read (or (harness-alist-get :prompt_cache_hit_tokens usage)
                            cached 0)
            :cache-write (or (harness-alist-get :prompt_cache_miss_tokens usage) 0)))))


;;; Streaming

(defun harness-provider-openai--handle-event (state callbacks event)
  "Handle one SSE EVENT, updating STATE and calling CALLBACKS."
  (unless (equal event "[DONE]")
    (let ((data (condition-case err
                    (harness-json-read event)
                  (error
                   (harness--log "bad SSE payload: %s" (error-message-string err))
                   nil))))
      (when data
        (when-let* ((usage (harness-alist-get :usage data)))
          (when (listp usage)
            (setf (plist-get state :usage)
                  (harness-provider-openai--parse-usage usage))
            (when-let* ((fn (plist-get callbacks :on-usage)))
              (funcall fn (plist-get state :usage)))))
        (let ((choice (car (harness-alist-get :choices data))))
          (when choice
            (when-let* ((finish (harness-alist-get :finish_reason choice)))
              (unless (eq finish :false)
                (setf (plist-get state :finish) finish)))
            (let ((delta (harness-alist-get :delta choice)))
              (when delta
                (let ((text (harness-alist-get :content delta))
                      (reasoning (or (harness-alist-get :reasoning_content delta)
                                     (harness-alist-get :reasoning delta))))
                  (when (and reasoning (not (string-empty-p (format "%s" reasoning))))
                    (when-let* ((fn (plist-get callbacks :on-delta)))
                      (funcall fn 'thinking (format "%s" reasoning))))
                  (when (and text (not (string-empty-p (format "%s" text))))
                    (when-let* ((fn (plist-get callbacks :on-delta)))
                      (funcall fn 'text (format "%s" text))))
                  (when-let* ((calls (harness-alist-get :tool_calls delta)))
                    (when (listp calls)
                      (dolist (call calls)
                        (harness-provider-openai--accumulate-tool-call
                         state callbacks call)))))))))))))

(defun harness-provider-openai--accumulate-tool-call (state callbacks delta)
  "Merge one streamed tool call DELTA into STATE and notify CALLBACKS."
  (let* ((index (or (harness-alist-get :index delta) 0))
         (calls (plist-get state :tool-calls))
         (existing (gethash index calls))
         (call (or existing (harness-tool-call-create :name "" :args-string "")))
         (function (harness-alist-get :function delta)))
    (when-let* ((id (harness-alist-get :id delta)))
      (when (and (stringp id) (not (string-empty-p id)))
        (setf (harness-tool-call-id call) id)))
    (when (listp function)
      (when-let* ((name (harness-alist-get :name function)))
        (when (and (stringp name) (not (string-empty-p name)))
          (setf (harness-tool-call-name call) name)))
      (when-let* ((arguments (harness-alist-get :arguments function)))
        (when (stringp arguments)
          (setf (harness-tool-call-args-string call)
                (concat (harness-tool-call-args-string call) arguments)))))
    (puthash index call calls)
    (when-let* ((fn (plist-get callbacks :on-tool-call)))
      (funcall fn index call))))

(defun harness-provider-openai--fail (callbacks error)
  "Report HTTP ERROR through CALLBACKS."
  (when-let* ((fn (plist-get callbacks :on-error)))
    (funcall fn 'harness-http
             (if (harness-http-error-p error)
                 (harness-http-error-format error)
               (format "%s" error)))))

(cl-defmethod harness-provider-chat ((provider harness-provider-openai)
                                     request callbacks)
  "Start a streaming chat completion on PROVIDER for REQUEST."
  (let* ((state (list :tool-calls (make-hash-table :test #'eql)
                      :finish nil
                      :usage nil))
         (handle
          (harness-http-request
           (harness-provider-openai--url provider "/chat/completions")
           :method "POST"
           :headers (harness-provider-openai--headers provider t)
           :body (harness-provider-openai--request-body request)
           :on-event (lambda (event)
                       (harness-provider-openai--handle-event state callbacks event))
           :on-complete
           (lambda (_status _headers _body)
             ;; Some gateways close the stream without sending [DONE]; the
             ;; exactly-once guard in `harness-provider--once' makes the extra
             ;; call harmless.
             (when-let* ((fn (plist-get callbacks :on-done)))
               (funcall fn (or (plist-get state :finish) "stop")
                        (plist-get state :usage))))
           :on-error (lambda (error) (harness-provider-openai--fail callbacks error)))))
    handle))


;;; Model discovery

(cl-defmethod harness-provider-models ((provider harness-provider-openai) callback)
  "Fetch the model list from PROVIDER's `/models' endpoint."
  (harness-http-request
   (harness-provider-openai--url provider "/models")
   :method "GET"
   :headers (harness-provider-openai--headers provider nil)
   :on-complete
   (lambda (_status _headers body)
     (funcall callback
              (condition-case err
                  (let* ((data (harness-json-read body))
                         (models (harness-alist-get :data data)))
                    (delq nil
                          (mapcar
                           (lambda (entry)
                             (when-let* ((id (harness-alist-get :id entry)))
                               (list :provider (harness-provider-name provider)
                                     :id id
                                     :label id
                                     :source 'discovered)))
                           (if (listp models) models nil))))
                (error
                 (harness--log "could not parse the model list: %s"
                               (error-message-string err))
                 nil))))
   :on-error (lambda (error)
               (harness--log "model discovery failed: %s"
                             (harness-http-error-format error))
               (funcall callback nil))))

(provide 'harness-provider-openai)
;;; harness-provider-openai.el ends here
