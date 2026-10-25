;;; harness-mcp-protocol.el --- The Model Context Protocol, as the harness speaks it  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The harness runs the tools that touch files or start code in
;; processes it does not trust (lisp/modules/harness-mcp.el starts them
;; in the sandbox), and talks to them in the Model Context Protocol
;; (MCP): JSON-RPC 2.0 messages, one JSON object per line on the
;; process's standard input and output, a handshake (`initialize'),
;; then `tools/list' and `tools/call'.  This library is the part both
;; ends share, with no process and no state of its own:
;;
;; - the messages: `harness-mcp-request', `harness-mcp-notification',
;;   `harness-mcp-response' and `harness-mcp-error-response', and
;;   `harness-mcp-message-kind' to tell what a decoded one is;
;; - the framing of the stdio transport, `harness-mcp-encode-line' and
;;   `harness-mcp-decode-line';
;; - the results of a tool call: `harness-mcp-call-result' builds a
;;   CallToolResult, `harness-mcp-result-text' and the other accessors
;;   read one, and `harness-mcp-tool-result-to-call-result' and
;;   `harness-mcp-call-result-to-tool-result' carry a harness tool
;;   RESULT (see harness-tools.el) across, with what MCP has no field
;;   for -- attachments, images, the call's `:meta' -- in the result's
;;   own `_meta', under `harness/result';
;; - a server: `harness-mcp-make-server' with tools made by
;;   `harness-mcp-make-tool', and `harness-mcp-serve', which answers one
;;   decoded message and knows nothing of the transport it came on.
;;
;; The data are the harness's JSON plists (lisp/harness-util.el):
;; objects are plists with keyword keys, arrays are lists, `false' is
;; `:false'.  A server of the harness is a program that reads those
;; lines (lisp/harness-mcp-fs.el is one: the file tools in a jailed
;; Emacs), and so is the Emacs a client lends to the harness over ACP
;; (lisp/harness-emacs-mcp.el); both answer with `harness-mcp-serve'.
;;
;; A tool's handler is called as (HANDLER ARGUMENTS CONTEXT).  ARGUMENTS
;; is the plist the caller gave; CONTEXT is a plist: `:meta' (the
;; request's `_meta', where the harness puts the call's context under
;; `harness/context'), `:request-id', `:progress' (a function of a
;; number and optionally a total and a message that sends a progress
;; notification when the caller asked for one) and `:notify' (a function
;; of a message, for notifications of any kind).  It returns a
;; CallToolResult, a string, or a promise of either; a handler that
;; signals is answered with a result that has `isError' set, as the
;; protocol asks of a tool that fails, and only a call to a tool the
;; server does not have is an error of the protocol.
;;
;; What the harness asks of a server is the least that works with any
;; MCP client.  A server that wants to say what happened to the
;; harness -- a tool that wrote a file -- sends a `notifications/message'
;; whose `logger' is \"harness\" and whose data is {\"event\": NAME,
;; \"args\": [...]}; the host passes on only the events the server was
;; declared to be allowed to announce (see `harness-mcp-define-server').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defconst harness-mcp-protocol-version "2025-06-18"
  "The version of the Model Context Protocol the harness speaks.")

(defconst harness-mcp-supported-versions '("2025-06-18" "2025-03-26" "2024-11-05")
  "The versions of the protocol a harness server will answer in.
A client that asks for another gets `harness-mcp-protocol-version'.")

(defconst harness-mcp-error-parse -32700 "JSON-RPC: the text was no JSON.")
(defconst harness-mcp-error-invalid-request -32600 "JSON-RPC: not a request.")
(defconst harness-mcp-error-method-not-found -32601 "JSON-RPC: no such method.")
(defconst harness-mcp-error-invalid-params -32602 "JSON-RPC: the parameters do not fit.")
(defconst harness-mcp-error-internal -32603 "JSON-RPC: the server failed.")

(defconst harness-mcp-result-key :harness/result
  "Where in a result's `_meta' the harness carries what MCP has no field for.
The extras of a tool RESULT -- `:attachments', `:images', `:meta' and the
like -- go there, as an object (see
`harness-mcp-tool-result-to-call-result').")

(defconst harness-mcp-context-key :harness/context
  "Where in the `_meta' of a tool call the harness puts the call's context.
The session, the working directory, the host and the like, as an object:
what a tool's `ctx' holds (see `harness-mcp-call').")

;;;; Messages

(defun harness-mcp-request (id method &optional params)
  "Return the JSON-RPC request METHOD with PARAMS and ID, a number or a string."
  (append (list :jsonrpc "2.0" :id id :method method)
          (and params (list :params params))))

(defun harness-mcp-notification (method &optional params)
  "Return the JSON-RPC notification METHOD with PARAMS."
  (append (list :jsonrpc "2.0" :method method)
          (and params (list :params params))))

(defun harness-mcp-response (id result)
  "Return the JSON-RPC response to request ID with RESULT, an object.
A nil RESULT is the empty object, which is what MCP answers a request
with nothing to say, such as `ping'."
  (list :jsonrpc "2.0" :id id :result (or result :empty)))

(defun harness-mcp-error-response (id code message &optional data)
  "Return the JSON-RPC error response to ID, with CODE, MESSAGE and DATA.
ID is nil when the request could not be read."
  (list :jsonrpc "2.0" :id id
        :error (append (list :code code :message message)
                       (and data (list :data data)))))

(defun harness-mcp-message-kind (message)
  "Return what the decoded JSON-RPC MESSAGE is, or nil if it is none.
`request' (a method and an id), `notification' (a method), `result'
\(the answer to a request) or `error' (the failure of one)."
  (and (consp message) (keywordp (car message))
       (cond ((and (plist-member message :method) (plist-member message :id)
                   (plist-get message :id))
              'request)
             ((plist-member message :method) 'notification)
             ((plist-member message :error) 'error)
             ((plist-member message :result) 'result))))

(defun harness-mcp-encode-line (message)
  "Return MESSAGE as one line of the stdio transport, newline included.
It is UTF-8 bytes, ready for a process: JSON escapes every newline in
a string, so a message is one line however its text is made."
  (concat (harness-json-encode message) "\n"))

(defun harness-mcp-decode-line (line)
  "Return the message LINE holds, or signal an error saying why not."
  (let ((message (condition-case nil
                     (harness-json-parse line)
                   (error (error "Not JSON: %s" (harness-truncate-end (or line "") 80))))))
    (unless (harness-mcp-message-kind message)
      (error "Not a JSON-RPC message: %s" (harness-truncate-end (or line "") 80)))
    message))

;;;; Tool results

(defun harness-mcp-text-content (text)
  "Return the text block of TEXT, a content block of a tool result."
  (list :type "text" :text (or text "")))

(cl-defun harness-mcp-call-result (text &key is-error structured meta)
  "Return the CallToolResult that says TEXT.
IS-ERROR marks a failure the model should read, STRUCTURED is the
data a client may read instead of the text and META the result's
`_meta'."
  (append (list :content (list (harness-mcp-text-content text))
                :isError (if is-error t :false))
          (and structured (list :structuredContent structured))
          (and meta (list :_meta meta))))

(defun harness-mcp-result-text (result)
  "Return the text of the CallToolResult RESULT: its text blocks, joined.
Other kinds of block are left out."
  (mapconcat (lambda (block) (or (plist-get block :text) ""))
             (cl-remove-if-not (lambda (block) (equal (plist-get block :type) "text"))
                               (plist-get result :content))
             "\n"))

(defun harness-mcp-result-error-p (result)
  "Non-nil when the CallToolResult RESULT says the tool failed."
  (harness-json-true-p (plist-get result :isError)))

(defun harness-mcp-result-structured (result)
  "Return the data of the CallToolResult RESULT, or nil when it has none."
  (plist-get result :structuredContent))

(defun harness-mcp-tool-result-to-call-result (result)
  "Return the CallToolResult for RESULT, a harness tool result.
The text goes where MCP puts it; everything else the result holds
\(attachments, images, the call's `:meta' ...) is kept in the result's
`_meta' under `harness/result', and comes back with
`harness-mcp-call-result-to-tool-result'."
  (let ((extras (harness-plist-remove result :content :is-error)))
    (harness-mcp-call-result (plist-get result :content)
                             :is-error (plist-get result :is-error)
                             :meta (and extras (list harness-mcp-result-key extras)))))

(defun harness-mcp-call-result-to-tool-result (result)
  "Return the harness tool result for RESULT, a CallToolResult.
The inverse of `harness-mcp-tool-result-to-call-result'.  A result
that does not come from a harness server has its text, and the data
it sent as `:structured'; a block that is no text is said in the text
as omitted, since a tool's output is text for the model."
  (let* ((blocks (plist-get result :content))
         (others (cl-remove-if (lambda (b) (equal (plist-get b :type) "text")) blocks))
         (text (harness-mcp-result-text result))
         (extras (plist-get (plist-get result :_meta) harness-mcp-result-key))
         (structured (plist-get result :structuredContent)))
    (append (list :content (if others
                               (concat text (if (string-empty-p text) "" "\n")
                                       (format "[%d non-text block%s omitted]"
                                               (length others) (if (cdr others) "s" "")))
                             text)
                  :is-error (harness-mcp-result-error-p result))
            (and (consp extras) (keywordp (car extras)) extras)
            (and structured (not (plist-member extras :structured)) (list :structured structured)))))

;;;; A server

(cl-defstruct (harness-mcp-tool (:constructor harness-mcp-make-tool) (:copier nil))
  "A tool a server offers.
NAME is what a client calls it; TITLE the name people read, DESCRIPTION
what the model reads and SCHEMA the JSON schema of its arguments, a
plist.  HANDLER is called as (HANDLER ARGUMENTS CONTEXT); see the
Commentary.  ANNOTATIONS are MCP's hints about the tool (`readOnlyHint'
..), a plist."
  name title description schema handler annotations)

(cl-defstruct (harness-mcp-server (:constructor harness-mcp-make-server) (:copier nil))
  "What a server of the harness answers `initialize' and `tools/list' with.
NAME, TITLE and VERSION say what it is, INSTRUCTIONS how to use it, and
TOOLS is a list of `harness-mcp-tool'.  INITIALIZED is set when the
client said so, CANCELLED holds the ids of requests the client gave up."
  name title (version "1") instructions tools initialized
  (cancelled (make-hash-table :test 'equal)))

(defun harness-mcp-server-tool (server name)
  "Return the tool NAME of SERVER, or nil."
  (cl-find name (harness-mcp-server-tools server) :key #'harness-mcp-tool-name :test #'equal))

(defun harness-mcp-cancelled-p (server request-id)
  "Non-nil when the client of SERVER gave up on the request REQUEST-ID."
  (and (gethash request-id (harness-mcp-server-cancelled server)) t))

(defun harness-mcp--tool-descriptor (tool)
  "Return TOOL as `tools/list' lists it."
  (append (list :name (harness-mcp-tool-name tool))
          (and (harness-mcp-tool-title tool) (list :title (harness-mcp-tool-title tool)))
          (list :description (or (harness-mcp-tool-description tool) "")
                :inputSchema (or (harness-mcp-tool-schema tool)
                                 '(:type "object" :properties :empty)))
          (and (harness-mcp-tool-annotations tool)
               (list :annotations (harness-mcp-tool-annotations tool)))))

(defun harness-mcp--initialize-result (server params)
  "Return the result of `initialize' for SERVER, answering PARAMS."
  (let* ((asked (plist-get params :protocolVersion))
         (version (if (member asked harness-mcp-supported-versions)
                      asked
                    harness-mcp-protocol-version)))
    (append (list :protocolVersion version
                  :capabilities (list :tools (list :listChanged :false))
                  :serverInfo (append (list :name (or (harness-mcp-server-name server) "harness")
                                            :version (harness-mcp-server-version server))
                                      (and (harness-mcp-server-title server)
                                           (list :title (harness-mcp-server-title server)))))
            (and (harness-mcp-server-instructions server)
                 (list :instructions (harness-mcp-server-instructions server))))))

(defun harness-mcp--failure-result (err)
  "Return the CallToolResult that tells a tool failed with ERR."
  (harness-mcp-call-result (format "Tool failed: %s" (harness-error-message err)) :is-error t))

(defun harness-mcp--handler-result (value)
  "Return the CallToolResult for VALUE, what a handler returned."
  (cond ((stringp value) (harness-mcp-call-result value))
        ((null value) (harness-mcp-call-result ""))
        ((and (consp value) (plist-member value :content)
              (let ((content (plist-get value :content)))
                ;; A harness tool RESULT has its text in `:content'; a
                ;; CallToolResult has a list of blocks.
                (or (listp content) (vectorp content))))
         value)
        ((and (consp value) (plist-member value :content)) (harness-mcp-tool-result-to-call-result value))
        (t (harness-mcp-call-result (format "%S" value)))))

(defun harness-mcp--call (server params id transport)
  "Run the tool call PARAMS, request ID, on SERVER; return its response.
TRANSPORT is the plist the caller of `harness-mcp-serve' gave.  The
response is a message, or a promise of one when the handler's result is
a promise."
  (let* ((name (plist-get params :name))
         (tool (and (stringp name) (harness-mcp-server-tool server name))))
    (if (null tool)
        (harness-mcp-error-response id harness-mcp-error-invalid-params
                                    (format "Unknown tool: %s" name))
      (let* ((meta (plist-get params :_meta))
             (token (plist-get meta :progressToken))
             (notify (plist-get transport :notify))
             (context (list :meta meta :request-id id :notify notify
                            :progress (lambda (progress &optional total message)
                                        (when (and token notify)
                                          (funcall notify
                                                   (harness-mcp-notification
                                                    "notifications/progress"
                                                    (append (list :progressToken token :progress progress)
                                                            (and total (list :total total))
                                                            (and message (list :message message)))))))))
             (arguments (or (plist-get params :arguments) nil))
             (value (condition-case err
                        (funcall (harness-mcp-tool-handler tool) arguments context)
                      (error (harness-mcp--failure-result err))))
             (finish (lambda (v) (harness-mcp-response id (harness-mcp--handler-result v)))))
        (if (harness-promise-p value)
            (harness-then value finish
                          (lambda (err) (funcall finish (harness-mcp--failure-result err))))
          (funcall finish value))))))

(defun harness-mcp-serve (server message &optional transport)
  "Answer MESSAGE, a decoded JSON-RPC message, as SERVER, a `harness-mcp-server'.
Return the response message; a promise of it when a tool's handler
returns a promise; nil for a notification, which has none.  TRANSPORT
is a plist: `:notify', a function that sends a message to the client
\(progress, logging), if the transport can.  The server answers
`initialize', `ping', `tools/list' and `tools/call'; any other request
is an error of the protocol, and any other notification is dropped."
  (pcase (harness-mcp-message-kind message)
    ('request
     (let ((id (plist-get message :id))
           (method (plist-get message :method))
           (params (plist-get message :params)))
       (pcase method
         ("initialize" (harness-mcp-response id (harness-mcp--initialize-result server params)))
         ("ping" (harness-mcp-response id nil))
         ("tools/list"
          (harness-mcp-response
           id (list :tools (mapcar #'harness-mcp--tool-descriptor (harness-mcp-server-tools server)))))
         ("tools/call" (harness-mcp--call server params id transport))
         (_ (harness-mcp-error-response id harness-mcp-error-method-not-found
                                        (format "Method not found: %s" method))))))
    ('notification
     (pcase (plist-get message :method)
       ("notifications/initialized" (setf (harness-mcp-server-initialized server) t) nil)
       ("notifications/cancelled"
        (when-let* ((id (plist-get (plist-get message :params) :requestId)))
          (puthash id t (harness-mcp-server-cancelled server)))
        nil)
       (_ nil)))
    (_ nil)))

;;;; The stdio loop of a server

;; A server that is a program -- an `emacs --batch' the host starts in
;; the sandbox -- reads its requests from standard input and writes its
;; answers to standard output, one message to a line, and does what is
;; asked one request at a time.  Whatever a tool prints is not for the
;; client: its standard output goes to a buffer of its own while it
;; runs, and `message' goes to standard error, which the host keeps for
;; the day the server fails.

(defun harness-mcp-stdio-write (message)
  "Write MESSAGE, a JSON-RPC message, to standard output as one line."
  (let ((standard-output t))
    (princ (concat (harness-json-encode-text message) "\n")))
  (flush-standard-output))

(defun harness-mcp-stdio-read-line ()
  "Return the next line of standard input, or nil when it has ended."
  (condition-case nil
      (read-from-minibuffer "")
    (error nil)))

(defun harness-mcp--await (promise)
  "Return the value of PROMISE, spinning the event loop until it settles.
A rejection is an error."
  (while (not (harness-promise-settled-p promise))
    (accept-process-output nil 0.02)
    (unless (harness-promise-settled-p promise) (sit-for 0.005)))
  (if (eq (harness-promise-state promise) 'resolved)
      (harness-promise-value promise)
    (signal 'harness-error (list (harness-error-message (harness-promise-value promise))))))

(defun harness-mcp--answer-line (server line)
  "Return the response to LINE, a message SERVER reads, or nil for none."
  (condition-case err
      (let* ((message (harness-mcp-decode-line line))
             (id (plist-get message :id))
             (response (let ((standard-output (generate-new-buffer " *mcp-tool-output*" t)))
                         (unwind-protect
                             (let ((value (harness-mcp-serve server message
                                                             (list :notify #'harness-mcp-stdio-write))))
                               (if (harness-promise-p value) (harness-mcp--await value) value))
                           (kill-buffer standard-output)))))
        (ignore id)
        response)
    (error (harness-mcp-error-response nil harness-mcp-error-parse (harness-error-message err)))))

(defun harness-mcp-stdio-loop (server)
  "Serve SERVER on standard input and output until the input ends.
Each line is answered before the next is read.  Returns when the input
is closed, which is the host's way to say the server should go."
  (setq locale-coding-system 'utf-8-unix)
  (set-language-environment "UTF-8")
  (let (line)
    (while (setq line (harness-mcp-stdio-read-line))
      (unless (string-blank-p line)
        (when-let* ((response (harness-mcp--answer-line server line)))
          (harness-mcp-stdio-write response))))))

(provide 'harness-mcp-protocol)
;;; harness-mcp-protocol.el ends here
