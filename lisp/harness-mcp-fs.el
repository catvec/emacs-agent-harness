;;; harness-mcp-fs.el --- The file tools, as an MCP server that runs in the jail  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The file tools (read_file, write_file, edit_file, list_dir, glob, grep
;; and file_info) touch the files of the machine at the agent's
;; direction.  They used to run in the harness process, behind a check of
;; the paths a call names against the session's directories; a check is
;; a comparison made once, in a process that can reach everything, and
;; the use that follows it can differ from what was compared.  So the
;; harness runs them in a process the kernel confines instead: this file
;; is that process.
;;
;; It is an MCP server (lisp/harness-mcp-protocol.el) on standard input
;; and output, which the harness's MCP host (lisp/modules/harness-mcp.el)
;; starts in the session's sandbox, with the mounts a bash command of the
;; session gets, as `emacs --batch -Q -l lisp/harness-mcp-fs.el -f
;; harness-mcp-fs-main'.  It does not reimplement the tools: it loads the
;; module that defines them (lisp/modules/harness-tools-fs.el) and
;; answers a call by running the very handler the harness runs for a
;; remote path, so the tools behave the same wherever they run.  What
;; differs is what they can reach: a path outside the mounts does not
;; exist for this process, whatever the permission chain, a prompt or a
;; judge decided, and nothing a tool does here can touch it.
;;
;; The harness gives a call what a tool's context holds (the session,
;; the working directory, the call's id) under `_meta' (see
;; `harness-mcp-call'), and the few options of the harness's own that
;; the tools read, under `harness/fs': the output budget, the limits of
;; the images it shows a model, ffmpeg's name, and the directory a
;; copy of an image is made in -- one the harness can read, since the
;; copy is for the model.  A file a tool writes is announced as the
;; event `tools/file-written', so the user's Emacs reverts the buffers
;; that visit it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-mcp-protocol)
(require 'harness-tools-fs)

(defconst harness-mcp-fs-option-variables
  '((:maxOutputChars . harness-tools-max-output-chars)
    (:imageMaxBytes . harness-tools-fs-image-max-bytes)
    (:imageMaxSide . harness-tools-fs-image-max-side)
    (:ffmpeg . harness-tools-fs-ffmpeg)
    (:copyRoot . harness-tools-fs--copy-root)
    (:writable . harness-mcp-fs--writable))
  "The options a call may carry, and the variable each sets in this process.
They are set for good, not bound for the call: a tool that makes an
image copy reads them again when ffmpeg is done, after the call's own
code has returned.  A server serves one session and one call at a time,
so nothing else reads them meanwhile.")

(defvar harness-mcp-fs--writable nil
  "The directories this process can really write, as the harness says.
The sandbox has a /tmp and a home directory of its own, which a write
reaches without error and which nothing outside ever sees; a write to
one is refused, so that the tool does not say it made a file that is not
there.  The kernel confines the process whatever this holds: it is for
the model to be told the truth, not for the jail.")

(defun harness-mcp-fs--refuse-write (name arguments ctx)
  "Return an error result if the write tool NAME would write nowhere real.
That is, outside the directories the sandbox shows writable; nil
otherwise.  ARGUMENTS and CTX are the call's."
  (when (and (member name harness-tools-fs--writing)
             (stringp (plist-get arguments :path)))
    (let ((path (harness-tools-resolve-path (plist-get arguments :path) ctx)))
      (unless (cl-some (lambda (dir) (and (stringp dir) (harness-path-within-p dir path)))
                       harness-mcp-fs--writable)
        (harness-tool-error
         (format "%s is outside the directories this session may write, so the sandbox the tool runs in cannot make the change there. Work inside them, or ask the user for access to its directory."
                 (harness-tools-fs--display path ctx)))))))

(defun harness-mcp-fs--set-options (options)
  "Set the variables of `harness-mcp-fs-option-variables' from OPTIONS, a plist.
A key OPTIONS lacks leaves its variable as it was; a key it has with the
value `:false' (what JSON makes of nil) sets it to nil."
  (cl-loop for (key . variable) in harness-mcp-fs-option-variables
           when (plist-member options key)
           do (let ((value (plist-get options key)))
                (set variable (if (eq value :false) nil value)))))

(defun harness-mcp-fs--context (context)
  "Return the context a tool's handler is given, from CONTEXT, an MCP call's.
It is the call's session, working directory, host and id, which the
harness put in the request's `_meta' (`harness-mcp-context-key').  There
is no `:report' or `:note': the file tools have nothing to say while
they work."
  (let ((call (plist-get (plist-get context :meta) harness-mcp-context-key)))
    (list :session-id (plist-get call :sessionId)
          :cwd (plist-get call :cwd)
          :host (plist-get call :host)
          :call-id (plist-get call :callId))))

(defun harness-mcp-fs--failure (name err)
  "Return the result of the file tool NAME failing with ERR.
It says so as the harness does when a handler of its own signals
\(`harness-tools--failure'), so that a tool answers alike wherever it
runs."
  (harness-tool-error (format "Tool %s failed: %s" name (harness-error-message err))))

(defun harness-mcp-fs--handler (name)
  "Return the MCP handler of the file tool NAME.
It sets the call's options, then runs the handler the harness runs for
the tool, with the call's arguments and context.  The result is a
harness tool RESULT, or a promise of one (grep, and an image made
smaller by ffmpeg, wait for a process)."
  (let ((run (cdr (assoc name harness-tools-fs--handlers))))
    (lambda (arguments context)
      (harness-mcp-fs--set-options
       (plist-get (plist-get context :meta) harness-tools-fs-options-key))
      (condition-case err
          (let* ((ctx (harness-mcp-fs--context context))
                 (value (or (harness-mcp-fs--refuse-write name arguments ctx)
                            (funcall run arguments ctx))))
            (if (harness-promise-p value)
                (harness-then value #'identity (lambda (e) (harness-mcp-fs--failure name e)))
              value))
        (error (harness-mcp-fs--failure name err))))))

(defun harness-mcp-fs--tool (name)
  "Return the MCP tool for the file tool NAME, as the harness defines it."
  (let ((tool (harness-tool-get name)))
    (harness-mcp-make-tool
     :name name
     :title (harness-tool-label tool)
     :description (harness-tool-description tool)
     :schema (harness-tool-schema tool)
     :annotations (list :readOnlyHint (if (eq (harness-tool-kind tool) 'read) t :false))
     :handler (harness-mcp-fs--handler name))))

(defvar harness-mcp-fs-server
  (harness-mcp-make-server
   :name "fs" :title "File tools" :version "1"
   :instructions "The harness's file tools, run in the session's sandbox."
   :tools (mapcar #'harness-mcp-fs--tool (mapcar #'car harness-tools-fs--handlers)))
  "The MCP server this process is: the harness's file tools.")

(defun harness-mcp-fs--announce-written (path)
  "Tell the harness that a tool wrote PATH: the event `tools/file-written'.
The host passes on only the events the server was declared to announce,
and this is one."
  (harness-mcp-stdio-write
   (harness-mcp-notification
    "notifications/message"
    (list :level "info" :logger "harness"
          :data (list :event "tools/file-written" :args (list path))))))

(defun harness-mcp-fs-main ()
  "Serve `harness-mcp-fs-server' on standard input and output, and exit.
The entry point of the process the harness starts in the sandbox: it
returns when the host closes the input, which is how the host says the
server should go."
  (harness-on 'tools/file-written #'harness-mcp-fs--announce-written)
  (harness-mcp-stdio-loop harness-mcp-fs-server)
  (kill-emacs 0))

(provide 'harness-mcp-fs)
;;; harness-mcp-fs.el ends here
