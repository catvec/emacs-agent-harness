;;; harness-tools.el --- Tool registry and execution pipeline  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tools are declared with `harness-define-tool' and executed with the
;; `tools/execute' method, which runs the permission chain, the handler
;; (with a timeout), the context-bomb guard and the result filter.  A
;; tool never runs without a permission decision; when no permission
;; module is installed every call is denied, so a misconfigured harness
;; fails safe.
;;
;; A tool has two names: NAME, the identifier the model calls it by
;; (read_file), and its `:label', the name people read (Read file),
;; which every UI shows in its place.  A call's title is the label,
;; then what the call is about, from the tool's `:subject' function:
;; "Read file: src/x.el".
;;
;; Some providers have tools of their own that can stand in for a
;; harness tool: Claude Code's web search for web_search, say.  A
;; provider names the harness tools it has such a counterpart of in its
;; `:builtin-tools' capability, and `tools/builtin' says which of them a
;; session's provider runs itself; `tools/list' then leaves them out.
;; The calls the provider runs still need a permission decision, which
;; `tools/authorize' gives without running anything.
;;
;; Corporate mode (`harness-corporate-mode') turns off the tools of kind
;; net other than web search (`harness-tools--corporate-net-tools'),
;; and ssh, which runs commands on other machines
;; (`harness-tools--corporate-remote-tools').  No session gets them,
;; and a call to one is refused before the permission chain, whatever
;; the permission mode and the standing rules say
;; (`harness-tools--corporate-refusal').  web_search stays, and so does
;; a provider's own search in its place: that is a call of web_search
;; too, which the permission chain decides as usual.
;;
;; Every tool reaches another host through TRAMP, given a path there or
;; in a session on that host.  A call that fails because TRAMP could not
;; connect says why and how to set the host up, whichever tool made it
;; (`harness-tools-remote-failure').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)

(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-get-method-parameter "tramp" (vec param &optional default))
(declare-function tramp-file-name-user "tramp" (vec))
(declare-function tramp-file-name-host "tramp" (vec))
(declare-function tramp-file-name-port "tramp" (vec))

(defcustom harness-tools-max-output-chars 30000
  "Tool outputs longer than this are saved to a file and truncated."
  :type 'integer :group 'harness)

(defconst harness-tools--timeout 600
  "Default seconds a tool may run before it is cancelled.")

(defvar harness-tools--emacs-timeout 15
  "Seconds a tool about the user's Emacs may wait for it to answer.
Internal, not an option (see docs/configuration-audit.md).  The
`emacs_*' tools ask the Emacs a client lent to the harness over
`emacs/request' (`harness-tools-ask-emacs'); one busy or blocked longer
than this fails the tool call, with a desktop notice, instead of
leaving the session waiting forever.")

(defconst harness-tools--ui-notice-interval 300
  "Seconds between desktop notices that the Emacs UI is not answering.")

(defvar harness-tools--ui-notice-at 0
  "When the UI was last reported unresponsive.")

(declare-function harness-notifications-desktop-notify "harness-notifications-desktop" (&rest params))

(defun harness-tools--ui-unresponsive (what seconds)
  "Report that WHAT, the Emacs a tool asked, did not answer within SECONDS.
Logs the miss, and shows a desktop notification at most every
`harness-tools--ui-notice-interval' seconds: an Emacs blocked in a
subprocess call can stay that way for hours, and nothing else would
say so."
  (harness-log 'warn "tools: %s did not answer within %ss; it may be blocked" what seconds)
  (when (> (- (float-time) harness-tools--ui-notice-at) harness-tools--ui-notice-interval)
    (setq harness-tools--ui-notice-at (float-time))
    (when (or (fboundp 'harness-notifications-desktop-notify)
              (require 'harness-notifications-desktop nil t))
      (ignore-errors
        (harness-notifications-desktop-notify
         :title "Harness: the Emacs UI is not responding"
         :body (format "A tool waited %ss for %s to answer; it may be blocked. See %s."
                       seconds what harness-log-buffer-name)
         :urgency 'critical)))))

(defun harness-tools--with-deadline (promise seconds what)
  "Return a promise settled as PROMISE, or rejected after SECONDS.
WHAT names the work for the timeout, which is also reported as an
unresponsive UI (`harness-tools--ui-unresponsive')."
  (let ((result (harness-make-promise))
        (timer nil) (settled nil))
    (setq timer (run-at-time seconds nil
                             (lambda ()
                               (unless settled
                                 (setq settled t)
                                 (harness-tools--ui-unresponsive what seconds)
                                 (harness-reject result
                                                 (list 'timeout
                                                       (format "%s did not answer within %ss"
                                                               what seconds)))))))
    (harness-then promise
                  (lambda (value)
                    (unless settled (setq settled t) (cancel-timer timer)
                            (harness-resolve result value))
                    nil)
                  (lambda (err)
                    (unless settled (setq settled t) (cancel-timer timer)
                            (harness-reject result err))
                    nil))
    result))

(cl-defstruct (harness-tool (:copier nil))
  ;; New slots go last, so a tool registered before a reload still reads
  ;; right should its module fail to load again (see `harness-tools--label').
  name description schema handler kind paths-fn coalescable subject-fn module timeout label)

(defvar harness-tools (make-hash-table :test 'equal)
  "Tool name -> `harness-tool'.")

(defun harness-tools--clean-schema (schema)
  "Return SCHEMA without its empty `:required' lists, at any depth.
An empty list encodes as JSON null, not [], and a provider refuses a
schema with \"required\": null: OpenAI fails the whole request, and
Claude Code drops every tool of the harness from the turn."
  (if (and (consp schema) (keywordp (car schema)))
      (let (clean)
        (while schema
          (let ((key (pop schema)) (value (pop schema)))
            (unless (and (eq key :required) (null value))
              (setq clean (nconc clean (list key (harness-tools--clean-schema value)))))))
        clean)
    schema))

(cl-defun harness-define-tool (name &key label description schema handler (kind 'meta)
                                    paths coalescable subject timeout)
  "Register tool NAME.  See docs/architecture.md for the keyword arguments.
LABEL is required: the name people read, such as \"Read file\" for
read_file, which the UI shows wherever it names the tool.  DESCRIPTION
is what the model reads about the tool, and SCHEMA the JSON schema of
its input, as a plist (by default an object without properties).
HANDLER, required too, is called with the input and context of a call
and returns a RESULT plist, a string, or a promise of one.  KIND is the
permission class of the tool: read, write, exec, net or meta, the
default.  PATHS is a function of a call's input returning the paths
the call touches, for the jail, and COALESCABLE non-nil lets the UI
fold the tool's calls into a summary block.  SUBJECT is a function of
a call's input returning what the call is about (the path it reads,
the command it runs) or nil; it follows the label in the call's title,
see `harness-tool-title'.  TIMEOUT is how many seconds a call may run,
by default `harness-tools--timeout'."
  (unless (functionp handler) (error "Tool %s needs a handler" name))
  (unless (and (stringp label) (not (harness-string-blank-p label)))
    (error "Tool %s needs a :label, the name people read (such as \"Read file\")" name))
  (puthash name (make-harness-tool :name name :label (string-trim label)
                                   :description (or description "")
                                   :schema (or (harness-tools--clean-schema schema)
                                               '(:type "object" :properties :empty))
                                   :handler handler :kind kind :paths-fn paths
                                   :coalescable coalescable :subject-fn subject
                                   :timeout timeout
                                   :module (and (boundp 'harness--defining-module)
                                                harness--defining-module))
           harness-tools)
  name)

(defun harness-tool-get (name)
  "Return the tool struct for NAME or nil."
  (gethash name harness-tools))

(defun harness-tools--label (tool)
  "Return the label of TOOL, a `harness-tool', or its name when it has none.
A tool registered by code from before tools had labels has none: its
record is a slot short."
  (or (ignore-errors (harness-tool-label tool))
      (harness-tool-name tool)))

(defun harness-tools-label (name)
  "Return the name people read for tool NAME: its label, else NAME itself.
A tool nobody registered, one a model made up say, has no label."
  (let ((tool (and name (harness-tool-get name))))
    (if tool (harness-tools--label tool) (format "%s" (or name "tool")))))

(defun harness-tool-spec (tool)
  "Return the public spec plist of TOOL."
  (list :name (harness-tool-name tool)
        :label (harness-tools--label tool)
        :description (harness-tool-description tool)
        :schema (harness-tool-schema tool)
        :kind (harness-tool-kind tool)
        :coalescable (and (harness-tool-coalescable tool) t)))

(defun harness-tools--subject (tool input)
  "Return what a call of TOOL (a struct or nil) with INPUT is about, or nil.
That is what TOOL's subject function says, nil included; without one,
or when it fails, the first string in INPUT."
  (let* ((fn (and tool (harness-tool-subject-fn tool)))
         (said (and fn
                    (condition-case err
                        (list (funcall fn input))
                      (error (harness-log 'debug "tool %s: subject failed: %S" (harness-tool-name tool) err)
                             nil))))
         (subject (if said
                      (car said)
                    (cl-loop for (_k v) on input by #'cddr
                             when (and (stringp v) (not (harness-string-blank-p v)))
                             return (harness-truncate-end (harness-first-line v) 60)))))
    (and (stringp subject) (not (harness-string-blank-p subject))
         (harness-first-line subject))))

(defun harness-tool-title (name input)
  "Return the title of a call to tool NAME with INPUT, for people to read.
It is the tool's label, then a colon and what the call is about, as
\"Read file: x.el\" for read_file on x.el; or the label alone when the
call is about nothing in particular."
  (let* ((tool (harness-tool-get name))
         (subject (harness-tools--subject tool input)))
    (if subject
        (format "%s: %s" (harness-tools-label name) subject)
      (harness-tools-label name))))

;;;; Results

(defun harness-tool-ok (content &rest props)
  "Return a successful RESULT with CONTENT and extra PROPS."
  (append (list :content (if (stringp content) content (format "%S" content)) :is-error nil) props))

(defun harness-tool-error (message &rest props)
  "Return an error RESULT with MESSAGE and extra PROPS."
  (append (list :content message :is-error t) props))

;;;; The user's Emacs

;; Every tool runs here, in the harness; no client runs one.  A tool
;; about the user's Emacs reaches that Emacs as a resource, the way the
;; file tools reach a TRAMP host: a client lends its Emacs to the
;; harness (see lisp/harness-emacs-endpoint.el), and the tool asks it
;; for plain data or a few bounded actions.  Only emacs_eval
;; (tools-emacs-eval) asks it to evaluate code, when a judge model
;; expects the code to return at once and the user did not turn that
;; off there (`harness-emacs-eval').  A client that lends no Emacs,
;; such as a phone, is never asked, and a harness with none attached
;; (headless) runs every other tool as usual.

(defun harness-tools-reason (err)
  "Return the message of ERR, a rejection or an error, for the model to read.
An error whose data is just a message, as `emacs/request' and the
deadline of `harness-tools--with-deadline' reject with, gives that
message, rather than Emacs's printed form of the whole error."
  (if (and (consp err) (symbolp (car err)) (stringp (cadr err)) (null (cddr err)))
      (cadr err)
    (harness-error-message err)))

(defun harness-tools-sentence (text)
  "Return TEXT as a sentence: capitalised, with one full stop at its end."
  (let ((text (string-trim-right (string-trim (or text "")) "[ .]+")))
    (if (string-empty-p text)
        "It failed."
      (concat (upcase (substring text 0 1)) (substring text 1) "."))))

(defun harness-tools-ask-emacs (method params &optional seconds)
  "Ask the Emacs lent to the harness for METHOD with PARAMS; return a promise.
METHOD names a request of lisp/harness-emacs-endpoint.el, such as
\"buffers\"; `emacs/request' sends it to the one Emacs a client lent.
The promise resolves to the answer.  It rejects when no Emacs is
attached, when it refuses or fails (with its message; see
`harness-tools-reason'), and when it does not answer within SECONDS
\(default `harness-tools--emacs-timeout'), which is also reported as an
unresponsive UI."
  (if (not (harness-method-exists-p 'emacs/request))
      (harness-rejected (list 'harness-error "no Emacs is attached to the harness: it serves no clients"))
    (harness-tools--with-deadline
     (harness-call-async 'emacs/request method params)
     (or seconds harness-tools--emacs-timeout)
     "the user's Emacs")))

(defun harness-tools--normalise-result (value)
  "Return VALUE, what a tool handler gave, as a RESULT.
A RESULT plist has its `:is-error' made t or nil; a string becomes the
content of a successful result, nil an empty one, and anything else its
printed form."
  (cond ((and (listp value) (plist-member value :content))
         (plist-put (copy-sequence value) :is-error (and (plist-get value :is-error) t)))
        ((stringp value) (harness-tool-ok value))
        ((null value) (harness-tool-ok ""))
        (t (harness-tool-ok (format "%S" value)))))

(defun harness-tools--guard-size (result call-id)
  "Truncate an oversized RESULT, saving the full text for range reads.
The text is saved as CALL-ID.txt, or under a fresh id without one, in
the outputs directory of `harness-state-directory'."
  (let ((content (plist-get result :content)))
    (if (<= (length content) harness-tools-max-output-chars)
        result
      (let* ((dir (expand-file-name "outputs" harness-state-directory))
             (path (expand-file-name (format "%s.txt" (or call-id (harness-short-id))) dir))
             (head (substring content 0 (/ harness-tools-max-output-chars 3))))
        (harness-write-file-atomically path content)
        (plist-put
         (plist-put (copy-sequence result) :content
                    (format "%s\n\n[Output truncated: %d characters, %d lines. The full output was saved to %s. Read it in ranges with read_file (offset/limit), or narrow the request.]"
                            head (length content)
                            (1+ (cl-count ?\n content)) path))
         :truncated (list :path path :chars (length content)))))))

;;;; Context

(defun harness-tools--session (session-id)
  "Return the plist of session SESSION-ID, as `session/get' gives it.
Without the session, or the session module, return a stand-in that has
SESSION-ID and `default-directory' as its `:cwd'."
  (or (and session-id (harness-method-exists-p 'session/get)
           (ignore-errors (harness-call 'session/get session-id)))
      (list :id session-id :cwd (file-name-as-directory (expand-file-name default-directory)))))

(defun harness-tools-resolve-path (path ctx)
  "Return PATH absolute, relative to CTX's cwd and host."
  (let* ((cwd (or (plist-get ctx :cwd) default-directory))
         (host (plist-get ctx :host))
         (p (expand-file-name path cwd)))
    (if (and host (not (file-remote-p p)))
        (concat host p)
      p)))

(defun harness-tools--paths (tool input ctx)
  "Return the paths a call of TOOL with INPUT touches, absolute under CTX.
They are what its paths function says, resolved by
`harness-tools-resolve-path'; nil without that function, or when it
fails, which is logged."
  (when (harness-tool-paths-fn tool)
    (condition-case err
        (mapcar (lambda (p) (harness-tools-resolve-path p ctx))
                (delq nil (funcall (harness-tool-paths-fn tool) input)))
      (error (harness-log 'warn "tool %s: paths function failed: %S" (harness-tool-name tool) err) nil))))

;;;; Remote hosts

;; When TRAMP cannot connect to a host it says little more than that
;; ("Tramp failed to connect.  If this happens repeatedly, try `M-x
;; tramp-cleanup-this-connection'"), nothing a model can act on, and
;; the harness has no terminal at which ssh could ask for a password.
;; So a call that failed on a host TRAMP is not connected to is
;; explained instead: ssh, asked once more in batch mode, says why, and
;; the error says how to set the host up.

(defconst harness-tools--remote-check-timeout 20
  "Seconds the batch-mode ssh that explains a failed connection may take.")

(defconst harness-tools-remote-setup-hint
  "The harness connects without a terminal, so nothing can answer a password, key passphrase or host key prompt: the host must accept a key from ssh-agent (or one without a passphrase) and be in ~/.ssh/known_hosts. `ssh -o BatchMode=yes HOST true' in a terminal shows whether it is set up. That is for the user to set up; do not try to work around it."
  "What the error about a failed ssh connection says about setting a host up.")

(defun harness-tools--remote-busy-p (err)
  "Non-nil when ERR is TRAMP refusing a call on a connection in use.
TRAMP serves one call at a time on a connection, and the harness may
make another one while it waits on the host for the first."
  (and (string-search "Forbidden reentrant call of Tramp" (harness-error-message err)) t))

(defun harness-tools--remote-reason (err)
  "Return what went wrong for ERR, an error TRAMP signalled while connecting.
Nil when TRAMP says no more than that it could not connect."
  (let ((message (harness-error-message err)))
    (cond
     ;; TRAMP read the answer to a prompt from the harness's closed stdin.
     ((eq (car-safe err) 'end-of-file)
      "the login asked for a password, a passphrase or a host key confirmation, which the harness cannot answer")
     ((string-match-p "Tramp failed to connect" message) nil)
     ;; TRAMP's buffers are of no use to the model.
     (t (replace-regexp-in-string ",? see buffer .*\\'" ""
                                   (string-trim (car (split-string message "\n"))))))))

(defun harness-tools--ssh-jump (vec)
  "Return VEC, a dissected hop, as ssh's -J option writes a jump host."
  (let ((host (tramp-file-name-host vec))
        (user (tramp-file-name-user vec))
        (port (tramp-file-name-port vec)))
    (concat (if user (concat user "@") "")
            (if (string-search ":" host) (concat "[" host "]") host)
            (if port (concat ":" port) ""))))

(defun harness-tools--ssh-batch-command (prefix)
  "Return the ssh command that connects to PREFIX's host in batch mode, or nil.
PREFIX is a TRAMP prefix, such as /ssh:box: or /ssh:jump|ssh:box:.  Nil
when a hop does not log in with ssh (sudo, docker, TRAMP's mock method)."
  (require 'tramp)
  (let ((vecs (mapcar (lambda (hop) (tramp-dissect-file-name (concat "/" hop ":")))
                      (split-string (substring prefix 1 -1) "|" t))))
    (when (and vecs (cl-every (lambda (v) (equal (tramp-get-method-parameter v 'tramp-login-program) "ssh"))
                              vecs))
      (let* ((target (car (last vecs)))
             (jumps (butlast vecs))
             (user (tramp-file-name-user target))
             (port (tramp-file-name-port target)))
        (append (list "ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10")
                (and jumps (list "-J" (mapconcat #'harness-tools--ssh-jump jumps ",")))
                (and port (list "-p" port))
                (and user (list "-l" user))
                (list "--" (tramp-file-name-host target) "true"))))))

(defun harness-tools--remote-diagnose (command)
  "Return a promise of what COMMAND, ssh in batch mode, says, or nil.
TRAMP only says that the connection failed; ssh in batch mode, which
fails where it would ask, says why: no such host, a refused key, an
unknown host key.  The promise resolves to nil when COMMAND is nil,
when ssh does not run, or when nothing was learnt."
  (if (not command)
      (harness-resolved nil)
    (harness-then
     (condition-case err
         (harness-run-command command :cwd temporary-file-directory
                              :timeout harness-tools--remote-check-timeout :name "harness-ssh-check")
       (error (harness-rejected err)))
     (lambda (r)
       (let ((exit (plist-get r :exit))
             (said (string-trim (plist-get r :stderr))))
         (cond
          ((eql exit 0)
           "nothing: it connects, so TRAMP could not set up its shell on the host (a login script that prints or prompts?)")
          ((eq exit 'timeout) (format "nothing within %ss" harness-tools--remote-check-timeout))
          ((string-empty-p said) (format "exit %s" exit))
          (t (harness-truncate-end (string-join (last (split-string said "\n" t) 3) "\n") 600)))))
     (lambda (_err) nil))))

(defun harness-tools-remote-failure (prefix err)
  "Return the tool error for a call that could not reach PREFIX's host.
PREFIX is the host's TRAMP prefix, such as /ssh:box:, and ERR what
TRAMP signalled.  The error says why, as far as TRAMP and ssh in batch
mode can tell, and how to set up a host ssh logs in to; it comes as a
promise, since ssh is asked.  A connection that another call was using
did not fail: that error, at once, says to make the call again."
  (if (harness-tools--remote-busy-p err)
      (harness-tool-error (format "TRAMP was busy with another call on %s; make this call again." prefix)
                          :meta (list :host prefix :busy t))
    (harness-log 'info "tools: could not connect to %s: %s" prefix (harness-error-message err))
    (let ((ssh (condition-case nil (harness-tools--ssh-batch-command prefix) (error nil))))
      (harness-then
       (harness-tools--remote-diagnose ssh)
       (lambda (said)
         (let ((reason (harness-tools--remote-reason err)))
           (harness-tool-error
            (concat (format "Could not connect to %s" prefix)
                    (if reason (format " (%s)" reason) "")
                    "."
                    (if said (format "\nssh -o BatchMode=yes says: %s" said) "")
                    (if ssh (concat "\n" harness-tools-remote-setup-hint) ""))
            :meta (list :host prefix :connected nil))))))))

(defun harness-tools--unreached-host (tool input ctx err)
  "Return the TRAMP prefix of the host TOOL's call could not reach, or nil.
ERR is what the call with INPUT under CTX signalled.  The host is that
of the first of the call's paths on another host, else of the
session's directory.  ERR must be a file error, or the end of input
TRAMP met reading the answer to a prompt, while TRAMP has no
connection to the host: on a host it is connected to, a file error is
about a file there.  A connection that another call was using counts
either way."
  (when (and (symbolp (car-safe err))
             (or (eq (car err) 'end-of-file)
                 (memq 'file-error (get (car err) 'error-conditions))))
    (when-let* ((path (cl-find-if (lambda (p) (and (stringp p) (file-remote-p p)))
                                  (append (harness-tools--paths tool input ctx)
                                          (list (plist-get ctx :cwd))))))
      (and (or (harness-tools--remote-busy-p err)
               (not (file-remote-p path nil t)))
           (file-remote-p path)))))

(defun harness-tools--failure (tool input ctx err)
  "Return a promise of the result of TOOL's call with INPUT under CTX.
The call failed with ERR, and the result says so; or, when TRAMP
could not reach the host the call is about, why not
\(`harness-tools-remote-failure')."
  (let ((plain (harness-tool-error (format "Tool %s failed: %s" (harness-tool-name tool)
                                           (harness-error-message err))))
        (prefix (condition-case nil (harness-tools--unreached-host tool input ctx err) (error nil))))
    (if (not prefix)
        (harness-resolved plain)
      (harness-then (condition-case e
                        (harness-as-promise (harness-tools-remote-failure prefix err))
                      (error (harness-rejected e)))
                    nil
                    (lambda (_) plain)))))

;;;; Corporate mode

(defconst harness-tools--corporate-net-tools '("web_search")
  "Tools of kind net that corporate mode leaves on: web search.
A search sends its query to the search provider, or the model provider
runs it in the tool's place (see `tools/builtin'), and either is a call
of web_search.  Every other tool of kind net, such as web_fetch, which
reaches any URL, is off with `harness-corporate-mode' on.")

(defconst harness-tools--corporate-remote-tools '("ssh")
  "Tools of other kinds than net that corporate mode turns off too.
ssh is of kind exec, since it runs commands, but it runs them on
another machine, which carries data off this one as web_fetch does.")

(defconst harness-tools-corporate-hint
  "Work with the project and the tools you have; do not try to reach the network another way, such as with curl in the shell. If the task cannot be done without this tool, finish what you can and say so in your answer."
  "What the model is told when corporate mode refuses a network tool.")

(defun harness-tools--corporate-off-p (name kind)
  "Non-nil when corporate mode turns off tool NAME, of KIND.
With `harness-corporate-mode' on, that is every tool of kind net other
than those of `harness-tools--corporate-net-tools', and the tools of
`harness-tools--corporate-remote-tools'."
  (and (harness-corporate-p)
       (or (and (eq kind 'net) (not (member name harness-tools--corporate-net-tools)))
           (member name harness-tools--corporate-remote-tools))
       t))

(defun harness-tools--off-p (name)
  "Non-nil when tool NAME is off: corporate mode turns it off."
  (let ((tool (harness-tool-get name)))
    (and tool (harness-tools--corporate-off-p name (harness-tool-kind tool)))))

(defun harness-tools--corporate-refusal (name kind)
  "Return the decision refusing a call of tool NAME, of KIND, or nil.
With `harness-corporate-mode' on, the tools of kind net other than web
search and ssh are off (`harness-tools--corporate-off-p'): a call to
one is refused without asking the `permission/decide' chain, so no
permission mode, standing rule or answer lets it run.  A web search is
not refused here: the chain decides it, as any other call."
  (when (harness-tools--corporate-off-p name kind)
    (list :behavior 'deny
          :reason (if (member name harness-tools--corporate-remote-tools)
                      "corporate mode: tools that reach other machines are off"
                    "corporate mode: network tools other than web search are off")
          :hint harness-tools-corporate-hint)))

(defun harness-tools--decide (request)
  "Return a promise of the permission decision on REQUEST.
A call corporate mode refuses (`harness-tools--corporate-refusal')
never reaches the `permission/decide' chain; any other call does."
  (let ((refusal (harness-tools--corporate-refusal (plist-get request :tool)
                                                   (plist-get request :kind))))
    (if refusal
        (harness-resolved refusal)
      (harness-run-filter-async 'permission/decide (list :behavior 'ask) request))))

;;;; Tools a provider runs itself

(defun harness-tools--names (session)
  "Return the names of the tools SESSION gets, after `agent/tools'.
In corporate mode no session gets the tools of kind net other than web
search, nor ssh (`harness-tools--off-p').  Without SESSION, every
registered tool: a catalogue, offered to no model."
  (let ((names (let (n) (maphash (lambda (k _) (push k n)) harness-tools) (sort n #'string<))))
    (if session
        (cl-remove-if #'harness-tools--off-p (harness-run-filter 'agent/tools names session))
      names)))

(defun harness-tools--offered (session)
  "Return the harness tools that SESSION's provider has counterparts of.
They are the `:builtin-tools' capability of SESSION's model."
  (let ((model (plist-get session :model)))
    (when (and (stringp model) (harness-method-exists-p 'provider/capabilities))
      (condition-case err
          (let ((offered (plist-get (harness-call 'provider/capabilities model) :builtin-tools)))
            (and (listp offered) offered))
        (error (harness-log 'warn "tools: capabilities of %s: %s" model (harness-error-message err))
               nil)))))

(defun harness-tools--builtin (session names)
  "Return the tools among NAMES that SESSION's provider runs itself.
The provider must offer them (`harness-tools--offered') and the sync
filter `agent/builtin-tools' pick them."
  (when-let* ((offered (and session (harness-tools--offered session))))
    (let ((chosen (harness-run-filter 'agent/builtin-tools nil session offered)))
      (cl-remove-if-not (lambda (n) (and (member n offered) (member n chosen))) names))))

;;;; Methods

(harness-defmethod tools/list (&optional session-id)
  "Return tool specs available to SESSION-ID (or all), after `agent/tools'.
The tools SESSION-ID's provider runs itself (see `tools/builtin') are
left out, and in corporate mode (`harness-corporate-mode') the tools of
kind net other than web search, and ssh.  Without SESSION-ID, every
registered tool is listed."
  (let* ((session (and session-id (harness-tools--session session-id)))
         (names (harness-tools--names session))
         (builtin (harness-tools--builtin session names))
         (names (cl-remove-if (lambda (n) (member n builtin)) names)))
    (delq nil (mapcar (lambda (n) (let ((tool (harness-tool-get n))) (and tool (harness-tool-spec tool)))) names))))

(harness-defmethod tools/builtin (session-id)
  "Return the names of the harness tools that SESSION-ID's provider runs itself.
A provider names the harness tools it has a counterpart of in its
`:builtin-tools' capability (Claude Code's web search for web_search,
say).  The sync filter `agent/builtin-tools' (value: list of names,
initially nil; args: the session and the names its provider offers)
picks the ones the provider should run; only tools the session would
get otherwise count, so in corporate mode web search may be among
them, but no other tool of kind net.  `tools/list' leaves them out,
and the agent asks the provider to turn them on with the request's
`:builtin-tools'."
  (let ((session (harness-tools--session session-id)))
    (harness-tools--builtin session (harness-tools--names session))))

(defun harness-tools-denial-message (decision)
  "Return what the model is told when permission DECISION refuses a call."
  (format "Denied: %s%s"
          (or (plist-get decision :reason)
              (if (eq (plist-get decision :behavior) 'ask) "no permission handler answered"
                "not permitted"))
          (if (plist-get decision :hint) (concat " " (plist-get decision :hint)) "")))

(harness-defmethod tools/authorize (session-id call)
  "Decide whether CALL (:id :name :input :kind) of SESSION-ID may run.
Nothing runs: this is for a tool the provider runs itself (see
`tools/builtin'), whose call still needs the harness's permission.  The
call goes through the `permission/decide' chain as `tools/execute'
sends it, as a call of the harness tool NAME: that tool's kind and paths
apply when it is registered, else CALL's `:kind', else exec.  In
corporate mode a call of kind net is denied without asking the chain,
unless it is a web search, and so is one of ssh
\(`harness-tools--corporate-refusal').  Emits
`permission/decided'.  Return a promise of the DECISION, whose
`:behavior' is allow or deny; a denial carries `:message', what the
model is told."
  (let* ((name (plist-get call :name))
         (call-id (or (plist-get call :id) (harness-short-id)))
         (input (plist-get call :input))
         (tool (harness-tool-get name))
         (kind (plist-get call :kind))
         (session (harness-tools--session session-id))
         (ctx (list :session-id session-id :cwd (plist-get session :cwd)
                    :host (plist-get session :host) :call-id call-id))
         (request (list :session session :tool name :input input
                        :kind (cond (tool (harness-tool-kind tool))
                                    ((stringp kind) (intern kind))
                                    ((and kind (symbolp kind)) kind)
                                    (t 'exec))
                        :paths (and tool (harness-tools--paths tool input ctx))
                        :call-id call-id
                        :builtin t)))
    (harness-then
     (harness-tools--decide request)
     (lambda (decision)
       (harness-emit 'permission/decided session-id request decision)
       (if (eq (plist-get decision :behavior) 'allow)
           decision
         (append (list :behavior 'deny :message (harness-tools-denial-message decision))
                 (harness-plist-remove decision :behavior :message)))))))

(harness-defmethod tools/get (name)
  "Return the spec of tool NAME or nil."
  (let ((tool (harness-tool-get name))) (and tool (harness-tool-spec tool))))

(defun harness-tools--run-handler (tool input ctx)
  "Run TOOL's handler with INPUT under CTX; return a promise of its result.
The result is normalised, and an error once the tool's timeout has
passed.  A handler that signals, or whose promise rejects, fails the
call with a result that says why (`harness-tools--failure')."
  (harness-with-promise (resolve reject)
    (let* ((timeout (or (harness-tool-timeout tool) harness-tools--timeout))
           (timer nil)
           (settled nil)
           (finish (lambda (value)
                     (unless settled
                       (setq settled t)
                       (when timer (cancel-timer timer))
                       (funcall resolve (harness-tools--normalise-result value)))))
           (fail (lambda (err)
                   (harness-then (harness-tools--failure tool input ctx err) finish))))
      (ignore reject)
      (setq timer (run-at-time timeout nil
                               (lambda ()
                                 (funcall finish (harness-tool-error
                                                  (format "Tool %s timed out after %ss" (harness-tool-name tool) timeout))))))
      (condition-case err
          (let ((value (funcall (harness-tool-handler tool) input ctx)))
            (if (harness-promise-p value)
                (harness-then value finish fail)
              (funcall finish value)))
        (error (funcall fail err))))))

(harness-defmethod tools/execute (session-id call)
  "Execute CALL (:id :name :input) for SESSION-ID; return a promise of a RESULT.
The `permission/decide' chain decides first; in corporate mode a call of
a tool of kind net is denied without asking it, unless it is a web
search, and so is a call of ssh (`harness-tools--corporate-refusal')."
  (let* ((name (plist-get call :name))
         (call-id (or (plist-get call :id) (harness-short-id)))
         (input (plist-get call :input))
         (tool (harness-tool-get name))
         (session (harness-tools--session session-id))
         (ctx (list :session-id session-id :cwd (plist-get session :cwd)
                    :host (plist-get session :host) :call-id call-id
                    :report (lambda (text)
                              (harness-emit 'tools/progress session-id call-id text)))))
    (harness-emit 'tools/started session-id call)
    (cond
     ((null tool)
      (let ((r (harness-tool-error (format "Unknown tool %s. Available: %s" name
                                           (mapconcat (lambda (s) (plist-get s :name))
                                                      (harness-call 'tools/list session-id) ", ")))))
        (harness-emit 'tools/finished session-id call r)
        (harness-resolved r)))
     (t
      (let* ((request (list :session session :tool name :input input
                            :kind (harness-tool-kind tool)
                            :paths (harness-tools--paths tool input ctx)
                            :call-id call-id))
             (decision (harness-tools--decide request)))
        (harness-then
         decision
         (lambda (decision)
           (let ((behavior (plist-get decision :behavior)))
             (harness-emit 'permission/decided session-id request decision)
             (harness-then
              (if (eq behavior 'allow)
                  (harness-tools--run-handler tool (or (plist-get decision :input) input) ctx)
                (harness-resolved
                 (harness-tool-error (harness-tools-denial-message decision) :denied t)))
              (lambda (result)
                (let* ((result (harness-tools--guard-size result call-id))
                       (result (harness-run-filter 'tools/result result session-id call)))
                  (harness-emit 'tools/finished session-id call result)
                  result)))))))))))

(harness-declare-event 'tools/started "(SESSION-ID CALL) before permission and execution.")
(harness-declare-event 'tools/progress "(SESSION-ID CALL-ID TEXT) progress from a running tool.")
(harness-declare-event 'tools/finished "(SESSION-ID CALL RESULT) after execution or denial.")
(harness-declare-event 'tools/file-written "(PATH) after a tool wrote PATH; the UI reverts buffers visiting it.")
(harness-declare-event 'permission/decided "(SESSION-ID REQUEST DECISION) after the permission chain.")

(harness-define-module 'tools
  :doc "Tool registry, permission-gated execution and context-bomb guard.")

(provide 'harness-tools)
;;; harness-tools.el ends here
