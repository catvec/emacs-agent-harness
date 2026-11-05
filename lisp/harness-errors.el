;;; harness-errors.el --- The details of harness errors  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; When something inside the harness fails, what the user and the agent
;; see is often one short line in the log or in the UI; the stack that
;; led there is gone.  This file keeps the details: the harness catches
;; an error where it must not escape -- a promise callback, an event
;; subscriber, a filter, a module's init, a process filter or sentinel --
;; and appends a report of it to `harness-error-details-file', with the
;; stack trace taken where it was signalled, the session and task it
;; happened for, and what the harness was doing.
;;
;; The trace is taken by `signal-hook-function', which runs inside
;; `signal' before `condition-case' unwinds the stack.  A catcher binds
;; `harness-error-report--depth' around the code it runs; the hook takes
;; a trace then, and the catcher writes the report in its error handler,
;; where the trace is still at hand in `harness-error-report--signals'.
;; The hook also remembers the last error signalled from a harness frame,
;; so that an error caught far from where it was signalled -- by
;; `command-error-function', say -- can still be reported with its
;; trace.
;;
;; The file lives in `harness-state-directory' by default, outside the
;; directories a session may read without approval: an agent is told the
;; file exists by its system prompt, but cannot read it until the user
;; allows that.  The harness reads the reports back as plists
;; (`harness-error-reports'), which its `errors/recent' and `errors/path'
;; methods give a client and the `read_harness_errors' tool gives an
;; agent; the tool asks the user for the file, since the permission
;; chain does not let a session inspect it.  What is written goes
;; through the log filter first, as a log line does, so a secret the
;; secrets module masks is not written here.
;;
;; Nothing in this file may signal from the reporting path: it runs where
;; the harness has just failed, and a failure to report an error must
;; never become one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)
(defvar harness-process)
(defvar harness-tools-calling-session)

(defcustom harness-error-details-file nil
  "File where the harness writes the details of its errors.
The default, nil, is \"error-details.log\" in
`harness-state-directory'.  The file is appended to, outside the
directories a session may read without approval; a report has the
stack trace of the error, the session and task it happened for, and
what the harness was doing.  Set it to a file to keep the reports
elsewhere."
  :type '(choice (const :tag "In the harness state directory" nil)
                 (file :tag "This file"))
  :group 'harness)

(defcustom harness-error-reporting t
  "Non-nil makes the harness write the details of its errors to a file.
See `harness-error-details-file'.  This is on by default: the details
are what makes a harness bug one that can be fixed.  Reporting never
signals and never holds up the work that failed."
  :type 'boolean
  :group 'harness)

(defcustom harness-error-details-max-bytes (* 4 1024 1024)
  "Size past which the error details file is rotated.
When a report would make the file larger, it is renamed to FILE.1,
replacing an older FILE.1, and a new file is started.  nil keeps one
file however large it grows."
  :type '(choice (const :tag "Keep every report" nil)
                 (integer :tag "Bytes"))
  :group 'harness)

(defconst harness-error-report-frame-limit 1000
  "Most stack frames one report keeps.
The innermost frames are the ones that say what failed; this only
keeps a runaway recursion from making one report unbounded.")

(defconst harness-error-report-frame-chars 500
  "Longest text one stack frame may take in a report, in characters.")

(defconst harness-error-report-data-chars 8000
  "Longest text of an error's data one report may quote, in characters.")

(defconst harness-error-report-max-chars 500000
  "Longest one whole report may be, in characters.")

(defvar harness-error-report--installed nil
  "Non-nil when `harness-error-report-install' has run in this Emacs.")

(defvar harness-error-report--previous-signal-hook nil
  "The `signal-hook-function' that was installed before the harness's own.")

(defvar harness-error-report--previous-command-error nil
  "The `command-error-function' that was installed before the harness's own.")

(defvar harness-error-report--last-signal nil
  "The last error signalled from a harness frame, with its trace.
A plist of `:error' (the error data list), `:trace' (a string or nil),
`:at' (the time it was signalled) and `:harness' (non-nil when a
harness function was on the stack).  It is what `command-error-function'
reports when an error was caught after the stack unwound.")

(defvar harness-error-report--writing nil
  "Non-nil while `harness-error-report' writes, so it cannot recurse.")

;;;; Where the details go

(defun harness-error-details-path ()
  "Return the file where the harness writes the details of its errors.
That is `harness-error-details-file', or \"error-details.log\" in
`harness-state-directory'."
  (expand-file-name
   (or harness-error-details-file "error-details.log")
   (cond ((and (boundp 'harness-state-directory)
               (stringp harness-state-directory))
          harness-state-directory)
         ((boundp 'user-emacs-directory)
          (expand-file-name "harness/" user-emacs-directory))
         (t temporary-file-directory))))

(defun harness-show-error-details ()
  "Open the file where the harness writes the details of its errors.
A report has the stack trace of an error, the session and task it
happened for, and what the harness was doing.  See
`harness-error-details-file'."
  (interactive)
  (find-file (harness-error-details-path)))

;;;; Taking the trace

(defun harness-error-report--frame-text (evald fn args)
  "Return one stack frame of FN, called with ARGS, as text.
EVALD says whether ARGS are values or forms.  The frame is bounded so
that one argument holding a whole transcript cannot make the report
huge."
  (let ((text (condition-case nil
                  (let ((print-length 8)
                        (print-level 4)
                        (print-circle t))
                    (format "%s%S %S" (if evald "" "…") fn args))
                (error "#<frame not printable>"))))
    (if (> (length text) harness-error-report-frame-chars)
        (concat (substring text 0 (1- harness-error-report-frame-chars)) "…")
      text)))

(defconst harness-error-report--internal-frames
  '(harness-error-report harness-error-report-maybe mapbacktrace)
  "Functions of the reporter itself, left out of a trace and its harness check.")

(defun harness-error-report--internal-frame-p (fn)
  "Non-nil when FN is a function of the reporter itself."
  (or (memq fn harness-error-report--internal-frames)
      (and (symbolp fn)
           (string-prefix-p "harness-error-report--" (symbol-name fn)))))

(defun harness-error-report--frames ()
  "Return the current stack as (:frames FRAMES :harness BOOL).
FRAMES are the frames innermost first, each (EVALD FN ARGS), bounded by
`harness-error-report-frame-limit'.  HARNESS is non-nil when a function
named `harness-…' was on the stack, which tells an error inside the
harness from one elsewhere in Emacs.  Never signals."
  (let ((frames nil)
        (harness nil))
    (cl-labels ((collect (evald fn args _flags)
                  (unless (harness-error-report--internal-frame-p fn)
                    (when (and (symbolp fn)
                               (string-prefix-p "harness-" (symbol-name fn)))
                      (setq harness t)))
                  (push (list evald fn args) frames)))
      (condition-case nil
          ;; Start at `signal', which is where the error is: the frames of
          ;; the hook and of this capture say nothing about what failed.
          (mapbacktrace #'collect 'signal)
        (error nil))
      (unless frames
        ;; `signal' is a C function when the error comes from one (`car'
        ;; of a number, say), so there is no Lisp frame to start at.  Take
        ;; the whole stack, and leave out the reporter's own frames above
        ;; the hook.
        (setq frames nil)
        (mapbacktrace #'collect)
        (setq frames (nreverse frames))
        (let ((tail (cl-member 'harness-error-report--signal-hook frames
                               :key (lambda (frame) (nth 1 frame)) :test #'eq)))
          (when tail (setq frames (cdr tail))))))
    (list :frames (cl-subseq frames 0 (min (length frames)
                                           harness-error-report-frame-limit))
          :harness harness)))

(defun harness-error-report--trace-string (frames)
  "Return FRAMES, as `harness-error-report--frames' lists them, as text."
  (if (null frames)
      "  (no stack trace)"
    (let ((n 0)
          (lines nil))
      (dolist (frame frames)
        (push (format "%4d  %s" n
                      (harness-error-report--frame-text
                       (nth 0 frame) (nth 1 frame) (nth 2 frame)))
              lines)
        (setq n (1+ n)))
      (concat (mapconcat #'identity (nreverse lines) "\n")
              (if (>= n harness-error-report-frame-limit)
                  (format "\n  … (%d more frames not shown)" n)
                "")))))

(defun harness-error-report--capture ()
  "Return the current stack as (:trace TEXT :harness BOOL).
See `harness-error-report--frames'."
  (let ((capture (harness-error-report--frames)))
    (list :trace (harness-error-report--trace-string (plist-get capture :frames))
          :harness (plist-get capture :harness))))

(defun harness-error-report--worth-trace-p (err)
  "Non-nil when ERR is worth keeping a stack trace for outside a catcher.
Deliberate refusals -- `harness-error' and its subtypes -- are the
harness saying no, and are signalled too often to walk the stack for
each; an unexpected `error', a wrong type or a file error may escape a
process filter, where only the trace taken now can say what failed."
  (let ((symbol (car-safe err)))
    (not (memq symbol '(quit user-error harness-error harness-no-such-method
                        harness-module-error)))))

(defun harness-error-report--signal-hook (error data)
  "Remember ERROR, signalled with DATA, and its stack trace.
Installed as `signal-hook-function'.  A `quit' is not an error and a
`user-error' is deliberate; neither is reported.  The hook runs inside
`signal', before `condition-case' unwinds the stack, so it can keep a
trace that the catcher could not take later.  The frames are kept, not
printed: a trace is made only when a report is written."
  (when (and harness-error-report--previous-signal-hook
             (not (eq harness-error-report--previous-signal-hook
                      #'harness-error-report--signal-hook)))
    (condition-case nil
        (funcall harness-error-report--previous-signal-hook error data)
      (error nil)))
  (when (and harness-error-reporting
             (not (memq error '(quit user-error)))
             (or (> (or harness-error-report--depth 0) 0)
                 (harness-error-report--worth-trace-p (cons error data))))
    (condition-case nil
        (let* ((err (cons error data))
               (capture (harness-error-report--frames))
               (record (list :error err
                             :frames (plist-get capture :frames)
                             :session (and (boundp 'harness-error-report-session)
                                           harness-error-report-session)
                             :task (and (boundp 'harness-error-report-task)
                                        harness-error-report-task)
                             :context (and (boundp 'harness-error-report-context)
                                           harness-error-report-context)
                             :at (float-time))))
          (when (> (or harness-error-report--depth 0) 0)
            (push record harness-error-report--signals)
            (when (> (length harness-error-report--signals) 20)
              (setcdr (nthcdr 19 harness-error-report--signals) nil)))
          (when (plist-get capture :harness)
            (setq harness-error-report--last-signal record)))
      (error nil))))

(defun harness-error-report--trace-for (err)
  "Return the trace taken when ERR was signalled, or nil.
The trace comes from the current catcher's records, or from the last
error signalled from a harness frame when it is still close in time."
  (let ((record (cl-find err harness-error-report--signals
                         :key (lambda (record) (plist-get record :error))
                         :test #'equal)))
    (unless record
      (let ((last harness-error-report--last-signal))
        (when (and last
                   (equal err (plist-get last :error))
                   (< (- (float-time) (or (plist-get last :at) 0)) 5))
          (setq record last))))
    (when record
      (harness-error-report--trace-string (plist-get record :frames)))))

(defun harness-error-report--session-for (err)
  "Return the session an error ERR happened for, as far as it is known."
  (or (and (boundp 'harness-error-report-session) harness-error-report-session)
      (and (boundp 'harness-tools-calling-session) harness-tools-calling-session)
      (let ((record (cl-find err harness-error-report--signals
                             :key (lambda (record) (plist-get record :error))
                             :test #'equal)))
        (or (plist-get record :session)
            (let ((last harness-error-report--last-signal))
              (and last
                   (equal err (plist-get last :error))
                   (plist-get last :session)))))))

(defun harness-error-report--task-for (session-id)
  "Return the id of the task SESSION-ID works on, or nil.
The tasks module is not core; without it, or when SESSION-ID is no
task's, there is no task id."
  (when (and session-id (fboundp 'harness-method-exists-p)
             (harness-method-exists-p 'task/for-session))
    (condition-case nil
        (plist-get (harness-call 'task/for-session session-id) :id)
      (error nil))))

;;;; Writing a report

(defun harness-error-report--error-text (err)
  "Return ERR, the error data list, as bounded text for a report."
  (let ((text (condition-case nil
                  (let ((print-length 50)
                        (print-level 8)
                        (print-circle t))
                    (format "%S" err))
                (error "#<error not printable>"))))
    (if (> (length text) harness-error-report-data-chars)
        (concat (substring text 0 (1- harness-error-report-data-chars)) "…")
      text)))

(defun harness-error-report--rotate (file)
  "Rotate FILE to FILE.1 when it has grown past the configured size.
See `harness-error-details-max-bytes'."
  (when (and harness-error-details-max-bytes
             (file-exists-p file)
             (let ((size (file-attribute-size (file-attributes file))))
               (and (numberp size) (> size harness-error-details-max-bytes))))
    (let ((old (concat file ".1")))
      (ignore-errors (delete-file old))
      (ignore-errors (rename-file file old t)))))

(defun harness-error-report--write (text)
  "Append TEXT to `harness-error-details-path'; return the file or nil.
A failure to write is logged short and never signals."
  (let ((file (harness-error-details-path)))
    (condition-case err
        (progn
          (make-directory (file-name-directory file) t)
          (harness-error-report--rotate file)
          (let ((coding-system-for-write 'utf-8-unix)
                (write-region-inhibit-fsync t)
                ;; Two harness processes (the UI and its child) append to
                ;; the same file; neither should leave a lock file.
                (create-lockfiles nil))
            (write-region text nil file t 'silent))
          ;; A report may quote a transcript or a request body, and the log
          ;; filter masks only secrets it knows.
          (ignore-errors (set-file-modes file #o600))
          file)
      (error (harness-log 'warn "errors: could not write the details of an error to %s: %s"
                          file (error-message-string err))
             nil))))

(cl-defun harness-error-report (err &key context session task backtrace)
  "Append a report of ERR to `harness-error-details-file' and return its path.
CONTEXT says what the harness was doing, such as \"promise callback\";
SESSION is the id of the session and TASK the id of the task the error
happened for, when known.  BACKTRACE is the stack trace to keep; by
default it is the trace taken when ERR was signalled, or the stack as
it is now.  The report is filtered through
`harness-log-filter-function', so secrets the log masks are masked
here too.  Return nil when the report could not be written.  This
never signals."
  (when (and harness-error-reporting (not harness-error-report--writing))
    (let* ((harness-error-report--writing t)
           (session (or session (harness-error-report--session-for err)))
           (task (or task
                     (and (boundp 'harness-error-report-task) harness-error-report-task)
                     (harness-error-report--task-for session)))
           (context (or context
                        (and (boundp 'harness-error-report-context) harness-error-report-context)
                        (plist-get harness-error-report--last-signal :context)
                        "harness error"))
           (trace (or backtrace
                      (harness-error-report--trace-for err)
                      (plist-get (harness-error-report--capture) :trace)))
           (text (format
                  (concat "======================================================================\n"
                          "HARNESS ERROR %s\n"
                          "======================================================================\n"
                          "Process: %s (pid %d), Emacs %s, harness %s\n"
                          "Where:   %s\n"
                          "Session: %s\n"
                          "Task:    %s\n"
                          "Error:   %s\n"
                          "Message: %s\n"
                          "Stack trace:\n%s\n\n")
                  (format-time-string "%Y-%m-%d %H:%M:%S%z")
                  (if (and (boundp 'harness-process) harness-process)
                      "UI (the harness runs in a child process)"
                    "harness process")
                  (emacs-pid) emacs-version
                  (or (and (boundp 'harness-version) harness-version) "?")
                  (or context "harness error")
                  (or session "-")
                  (or task "-")
                  (harness-error-report--error-text err)
                  (if (fboundp 'harness-error-message)
                      (harness-error-message err)
                    (error-message-string err))
                  (or trace "  (no stack trace)"))))
      (when (> (length text) harness-error-report-max-chars)
        (setq text (concat (substring text 0 (1- harness-error-report-max-chars))
                           "\n… (the report was cut)\n")))
      ;; The same filter the log uses, so a secret the secrets module
      ;; knows is not written into a file a person or an agent may read.
      (when (fboundp 'harness--log-filtered)
        (setq text (harness--log-filtered text)))
      (harness-error-report--write text))))

(defun harness-error-report-maybe (err &rest args)
  "Report ERR as `harness-error-report' does, when reporting is on.
ARGS are the keyword arguments of `harness-error-report'.  A catcher
of the harness's own calls this from within its boundary
\(`harness-error-report--depth'), so it reports even before
`harness-error-report-install'; the install adds the global hooks that
take traces from timers, commands and process filters, which a bare
library load does not touch."
  (when (and harness-error-reporting
             (or harness-error-report--installed
                 (> (or harness-error-report--depth 0) 0))
             (let ((symbol (car-safe err)))
               (not (memq symbol '(quit user-error)))))
    (apply #'harness-error-report err args)))

(defun harness-error-report-internal-p (err)
  "Non-nil when ERR looks like a harness bug rather than a refusal.
`error' with a string is how the harness refuses a call on purpose,
as are `harness-error', `user-error', `quit' and the file and process
errors a tool reports; the rest -- a wrong type, a missing function, a
bad argument count -- are bugs worth a report."
  (let ((symbol (car-safe err)))
    (and symbol
         (not (memq symbol '(quit user-error error harness-error
                             harness-no-such-method harness-module-error
                             file-error file-missing file-already-exists
                             process-error remote-file-error)))
         t)))

;;;; Reading the details
;;
;; A report is written for a person to read, so it is text with a header
;; and the stack below it.  The reader parses that text back into
;; plists, which is what `errors/recent' gives a client and what the
;; `read_harness_errors' tool gives an agent.  The format is made here
;; and read here, so a change to one is a change to both.

(defconst harness-error-report--separator
  "======================================================================"
  "The line that opens and closes a report in the details file.")

(defun harness-error-details-files ()
  "Return the files that hold the details of harness errors, newest first.
That is `harness-error-details-path' and the file it is rotated to,
FILE.1, whether or not either exists yet."
  (let ((file (harness-error-details-path)))
    (list file (concat file ".1"))))

(defun harness-error-report--size (file)
  "Return the size of FILE in bytes, or nil when FILE is not there."
  (let ((attributes (file-attributes file)))
    (and attributes (file-attribute-size attributes))))

(defun harness-error-report--blocks (text)
  "Return the report blocks in TEXT, oldest first, each as a list of lines.
A block starts with `harness-error-report--separator' when the line
after it is the \"HARNESS ERROR\" line of a report, and runs to the
next such start."
  (let ((lines (split-string text "\n"))
        (blocks nil)
        (block nil))
    (while lines
      (let ((line (pop lines)))
        (if (and (equal line harness-error-report--separator)
                 (string-prefix-p "HARNESS ERROR " (or (car lines) "")))
            (progn
              (when block (push (nreverse block) blocks))
              (setq block (list line)))
          (when block (push line block)))))
    (when block (push (nreverse block) blocks))
    (nreverse blocks)))

(defun harness-error-report--field (line)
  "Return (KEY . VALUE) when LINE is a header line of a report, or nil.
KEY is `:process', `:where', `:session', `:task', `:error' or
`:message'."
  (when (string-match
         "\\`\\(Process\\|Where\\|Session\\|Task\\|Error\\|Message\\):[ \t]*\\(.*\\)\\'"
         line)
    (cons (intern (concat ":" (downcase (match-string 1 line))))
          (match-string 2 line))))

(defun harness-error-report--parse-block (lines)
  "Return the report in LINES, a list of lines, as a plist, or nil.
The keys are those of `harness-error-reports'."
  (when (and (cdr lines) (string-prefix-p "HARNESS ERROR " (nth 1 lines)))
    (let* ((time (string-trim (substring (nth 1 lines) (length "HARNESS ERROR "))))
           (rest (nthcdr 2 lines))
           (trace-at (cl-position-if (lambda (line) (string-prefix-p "Stack trace:" line))
                                     rest))
           (head (if trace-at (cl-subseq rest 0 trace-at) rest))
           (trace (if trace-at (cl-subseq rest (1+ trace-at)) nil))
           (fields (list :time time))
           (message-more nil))
      (dolist (line head)
        (let ((field (harness-error-report--field line)))
          (cond
           (field
            (setq message-more (eq (car field) :message))
            (setq fields (plist-put fields (car field) (cdr field))))
           ((and message-more (not (string-empty-p line)))
            ;; A message may run over more than one line.
            (setq fields (plist-put fields :message
                                    (concat (plist-get fields :message) "\n" line)))))))
      ;; The writer uses "-" for an id it does not know.
      (dolist (key '(:session :task))
        (when (equal (plist-get fields key) "-")
          (setq fields (plist-put fields key nil))))
      (when (and trace (string-empty-p (string-trim (mapconcat #'identity trace ""))))
        (setq trace nil))
      (append fields
              (list :trace (and trace (string-trim-right (mapconcat #'identity trace "\n")))
                    :text (string-trim-right (mapconcat #'identity lines "\n")))))))

(defun harness-error-report--read-file (file)
  "Return the reports in FILE, newest first, each as a plist.
Return nil when FILE is not there or cannot be read.  Never signals."
  (condition-case err
      (when (file-readable-p file)
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents file))
          (let ((blocks (harness-error-report--blocks (buffer-string))))
            (delq nil (mapcar #'harness-error-report--parse-block
                              (nreverse blocks))))))
    (error (harness-log 'debug "errors: could not read %s: %s"
                        file (error-message-string err))
           nil)))

(defun harness-error-reports (&optional limit session task)
  "Return the details of harness errors, newest first.
LIMIT keeps only that many of the newest reports, nil for all.
SESSION and TASK keep only the reports that happened for that session
or task id; nil keeps every report.  Each report is a plist of :time,
:process, :where, :session, :task, :error, :message, :trace and :text,
the last the report as it was written.  The rotated file (FILE.1) is
read after the current one.  Never signals: a file that cannot be
read, or a report the parser does not understand, gives no report."
  (let ((reports nil))
    (dolist (file (harness-error-details-files))
      (setq reports (nconc reports (harness-error-report--read-file file))))
    (when (or session task)
      (setq reports (cl-remove-if-not
                     (lambda (report)
                       (and (or (null session) (equal session (plist-get report :session)))
                            (or (null task) (equal task (plist-get report :task)))))
                     reports)))
    (when limit
      (setq reports (cl-subseq reports 0 (min limit (length reports)))))
    reports))

(harness-defmethod errors/path ()
  "Return where the harness writes the details of its errors.
A plist of :file, the file reports go to, :exists and :size of that
file, and :rotated, the same for the file it is rotated to (FILE.1)."
  (let ((file (harness-error-details-path))
        (old (concat (harness-error-details-path) ".1")))
    (list :file file
          :exists (file-exists-p file)
          :size (harness-error-report--size file)
          :rotated (list :file old
                         :exists (file-exists-p old)
                         :size (harness-error-report--size old)))))

(harness-defmethod errors/recent (&optional limit session task)
  "Return the details of recent harness errors, newest first.
LIMIT is how many reports to return, 10 by default and at most 100.
SESSION and TASK keep only the reports that happened for that session
or task id.  Each report is a plist of :time, :process, :where,
:session, :task, :error, :message, :trace and :text; see
`harness-error-reports'."
  (let ((count (cond ((null limit) 10)
                     ((numberp limit) (max 1 (min 100 (floor limit))))
                     ((and (stringp limit)
                           (string-match-p "\\`[0-9]+\\'" limit))
                      (max 1 (min 100 (string-to-number limit))))
                     (t (signal 'harness-error
                                (list "The limit is a number of reports, 1 to 100"))))))
    (harness-error-reports count session task)))

;;;; Installing the catcher

(defvar harness-error-report--timer-advised nil
  "Non-nil when `harness-error-report--around-timer' advises the timer handler.")

(defun harness-error-report--around-timer (function &rest args)
  "Call FUNCTION, a timer handler, and report an error signalled inside it.
ARGS are its arguments.  `timer-event-handler' catches an error its
timer signals and only shows it in *Messages*; the report keeps its
trace.  Every error signalled during this call is seen, including one
in an anonymous timer function whose stack names no harness function;
the newest is reported."
  (let ((start (float-time))
        (harness-error-report--depth (1+ harness-error-report--depth))
        (harness-error-report--signals nil))
    (prog1 (apply function args)
      (let ((record (cl-find-if
                     (lambda (record)
                       (harness-error-report--worth-trace-p (plist-get record :error)))
                     harness-error-report--signals)))
        (when (and record
                   (>= (or (plist-get record :at) 0) start))
          (condition-case nil
              (harness-error-report-maybe
               (plist-get record :error)
               :context "timer"
               :session (plist-get record :session)
               :task (plist-get record :task))
            (error nil)))))))

(defun harness-error-report--timer-advice-install ()
  "Make the timer handler report the errors of the timers it runs."
  (when (and (fboundp 'timer-event-handler)
             (not harness-error-report--timer-advised)
             (not (advice-member-p #'harness-error-report--around-timer
                                   'timer-event-handler)))
    (advice-add 'timer-event-handler :around #'harness-error-report--around-timer)
    (setq harness-error-report--timer-advised t)))

(defun harness-error-report--timer-advice-remove ()
  "Take the timer handler's error report out again."
  (when (advice-member-p #'harness-error-report--around-timer 'timer-event-handler)
    (advice-remove 'timer-event-handler #'harness-error-report--around-timer))
  (setq harness-error-report--timer-advised nil))

(defun harness-error-report--command-error (data context signal)
  "Report DATA, an error that escaped a command, then hand it on.
CONTEXT and SIGNAL are as `command-error-function' passes them.
Installed as `command-error-function' in an Emacs that does not run
the harness process's own (`harness-server--command-error').  Only an
error signalled from a harness frame is reported, so an error in the
user's own Emacs code is left alone."
  (when (and harness-error-report--last-signal
             (equal data (plist-get harness-error-report--last-signal :error)))
    (condition-case nil
        (harness-error-report-maybe data :context (or context "command error"))
      (error nil)))
  (when harness-error-report--previous-command-error
    (funcall harness-error-report--previous-command-error data context signal)))

(defun harness-error-report-install ()
  "Install the harness's internal error catcher and reporter.
`signal-hook-function' takes the stack trace of an error before the
stack unwinds; `command-error-function' reports an error that escapes
a command here.  The harness process sets its own command error
handler before this runs, and that one reports for itself, so it is
left as it is.  Safe to call again."
  (interactive)
  (unless harness-error-report--installed
    (setq harness-error-report--installed t
          harness-error-report--previous-signal-hook
          (unless (eq signal-hook-function #'harness-error-report--signal-hook)
            signal-hook-function)
          signal-hook-function #'harness-error-report--signal-hook)
    (harness-error-report--timer-advice-install)
    (unless (eq command-error-function 'harness-server--command-error)
      (setq harness-error-report--previous-command-error
            (or command-error-function #'command-error-default-function)
            command-error-function #'harness-error-report--command-error)))
  t)

(defun harness-error-report-uninstall ()
  "Take the harness's error catcher and reporter back out.
The hooks that were installed before `harness-error-report-install'
are restored.  Reports already written stay."
  (interactive)
  (when harness-error-report--installed
    (when (eq signal-hook-function #'harness-error-report--signal-hook)
      (setq signal-hook-function harness-error-report--previous-signal-hook))
    (harness-error-report--timer-advice-remove)
    (when (eq command-error-function #'harness-error-report--command-error)
      (setq command-error-function harness-error-report--previous-command-error))
    (setq harness-error-report--installed nil
          harness-error-report--previous-signal-hook nil
          harness-error-report--previous-command-error nil))
  nil)

(provide 'harness-errors)
;;; harness-errors.el ends here
