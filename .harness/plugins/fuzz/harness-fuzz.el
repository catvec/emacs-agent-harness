;;; harness-fuzz.el --- An AFL++ adapter that fuzzes the harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; The fuzzer is AFL++ (https://github.com/AFLplusplus/AFLplusplus): the
;; mutations, the corpus, the crash detection and the minimiser are its
;; own.  This file is only the adapter that lets AFL++ fuzz Emacs Lisp.
;; It does not generate input and it does not decide what a likely input
;; is; the seed corpus and AFL++ do that.
;;
;; A target is a pure check over one input's bytes, plus a few seed
;; inputs AFL++ starts from:
;;
;;   (harness-fuzz-define-target 'my-parser
;;     :description "The parser I want to break."
;;     :seeds '("{\"a\":1}" "plain text")
;;     :check (lambda (bytes) ... t))
;;
;; CHECK gets the raw bytes of the fuzz input as a unibyte string and
;; returns non-nil when the harness handled them.  A signal, or nil,
;; says the harness broke, and that input is a crash.  A check must
;; treat malformed input as handled: that is the input a fuzzer sends.
;;
;; The adapter is a separate Emacs, started once per input:
;;
;;   emacs --batch -L ... -l harness-fuzz --eval
;;     (harness-fuzz--adapter-main 'my-parser "/path/to/@@")
;;
;; It exits 0 when the check held, 42 when the check broke, and 1 when
;; the adapter itself could not run.  AFL++ is told that 42 is a crash
;; (`AFL_CRASH_EXITCODE') and to keep the message beside the input
;; (`AFL_CRASH_TRACES'); a crash that takes the whole Emacs down is
;; just a signal, which AFL++ has always understood.
;;
;; A campaign writes the seeds, probes them through the adapter once (a
;; broken adapter must not look like a campaign that found nothing),
;; runs one `afl-fuzz' per target, and reads back the crashes and hangs
;; AFL++ saved.  Each crash is minimised with `afl-tmin', the minimiser
;; of the same suite.  The campaign is bounded by executions (`-E') and
;; by wall clock (`-V'), so it is safe to start from a tool call.
;;
;; Emacs Lisp has no AFL++ instrumentation.  The default mode is
;; therefore AFL++'s dumb mode (`-n'): the mutation engine, the corpus,
;; the crash detection and `afl-tmin' are AFL++'s, but it cannot tell
;; which input reached new code.  A project that builds Emacs with
;; afl-cc (CC=afl-cc ./configure && make) points
;; `harness-fuzz-emacs-program' at that Emacs and sets
;; `harness-fuzz-afl-mode' to `instrumented' for coverage-guided
;; campaigns; `qemu' uses AFL++'s QEMU mode when afl-qemu-trace is
;; installed.
;;
;; A target's check runs in the adapter process, never in the harness
;; Emacs: an input that takes Emacs down takes only the adapter with it.
;; The built-in targets are pure parsers and protocol halves -- they
;; touch no session, file, process or network.  A target another
;; project's plugin adds is that plugin's business.
;;
;; No target runs unless a tool asks for it.  A project enables the
;; plugin in its .dir-locals.el, names module tools-fuzz in
;; `harness-plugin-modules', and trusts the entries, as for any plugin
;; (see harness-plugins.el):
;;
;;   ((nil . ((eval . (require 'harness-fuzz-plugin
;;                            (expand-file-name
;;                             ".harness/plugins/fuzz/harness-fuzz-plugin"
;;                             (locate-dominating-file default-directory ".dir-locals.el"))))
;;            (harness-plugin-modules . (tools-fuzz)))))
;;
;; The tools are `fuzz_harness' to run a campaign, `fuzz_targets' to
;; list what it can fuzz, and `fuzz_replay' to run a reported input
;; again.  A target file is loaded into the adapter automatically when
;; the target was defined at the top level of that file; a target
;; defined any other way puts its file in `harness-fuzz-adapter-files'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
;; The libraries the built-in targets read.  They define no state of
;; their own by being loaded; a running harness has them already.
(require 'harness-mcp-protocol)
(require 'harness-links)
(require 'harness-http)
(require 'harness-acp)
(require 'harness-provider)
(require 'harness-session-search)

(defgroup harness-fuzz nil
  "AFL++ fuzzing of the harness's protocol boundaries."
  :group 'harness)

(defconst harness-fuzz-crash-exit-code 42
  "Exit code that says a target's check broke.
AFL++ is told it is a crash with `AFL_CRASH_EXITCODE'; 42 cannot be
confused with Emacs's own exit codes, which are 0 and 1 here.")

(defconst harness-fuzz-broken-exit-code 1
  "Exit code that says the adapter itself could not run.
AFL++ treats it as an ordinary run, so a campaign probes its seeds
before it starts and refuses to call a broken adapter a clean run.")

(defvar harness-fuzz-directory
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "harness-fuzz")))
  "Directory harness-fuzz.el was loaded from, for the adapter's -L.")

;;;; Options

(defcustom harness-fuzz-afl-program "afl-fuzz"
  "The afl-fuzz program, or its path.
AFL++ is at https://github.com/AFLplusplus/AFLplusplus; most package
managers call the package afl++ or afl."
  :type 'string :group 'harness-fuzz)

(defcustom harness-fuzz-tmin-program "afl-tmin"
  "The afl-tmin program, or its path; it minimises a crash.
When it cannot be found, a campaign still reports the crash, only not
minimised."
  :type 'string :group 'harness-fuzz)

(defcustom harness-fuzz-emacs-program nil
  "The Emacs the adapter runs, or nil for the Emacs of this process.
Set it to an Emacs built with AFL++ instrumentation (CC=afl-cc
./configure && make) together with `harness-fuzz-afl-mode' set to
`instrumented' for coverage-guided campaigns."
  :type '(choice (const :tag "This Emacs" nil) string)
  :group 'harness-fuzz)

(defcustom harness-fuzz-afl-mode 'dumb
  "How AFL++ observes the adapter.
`dumb' runs afl-fuzz with -n, its non-instrumented mode: the mutation
engine, corpus, crash detection and minimiser are AFL++'s, but it
cannot tell which input reached new code.  Emacs Lisp has no AFL++
instrumentation, so this is the default and the only mode that works
with a stock Emacs.
`instrumented' runs a normal coverage-guided campaign; point
`harness-fuzz-emacs-program' at an Emacs built with afl-cc.
`qemu' uses AFL++'s QEMU mode (-Q), for a stock Emacs when
afl-qemu-trace is installed."
  :type '(choice (const dumb) (const instrumented) (const qemu))
  :group 'harness-fuzz)

(defcustom harness-fuzz-afl-arguments nil
  "Extra arguments passed to afl-fuzz before the `--' and the adapter.
For example, a dictionary: (\"-x\" \"/path/to/tokens.dict\")."
  :type '(repeat string) :group 'harness-fuzz)

(defcustom harness-fuzz-max-executions 100000
  "Most executions one target's campaign may ask AFL++ for.
A tool's `executions' argument is capped by this."
  :type 'integer :group 'harness-fuzz)

(defcustom harness-fuzz-max-seconds 60
  "Longest one target's campaign may run, in seconds.
A tool's `seconds' argument is capped by this.  Targets run in
parallel, so a campaign of several targets can take a little longer."
  :type 'integer :group 'harness-fuzz)

(defcustom harness-fuzz-timeout 5
  "Seconds one input may take before AFL++ calls it a hang."
  :type 'number :group 'harness-fuzz)

(defcustom harness-fuzz-probe-seconds 5
  "Seconds one seed may take while a campaign probes it."
  :type 'number :group 'harness-fuzz)

(defcustom harness-fuzz-shrink-seconds 30
  "Seconds afl-tmin may spend minimising one crash."
  :type 'number :group 'harness-fuzz)

(defcustom harness-fuzz-parallel-targets
  (max 1 (min 8 (1- (or (num-processors) 2))))
  "How many targets a campaign fuzzes at the same time.
Each one is an afl-fuzz process, and each of its executions starts an
Emacs, so this is what keeps a campaign from filling the machine."
  :type 'integer :group 'harness-fuzz)

(defcustom harness-fuzz-max-crashes 20
  "Most crashes a report prints.
The rest are counted, not printed; `harness-fuzz-last-report' holds
them all."
  :type 'integer :group 'harness-fuzz)

(defcustom harness-fuzz-max-shrink 4
  "Most crashes one campaign minimises with afl-tmin.
One crash per target is chosen, the shortest AFL++ saved, and up to
this many of those are minimised in parallel."
  :type 'integer :group 'harness-fuzz)

(defcustom harness-fuzz-max-input-chars 2000
  "Most characters of a crash's input a report prints.
A longer input is cut short in the report but kept whole in
`harness-fuzz-last-report', which `fuzz_replay' can run by number."
  :type 'integer :group 'harness-fuzz)

(defcustom harness-fuzz-adapter-files nil
  "Files the adapter loads after harness-fuzz.el.
A target defined in a file is found by the adapter without this, when
the definition ran at the top level of that file.  Put a file here when
it was loaded another way, or when it sets up something a target needs
in the adapter."
  :type '(repeat file) :group 'harness-fuzz)

(defcustom harness-fuzz-keep-work-directory nil
  "Whether to keep a campaign's seeds, AFL++ output and crash files.
When nil the temporary directory is removed when the campaign ends.
When t it is kept, and the report names it."
  :type 'boolean :group 'harness-fuzz)

(defvar harness-fuzz--last-report nil
  "The report of the last campaign this Emacs ran, or nil.
`fuzz_replay' can run a crash of it by number.")

;;;; Targets

(cl-defstruct (harness-fuzz-target (:constructor harness-fuzz--make-target)
                                   (:copier nil))
  "A place to fuzz and the property its input must satisfy.
NAME is the symbol clients name it by, DESCRIPTION what it fuzzes,
CHECK gets one input's bytes and returns non-nil when the harness
handled them, SEEDS are the inputs AFL++ starts from, TIMEOUT is how
long one input may take (nil for the default), HIDDEN keeps it out of
the default `all' set, and FILE is the file that defined it, which the
adapter loads."
  name description check seeds timeout hidden file)

(defvar harness-fuzz--targets (make-hash-table :test 'eq)
  "Fuzz target name -> its `harness-fuzz-target'; newest definition wins.")

(cl-defun harness-fuzz-define-target (name &key description check seeds
                                           timeout hidden file)
  "Register fuzz target NAME, replacing one of the same name.
DESCRIPTION says what it fuzzes.  CHECK gets one input's bytes, a
unibyte string exactly as AFL++ wrote them, and returns non-nil when
the harness handled the input; a signal or nil says it broke, and is
the crash a campaign reports.  SEEDS is a non-empty list of strings
AFL++ mutates; a seed is a sample of the input, not a grammar.  TIMEOUT
is how many seconds one input may take (default `harness-fuzz-timeout').
HIDDEN keeps NAME out of `all', so a test target can be defined without
joining every campaign.

FILE is the file the adapter loads to find the target; it defaults to
the file whose top-level form defined the target.  Pass nil for a
target only this Emacs knows, and put a file in
`harness-fuzz-adapter-files' when the adapter needs it."
  (unless (and name (symbolp name) (not (keywordp name)))
    (error "A fuzz target needs a symbol name, not %S" name))
  (unless (functionp check)
    (error "Fuzz target %s needs a :check function" name))
  (unless (and (listp seeds) seeds)
    (error "Fuzz target %s needs a non-empty :seeds list" name))
  (dolist (seed seeds)
    (unless (stringp seed)
      (error "Fuzz target %s has a seed that is not a string: %S" name seed)))
  (puthash name
           (harness-fuzz--make-target
            :name name :description (or description "")
            :check check :seeds seeds
            :timeout (or timeout harness-fuzz-timeout)
            :hidden (and hidden t)
            :file (or file load-file-name (buffer-file-name)))
           harness-fuzz--targets)
  name)

(defun harness-fuzz-remove-target (name)
  "Forget fuzz target NAME; return non-nil when there was one."
  (and (remhash name harness-fuzz--targets) t))

(defun harness-fuzz-target-get (name)
  "Return the `harness-fuzz-target' NAME names, or nil."
  (and name (gethash (intern (format "%s" name)) harness-fuzz--targets)))

(defun harness-fuzz-targets (&optional include-hidden)
  "Return the registered targets, sorted by name.
With INCLUDE-HIDDEN, targets whose HIDDEN is set come too."
  (let (out)
    (maphash (lambda (_name target)
               (when (or include-hidden (not (harness-fuzz-target-hidden target)))
                 (push target out)))
             harness-fuzz--targets)
    (sort out (lambda (a b)
                (string< (symbol-name (harness-fuzz-target-name a))
                         (symbol-name (harness-fuzz-target-name b)))))))

(defun harness-fuzz--resolve-targets (targets)
  "Return TARGETS, a name, a list of names or `all', as target structs."
  (let ((names (cond ((or (null targets) (eq targets 'all) (equal targets "all"))
                      (mapcar #'harness-fuzz-target-name (harness-fuzz-targets)))
                     ((or (symbolp targets) (stringp targets))
                      (list (intern (format "%s" targets))))
                     (t (mapcar (lambda (name) (intern (format "%s" name))) targets)))))
    (unless names
      (error "No fuzz targets are registered"))
    (mapcar (lambda (name)
              (or (harness-fuzz-target-get name)
                  (error "No such fuzz target: %s" name)))
            names)))

;;;; The adapter
;;
;; Everything below this heading runs in the adapter process, a batch
;; Emacs AFL++ starts for one input.  It must not depend on anything
;; the harness process had in memory: the target file is loaded from
;; `harness-fuzz-target-file', and the input is the file AFL++ wrote.

(defun harness-fuzz--printable (text &optional maximum)
  "Return TEXT with control characters escaped, cut to MAXIMUM characters.
A message about an input must stay one readable line, however many
newlines and NULs the input held."
  (let ((out (mapconcat (lambda (char)
                          (if (or (< char 32) (= char 127))
                              (format "\\x%02x" char)
                            (char-to-string char)))
                        (string-to-list (format "%s" text)) "")))
    (if (and maximum (> (length out) maximum))
        (concat (substring out 0 maximum) "...")
      out)))

(defun harness-fuzz--adapter-message (format-string &rest arguments)
  "Print a harness-fuzz line to stderr, for AFL++'s crash trace."
  (princ (concat "harness-fuzz: "
                 (harness-fuzz--printable (apply #'format-message format-string arguments) 500)
                 "\n")
         #'external-debugging-output))

(defun harness-fuzz--read-bytes (file)
  "Return the bytes of FILE as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun harness-fuzz--write-bytes (file bytes)
  "Write BYTES to FILE exactly, as bytes rather than characters."
  (let ((coding-system-for-write 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (if (multibyte-string-p bytes)
                  (encode-coding-string bytes 'utf-8)
                bytes))
      (write-region (point-min) (point-max) file nil 'silent))))

(defun harness-fuzz--adapter-main (target-name file)
  "Run target TARGET-NAME's check on FILE's bytes and exit for AFL++.
Exit 0 when the check held, `harness-fuzz-crash-exit-code' when it
signalled or returned nil, and `harness-fuzz-broken-exit-code' when the
adapter itself could not run.  The message goes to stderr, where
AFL++'s `AFL_CRASH_TRACES' keeps it beside the crash."
  (let ((target (harness-fuzz-target-get target-name)))
    (unless target
      (harness-fuzz--adapter-message
       "no such target: %s (loaded from %s; a target's file is loaded when it was defined at top level)"
       target-name (or load-file-name "?"))
      (kill-emacs harness-fuzz-broken-exit-code))
    (let ((input (condition-case err
                     (harness-fuzz--read-bytes file)
                   (error
                    (harness-fuzz--adapter-message "cannot read %s: %s"
                                                   file (error-message-string err))
                    (kill-emacs harness-fuzz-broken-exit-code)))))
      (condition-case err
          (let ((held (funcall (harness-fuzz-target-check target) input)))
            (if held
                (kill-emacs 0)
              (harness-fuzz--adapter-message
               "%s: the check returned nil: its invariant broke"
               (harness-fuzz-target-name target))
              (kill-emacs harness-fuzz-crash-exit-code)))
        (error
         (harness-fuzz--adapter-message "%s: %s: %s"
                                        (harness-fuzz-target-name target)
                                        (car err) (error-message-string err))
         (kill-emacs harness-fuzz-crash-exit-code))
        (quit
         (harness-fuzz--adapter-message "%s: the check quit"
                                        (harness-fuzz-target-name target))
         (kill-emacs harness-fuzz-crash-exit-code))))))

;;;; Starting the adapter from the campaign
;;
;; The adapter is a plain `emacs --batch' invocation, so a campaign can
;; build it, test it and run it with `make-process'.  The load path is
;; this Emacs's own, so the adapter loads the same harness the campaign
;; does, and the target's file is loaded from the target itself.

(defun harness-fuzz--emacs-program ()
  "Return the Emacs executable the adapter runs."
  (let ((program (or harness-fuzz-emacs-program
                     (expand-file-name invocation-name invocation-directory))))
    (or (and (file-executable-p program) program)
        (executable-find program)
        (error "Cannot find the Emacs to run fuzz targets: %s" program))))

(defun harness-fuzz--load-path-arguments ()
  "Return -L arguments that give the adapter this Emacs's load path."
  (let (directories)
    (dolist (directory (cons harness-fuzz-directory load-path))
      (when (and (stringp directory)
                 (file-name-absolute-p directory)
                 (file-directory-p directory))
        (cl-pushnew (directory-file-name directory) directories :test #'equal)))
    (mapcan (lambda (directory) (list "-L" directory)) (nreverse directories))))

(defun harness-fuzz--target-load-files (target)
  "Return the files the adapter loads after harness-fuzz.el for TARGET."
  (let ((own (harness-fuzz-target-file target))
        (harness (expand-file-name "harness-fuzz.el" harness-fuzz-directory)))
    (cl-remove-duplicates
     (cl-remove-if (lambda (file)
                     (or (null file)
                         (and (file-exists-p file)
                              (equal (file-truename file)
                                     (file-truename harness)))))
                   (cons own harness-fuzz-adapter-files))
     :test #'equal)))

(defun harness-fuzz--adapter-command (target input-placeholder)
  "Return the argv that runs TARGET's check on INPUT-PLACEHOLDER.
INPUT-PLACEHOLDER is the path AFL++ substitutes for `@@'."
  (append
   (list (harness-fuzz--emacs-program) "--batch" "-q")
   (harness-fuzz--load-path-arguments)
   (list "-l" (expand-file-name "harness-fuzz" harness-fuzz-directory))
   (mapcan (lambda (file) (list "-l" (expand-file-name file)))
           (harness-fuzz--target-load-files target))
   (list "--eval"
         (format "(harness-fuzz--adapter-main '%S %S)"
                 (harness-fuzz-target-name target) input-placeholder))))

;;;; Running processes
;;
;; A campaign starts a few kinds of process -- a probe, an afl-fuzz, an
;; afl-tmin -- and waits for several at once.  Each one gets a buffer
;; for its output and a deadline of its own, so one hanging target does
;; not hold a campaign past its budget.

(cl-defstruct (harness-fuzz--job (:constructor harness-fuzz--make-job))
  "One process a campaign runs.
NAME names it in the process list, COMMAND is its argv, BUFFER holds
its output, ENVIRONMENT is prepended to the environment, TIMEOUT is how
many seconds it may run, DATA is the campaign's own bookkeeping,
PROCESS is the process once started, DEADLINE is when it must be
killed, TIMED-OUT says the campaign killed it, and RESULT is its
outcome."
  name command buffer environment timeout data process started deadline timed-out result)

(defun harness-fuzz--start-job (job)
  "Start JOB's process."
  (setf (harness-fuzz--job-started job) (float-time))
  (when-let* ((timeout (harness-fuzz--job-timeout job)))
    (setf (harness-fuzz--job-deadline job) (+ (float-time) timeout)))
  (let ((process-environment (append (harness-fuzz--job-environment job)
                                     process-environment)))
    (setf (harness-fuzz--job-process job)
          (make-process
           :name (format "harness-fuzz-%s" (harness-fuzz--job-name job))
           :command (harness-fuzz--job-command job)
           :buffer (harness-fuzz--job-buffer job)
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t))))

(defun harness-fuzz--job-output (job)
  "Return what JOB's process printed so far."
  (let ((buffer (harness-fuzz--job-buffer job)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer (buffer-string))
      "")))

(defun harness-fuzz--finish-job (job)
  "Wait for JOB's process to end and record its result."
  (let ((process (harness-fuzz--job-process job)))
    (when process
      (while (process-live-p process)
        (accept-process-output process 0.05))
      (let ((status (process-status process))
            (exit (process-exit-status process)))
        (setf (harness-fuzz--job-result job)
              (list :status status
                    :exit exit
                    :signal (and (eq status 'signal) exit)
                    :timed-out (and (harness-fuzz--job-timed-out job) t)
                    :elapsed (and (harness-fuzz--job-started job)
                                  (- (float-time) (harness-fuzz--job-started job)))
                    :output (harness-fuzz--job-output job)))
        (delete-process process)))))

(defun harness-fuzz--kill-job (job)
  "Stop JOB, first politely and then not."
  (let ((process (harness-fuzz--job-process job)))
    (when (process-live-p process)
      (setf (harness-fuzz--job-timed-out job) t)
      (signal-process process 'SIGTERM)
      (let ((limit (+ (float-time) 2)))
        (while (and (process-live-p process) (< (float-time) limit))
          (accept-process-output process 0.05)))
      (when (process-live-p process)
        (signal-process process 'SIGKILL)))))

(defun harness-fuzz--run-jobs (jobs &optional parallel deadline)
  "Run JOBS, at most PARALLEL at a time, and return them with results.
Each job's own TIMEOUT kills it; DEADLINE, when given, kills whatever
is left at that absolute time.  A job that cannot start gets an
`error' result instead of being signalled."
  (let ((pending jobs)
        (active nil))
    (while (or pending active)
      (while (and pending (or (null parallel) (< (length active) parallel)))
        (let ((job (pop pending)))
          (condition-case err
              (progn
                (harness-fuzz--start-job job)
                (push job active))
            (error
             (setf (harness-fuzz--job-result job)
                   (list :status 'error :exit nil :signal nil :timed-out nil
                         :output (error-message-string err)))))))
      (cond
       ((null active) nil)
       ((and deadline (> (float-time) deadline))
        (dolist (job active)
          (harness-fuzz--kill-job job)
          (harness-fuzz--finish-job job))
        (setq active nil
              pending nil))
       (t
        (accept-process-output nil 0.05)
        (dolist (job active)
          (when (and (harness-fuzz--job-deadline job)
                     (> (float-time) (harness-fuzz--job-deadline job)))
            (harness-fuzz--kill-job job)))
        (let (done)
          (dolist (job active)
            (unless (process-live-p (harness-fuzz--job-process job))
              (push job done)))
          (dolist (job done)
            (harness-fuzz--finish-job job)
            (setq active (delq job active)))))))
    jobs))

(defun harness-fuzz--adapter-messages (output)
  "Return the harness-fuzz messages in OUTPUT, oldest first."
  (let (messages)
    (dolist (line (split-string (or output "") "\n"))
      (when (string-match "\\`harness-fuzz: \\(.+\\)\\'" (string-trim-right line "\r"))
        (push (match-string 1 line) messages)))
    (nreverse messages)))

(defun harness-fuzz--job-outcome (job)
  "Return JOB's outcome as a plist: `:status', `:exit', `:signal', `:message'.
`:status' is `pass', `crash', `timeout' or `broken'."
  (let* ((result (harness-fuzz--job-result job))
         (output (plist-get result :output))
         (exit (plist-get result :exit))
         (signal (plist-get result :signal))
         (message (car (harness-fuzz--adapter-messages output))))
    (cond
     ((plist-get result :timed-out)
      (list :status 'timeout :exit exit :signal signal
            :message (format "the adapter did not finish within %ss"
                             (or (harness-fuzz--job-timeout job) "its limit"))))
     (signal
      (list :status 'crash :exit exit :signal signal
            :message (or message (format "the adapter died from signal %d" signal))))
     ((eql exit harness-fuzz-crash-exit-code)
      (list :status 'crash :exit exit :signal nil
            :message (or message "the check broke without a message")))
     ((eql exit 0)
      (list :status 'pass :exit 0 :signal nil :message nil))
     (t
      (list :status 'broken :exit exit :signal nil
            :message (or message (format "the adapter exited %s" exit)))))))

(defun harness-fuzz--tail (text count)
  "Return the last COUNT non-blank lines of TEXT, without ANSI colours."
  (let* ((clean (replace-regexp-in-string "\033\\[[0-9;]*[A-Za-z]" "" (or text "")))
         (lines (cl-remove-if #'string-blank-p (split-string clean "\n")))
         (tail (last lines count)))
    (mapconcat #'string-trim-right tail "\n")))

(defun harness-fuzz--run-adapter (target bytes &optional timeout)
  "Run TARGET's check on BYTES in an adapter process.
Return its `harness-fuzz--job-outcome' plist, or nil when TARGET is nil.
TIMEOUT defaults to the target's own timeout plus a second."
  (when target
    (let ((file (make-temp-file "harness-fuzz-input-" nil ".input")))
      (unwind-protect
          (progn
            (harness-fuzz--write-bytes file bytes)
            (let ((job (harness-fuzz--make-job
                        :name "adapter"
                        :command (harness-fuzz--adapter-command target file)
                        :buffer (generate-new-buffer " *harness-fuzz-adapter*")
                        :timeout (or timeout
                                     (+ (or (harness-fuzz-target-timeout target)
                                            harness-fuzz-timeout)
                                        5.0)))))
              (harness-fuzz--job-outcome
               (car (harness-fuzz--run-jobs (list job) 1 nil)))))
        (ignore-errors (delete-file file))))))

;;;; A campaign

(defun harness-fuzz--program (program variable)
  "Return PROGRAM, found on the path, or signal a helpful error naming VARIABLE."
  (or (and (stringp program) (file-name-absolute-p program)
           (file-executable-p program)
           program)
      (and (stringp program) (executable-find program))
      (error "Cannot find %s.  Install AFL++ (https://github.com/AFLplusplus/AFLplusplus), or set `%s' to the program's path"
             program variable)))

(defun harness-fuzz--seed (seed)
  "Return SEED as AFL++'s 31-bit random seed."
  (let ((seed (if (or (null seed) (not (numberp seed)))
                  (random most-positive-fixnum)
                (round seed))))
    (max 1 (logand (abs seed) #x7fffffff))))

(defun harness-fuzz--afl-environment ()
  "Return the environment afl-fuzz runs with."
  (list (format "AFL_CRASH_EXITCODE=%d" harness-fuzz-crash-exit-code)
        "AFL_CRASH_TRACES=1"
        "AFL_SKIP_CPUFREQ=1"
        "AFL_NO_AFFINITY=1"
        "AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1"
        "AFL_QUIET=1"
        "AFL_NO_UI=1"))

(defun harness-fuzz--tmin-environment ()
  "Return the environment afl-tmin runs with.
afl-tmin has no dumb mode, so it is told to run the adapter through
execve instead of a forkserver (`AFL_NO_FORKSRV')."
  (list (format "AFL_CRASH_EXITCODE=%d" harness-fuzz-crash-exit-code)
        "AFL_NO_FORKSRV=1"
        "AFL_SKIP_CPUFREQ=1"
        "AFL_NO_AFFINITY=1"
        "AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1"
        "AFL_QUIET=1"))

(defun harness-fuzz--afl-command (afl target seeds output seed executions seconds)
  "Return the afl-fuzz argv for TARGET.
SEEDS and OUTPUT are its corpus and output directories, SEED AFL++'s
random seed, and EXECUTIONS and SECONDS its two limits."
  (append
   (list afl
         "-i" seeds
         "-o" output
         "-E" (number-to-string executions)
         "-V" (number-to-string seconds)
         "-t" (number-to-string
               (max 100 (round (* 1000 (or (harness-fuzz-target-timeout target)
                                           harness-fuzz-timeout)))))
         "-m" "none"
         "-s" (number-to-string seed))
   (pcase harness-fuzz-afl-mode
     ('dumb '("-n"))
     ('instrumented nil)
     ('qemu '("-Q"))
     (_ (error "Unknown `harness-fuzz-afl-mode': %S" harness-fuzz-afl-mode)))
   harness-fuzz-afl-arguments
   (list "--")
   (harness-fuzz--adapter-command target "@@")))

(defun harness-fuzz--probe-targets (targets work)
  "Write TARGETS's seeds under WORK and check each one through the adapter.
Return (SEEDS . CRASHES): SEEDS is an alist of target name to the files
of the seeds that passed, and CRASHES are the seeds that crashed,
already reported as findings.  A seed that hangs or an adapter that
cannot run signals an error, because either makes a campaign's silence
meaningless.  A crashing seed is removed from the corpus AFL++ sees."
  (let (jobs)
    (dolist (target targets)
      (let* ((name (harness-fuzz-target-name target))
             (directory (expand-file-name (format "seeds/%s" name) work))
             (position 0))
        (make-directory directory t)
        (dolist (seed (harness-fuzz-target-seeds target))
          (let ((file (expand-file-name (format "%02d" position) directory)))
            (harness-fuzz--write-bytes file seed)
            (push (harness-fuzz--make-job
                   :name (format "probe-%s-%02d" name position)
                   :command (harness-fuzz--adapter-command target file)
                   :buffer (generate-new-buffer " *harness-fuzz-probe*")
                   :timeout (+ harness-fuzz-probe-seconds 5.0)
                   :data (list :target target :seed seed :file file))
                  jobs))
          (cl-incf position))))
    (let ((good (make-hash-table :test 'eq))
          (crashes nil))
      (dolist (job (harness-fuzz--run-jobs (nreverse jobs)
                                           (max 2 harness-fuzz-parallel-targets)
                                           nil))
        (let* ((data (harness-fuzz--job-data job))
               (target (plist-get data :target))
               (name (harness-fuzz-target-name target))
               (outcome (harness-fuzz--job-outcome job)))
          (pcase (plist-get outcome :status)
            ('pass
             (puthash name (cons (plist-get data :file) (gethash name good)) good))
            ('crash
             (delete-file (plist-get data :file))
             (push (list :target name
                         :kind 'crash
                         :signal (plist-get outcome :signal)
                         :exit (plist-get outcome :exit)
                         :message (plist-get outcome :message)
                         :input (plist-get data :seed)
                         :file "seed"
                         :shrunk nil)
                   crashes))
            (_
             (error "Fuzz target %s cannot run: %s"
                    name (plist-get outcome :message))))))
      (cons (cl-loop for name being the hash-keys of good using (hash-value files)
                     collect (cons name (nreverse files)))
            (nreverse crashes)))))

(defun harness-fuzz--plot-stats (output-directory)
  "Return the statistics AFL++ wrote to OUTPUT-DIRECTORY's plot data."
  (let ((file (expand-file-name "plot_data" output-directory)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-max))
        (forward-line -1)
        (let ((fields (mapcar #'string-trim
                              (split-string
                               (buffer-substring-no-properties
                                (line-beginning-position) (line-end-position))
                               ","))))
          (when (>= (length fields) 15)
            (list :executions (string-to-number (nth 11 fields))
                  :execs-per-sec (string-to-number (nth 10 fields))
                  :saved-crashes (string-to-number (nth 7 fields))
                  :saved-hangs (string-to-number (nth 8 fields)))))))))

(defun harness-fuzz--file-signal (file)
  "Return the signal AFL++ recorded in the name of crash FILE, or 0."
  (if (string-match ",sig:\\([0-9]+\\)" file)
      (string-to-number (match-string 1 file))
    0))

(defun harness-fuzz--findings (target output-directory)
  "Return the crashes and hangs AFL++ saved for TARGET in OUTPUT-DIRECTORY."
  (let (findings)
    (dolist (kind '(("crashes" . crash) ("hangs" . hang)))
      (let ((directory (expand-file-name (car kind) output-directory)))
        (when (file-directory-p directory)
          (dolist (file (sort (directory-files directory t "\\`id:") #'string<))
            (unless (string-suffix-p ".txt" file)
              (let* ((signal (harness-fuzz--file-signal file))
                     (trace (let ((text (concat file ".txt")))
                              (when (file-exists-p text)
                                (decode-coding-string
                                 (harness-fuzz--read-bytes text) 'utf-8))))
                     (message (or (car (harness-fuzz--adapter-messages trace))
                                  (if (eq (cdr kind) 'hang)
                                      "AFL++ killed the input at the target's timeout"
                                    "AFL++ recorded a crash without a message"))))
                (push (list :target (harness-fuzz-target-name target)
                            :kind (cdr kind)
                            :signal (and (> signal 0) signal)
                            :exit (and (eq (cdr kind) 'crash)
                                       (zerop signal)
                                       harness-fuzz-crash-exit-code)
                            :message message
                            :input (harness-fuzz--read-bytes file)
                            :file (file-name-nondirectory file)
                            :shrunk nil)
                      findings)))))))
    (nreverse findings)))

(defun harness-fuzz--campaign-result (job)
  "Return what one afl-fuzz JOB found."
  (let* ((data (harness-fuzz--job-data job))
         (target (plist-get data :target))
         (name (harness-fuzz-target-name target))
         (output-directory (plist-get data :out))
         (result (harness-fuzz--job-result job))
         (output (plist-get result :output)))
    (unless (eql 0 (plist-get result :exit))
      (error "AFL++ failed for fuzz target %s%s:\n%s"
             name
             (if (plist-get result :timed-out) " (the campaign stopped it)" "")
             (harness-fuzz--tail output 8)))
    (let ((stats (harness-fuzz--plot-stats output-directory)))
      (list :target name
            :stats (plist-put stats :execs-per-sec
                              (/ (or (plist-get stats :executions) 0)
                                 (max 0.1 (or (plist-get result :elapsed) 1.0))))
            :findings (harness-fuzz--findings target output-directory)
            :time-limit (and (string-match-p "Time limit was reached" output) t)))))

(defun harness-fuzz--run-campaigns (targets afl seed executions seconds work)
  "Run one afl-fuzz per TARGETS, in batches, and return their results.
WORK is the campaign's directory, where the probed seeds already are."
  (let ((remaining targets)
        (results nil)
        (size (max 1 harness-fuzz-parallel-targets)))
    (while remaining
      (let* ((chunk (cl-subseq remaining 0 (min size (length remaining))))
             (jobs nil))
        (setq remaining (nthcdr size remaining))
        (dolist (target chunk)
          (let* ((name (harness-fuzz-target-name target))
                 (output (expand-file-name (format "out/%s" name) work)))
            (make-directory output t)
            (push (harness-fuzz--make-job
                   :name (format "afl-%s" name)
                   :command (harness-fuzz--afl-command
                             afl target (expand-file-name (format "seeds/%s" name) work)
                             output seed executions seconds)
                   :environment (harness-fuzz--afl-environment)
                   :buffer (generate-new-buffer (format " *harness-fuzz-afl-%s*" name))
                   :timeout (+ seconds 60.0)
                   :data (list :target target :out output))
                  jobs)))
        (dolist (job (harness-fuzz--run-jobs (nreverse jobs) nil nil))
          (push (harness-fuzz--campaign-result job) results))))
    (nreverse results)))

(defun harness-fuzz--shrink-candidates (findings)
  "Return the findings worth minimising, shortest input first.
One per target comes first, then the rest, so a target with a dozen
crashes and a target with one both get their turn, and the shortest
inputs (which afl-tmin finishes fastest) run first."
  (let ((sorted (sort (copy-sequence findings)
                      (lambda (a b)
                        (< (length (plist-get a :input))
                           (length (plist-get b :input))))))
        (first nil)
        (rest nil)
        (seen nil))
    (dolist (finding sorted)
      (if (memq (plist-get finding :target) seen)
          (push finding rest)
        (push (plist-get finding :target) seen)
        (push finding first)))
    (let ((candidates (append (nreverse first) (nreverse rest))))
      (cl-subseq candidates 0 (min harness-fuzz-max-shrink (length candidates))))))

(defun harness-fuzz--shrink-crashes (findings work)
  "Minimise FINDINGS with afl-tmin, in parallel, under WORK.
Return FINDINGS with the minimised ones replaced.  A tmin that fails,
takes too long or whose output no longer breaks the target leaves its
crash as AFL++ found it."
  (let ((tmin (ignore-errors (harness-fuzz--program harness-fuzz-tmin-program
                                                     'harness-fuzz-tmin-program)))
        (candidates (harness-fuzz--shrink-candidates findings)))
    (if (or (null tmin) (null candidates))
        findings
      (let ((jobs nil)
            (position 0))
        (make-directory (expand-file-name "shrink" work) t)
        (dolist (finding candidates)
          (let* ((input (expand-file-name (format "shrink/%02d.input" position) work))
                 (output (expand-file-name (format "shrink/%02d.output" position) work))
                 (target (harness-fuzz-target-get (plist-get finding :target)))
                 (timeout (max 100 (round (* 1000 (or (harness-fuzz-target-timeout target)
                                                      harness-fuzz-timeout))))))
            (harness-fuzz--write-bytes input (plist-get finding :input))
            (push (harness-fuzz--make-job
                   :name (format "tmin-%02d" position)
                   :command (append (list tmin "-i" input "-o" output
                                          "-t" (number-to-string timeout)
                                          "-m" "none")
                                    (and (eq (plist-get finding :kind) 'hang) '("-H"))
                                    (list "--")
                                    (harness-fuzz--adapter-command target "@@"))
                   :environment (harness-fuzz--tmin-environment)
                   :buffer (generate-new-buffer " *harness-fuzz-tmin*")
                   :timeout harness-fuzz-shrink-seconds
                   :data (list :finding finding :output output))
                  jobs))
          (cl-incf position))
        (dolist (job (harness-fuzz--run-jobs (nreverse jobs)
                                             (max 2 harness-fuzz-parallel-targets)
                                             nil))
          (let* ((data (harness-fuzz--job-data job))
                 (finding (plist-get data :finding))
                 (output (plist-get data :output))
                 (result (harness-fuzz--job-result job)))
            (when (and (eql 0 (plist-get result :exit))
                       (file-exists-p output))
              (let* ((bytes (harness-fuzz--read-bytes output))
                     (target (harness-fuzz-target-get (plist-get finding :target)))
                     (outcome (and (< (length bytes) (length (plist-get finding :input)))
                                   (harness-fuzz--run-adapter target bytes))))
                (when (or (eq (plist-get outcome :status) 'crash)
                          (and (eq (plist-get finding :kind) 'hang)
                               (eq (plist-get outcome :status) 'timeout)))
                  (setf (plist-get finding :input) bytes
                        (plist-get finding :shrunk) t
                        (plist-get finding :message) (plist-get outcome :message)
                        (plist-get finding :signal) (plist-get outcome :signal)
                        (plist-get finding :exit) (plist-get outcome :exit)))))))
        findings))))

(defun harness-fuzz--by-target (targets runs findings skipped)
  "Return the per-target summary of a campaign."
  (let (cells)
    (dolist (target targets)
      (let* ((name (harness-fuzz-target-name target))
             (run (cl-find-if (lambda (result) (eq (plist-get result :target) name))
                              runs))
             (stats (plist-get run :stats)))
        (push (cons name
                    (append (list :executions (or (plist-get stats :executions) 0)
                                  :execs-per-sec (or (plist-get stats :execs-per-sec) 0)
                                  :crashes (cl-loop for finding in findings
                                                    count (and (eq (plist-get finding :target) name)
                                                               (eq (plist-get finding :kind) 'crash)))
                                  :hangs (cl-loop for finding in findings
                                                  count (and (eq (plist-get finding :target) name)
                                                             (eq (plist-get finding :kind) 'hang))))
                            (when-let* ((reason (cdr (assq name skipped))))
                              (list :skipped reason))))
              cells)))
    (nreverse cells)))

(cl-defun harness-fuzz-run (&key targets executions seconds seed shrink name)
  "Fuzz TARGETS with AFL++, for EXECUTIONS inputs each, within SECONDS.
TARGETS is a target name, a list of names, or `all' (the default).
EXECUTIONS defaults to 200 and SECONDS to 5; both are capped by
`harness-fuzz-max-executions' and `harness-fuzz-max-seconds'.  SEED is
AFL++'s random seed.  A crash is minimised with afl-tmin unless SHRINK
is nil.  NAME names the run in the report.

Each target gets its own afl-fuzz, its own corpus and its own output
directory under one temporary directory, and they run in parallel up to
`harness-fuzz-parallel-targets'.  The run returns a report plist; it
signals an error when AFL++ or a target's adapter cannot run at all,
because a campaign that cannot start must not look like one that found
nothing."
  (let* ((targets (harness-fuzz--resolve-targets targets))
         (afl (harness-fuzz--program harness-fuzz-afl-program
                                     'harness-fuzz-afl-program))
         (executions (max 1 (min harness-fuzz-max-executions
                                 (round (or executions 200)))))
         (seconds (max 1 (min harness-fuzz-max-seconds
                              (round (or seconds 5)))))
         (seed (harness-fuzz--seed seed))
         (work (make-temp-file "harness-fuzz-" t))
         (started (float-time)))
    (unwind-protect
        (let* ((probe (harness-fuzz--probe-targets targets work))
               (seeds (car probe))
               (probe-crashes (cdr probe))
               (skipped nil)
               (runs nil))
          (dolist (target targets)
            (let ((name (harness-fuzz-target-name target)))
              (unless (assq name seeds)
                (push (cons name "every seed crashed") skipped))))
          (when seeds
            (setq runs (harness-fuzz--run-campaigns
                        (cl-remove-if-not
                         (lambda (target)
                           (assq (harness-fuzz-target-name target) seeds))
                         targets)
                        afl seed executions seconds work)))
          (let* ((findings (append probe-crashes
                                   (cl-loop for run in runs
                                            append (plist-get run :findings))))
                 (crashes (if shrink
                              (harness-fuzz--shrink-crashes findings work)
                            findings))
                 (report (list :run (or name "fuzz")
                               :seed seed
                               :afl afl
                               :mode harness-fuzz-afl-mode
                               :targets (mapcar #'harness-fuzz-target-name targets)
                               :executions (cl-loop for run in runs
                                                    sum (or (plist-get (plist-get run :stats)
                                                                        :executions)
                                                            0))
                               :crashes crashes
                               :by-target (harness-fuzz--by-target targets runs crashes skipped)
                               :skipped (nreverse skipped)
                               :stopped (cond ((null runs) 'probes)
                                              ((cl-some (lambda (run)
                                                          (plist-get run :time-limit))
                                                        runs)
                                               'seconds)
                                              (t 'executions))
                               :elapsed (- (float-time) started)
                               :work-directory (and harness-fuzz-keep-work-directory work))))
            (setq harness-fuzz--last-report report)
            report))
      (unless harness-fuzz-keep-work-directory
        (ignore-errors (delete-directory work t))))))

(defun harness-fuzz-report ()
  "Return the report of the last campaign, or nil."
  harness-fuzz--last-report)

(defun harness-fuzz--print-input (input)
  "Return INPUT printed for a report, bounded by `harness-fuzz-max-input-chars'.
INPUT is the input's bytes.  The text is printable ASCII -- a byte
outside it is a three-digit octal escape -- so it survives a JSON tool
result, stays on one line, and `harness-fuzz--read-input' gives the
same bytes back.  Return (TEXT . TRUNCATED-P)."
  (let* ((bytes (if (multibyte-string-p input)
                    (encode-coding-string input 'utf-8)
                  input))
         (text (concat "\""
                       (mapconcat (lambda (byte)
                                    (cond ((= byte ?\\) "\\\\")
                                          ((= byte ?\") "\\\"")
                                          ((and (>= byte 32) (< byte 127))
                                           (char-to-string byte))
                                          (t (format "\\%03o" byte))))
                                  (string-to-list bytes) "")
                       "\"")))
    (if (> (length text) harness-fuzz-max-input-chars)
        (cons (harness-truncate-end text harness-fuzz-max-input-chars) t)
      (cons text nil))))

(defun harness-fuzz--mode-description (mode)
  "Return MODE as a phrase for a report."
  (pcase mode
    ('dumb "AFL++ dumb mode")
    ('instrumented "AFL++ with an instrumented Emacs")
    ('qemu "AFL++ QEMU mode")
    (_ (format "AFL++ (%s)" mode))))

(defun harness-fuzz--describe-crash (crash position)
  "Return CRASH, the POSITION-th of a report, as a few lines for a person."
  (let ((printed (harness-fuzz--print-input (plist-get crash :input))))
    (format "  %d. %s: %s%s%s\n     %s\n     input: %s%s\n     replay: fuzz_replay target: %S crash: %d"
            position
            (plist-get crash :target)
            (if (eq (plist-get crash :kind) 'hang) "hang" "crash")
            (cond ((plist-get crash :signal)
                   (format " (signal %d)" (plist-get crash :signal)))
                  ((eq (plist-get crash :kind) 'hang) " (timed out)")
                  ((plist-get crash :exit)
                   (format " (exit %s)" (plist-get crash :exit)))
                  (t ""))
            (if (plist-get crash :shrunk) ", minimised" "")
            (plist-get crash :message)
            (car printed) (if (cdr printed) " [truncated]" "")
            (plist-get crash :target) position)))

(defun harness-fuzz-describe-report (&optional report maximum-crashes)
  "Return REPORT, or the last campaign's, as text for a tool result.
MAXIMUM-CRASHES defaults to 20; more are counted, not printed."
  (let ((report (or report (harness-fuzz-report))))
    (if (null report)
        "No fuzz campaign has run in this Emacs yet."
      (let* ((crashes (plist-get report :crashes))
             (maximum (or maximum-crashes 20))
             (shown (cl-subseq crashes 0 (min maximum (length crashes))))
             (executions (or (plist-get report :executions) 0)))
        (concat
         (format "Fuzz run %s with %s (seed %d): %d input%s across %d target%s in %.1fs [stopped: %s]\n"
                 (or (plist-get report :run) "fuzz")
                 (harness-fuzz--mode-description (plist-get report :mode))
                 (plist-get report :seed)
                 executions (if (= 1 executions) "" "s")
                 (length (plist-get report :targets))
                 (if (= 1 (length (plist-get report :targets))) "" "s")
                 (float (or (plist-get report :elapsed) 0))
                 (plist-get report :stopped))
         (mapconcat
          (lambda (cell)
            (let ((stats (cdr cell)))
              (if-let* ((reason (plist-get stats :skipped)))
                  (format "  %s: skipped (%s)" (car cell) reason)
                (format "  %s: %d input%s at %.1f/s, %d crash%s%s"
                        (car cell)
                        (plist-get stats :executions)
                        (if (= 1 (plist-get stats :executions)) "" "s")
                        (float (plist-get stats :execs-per-sec))
                        (plist-get stats :crashes)
                        (if (= 1 (plist-get stats :crashes)) "" "es")
                        (let ((hangs (plist-get stats :hangs)))
                          (if (> hangs 0)
                              (format ", %d hang%s" hangs (if (= 1 hangs) "" "s"))
                            ""))))))
          (plist-get report :by-target) "\n")
         "\n"
         (if crashes
             (mapconcat (lambda (crash) (harness-fuzz--describe-crash crash (1+ (cl-position crash crashes))))
                        shown "\n")
           (format "No crashes: AFL++ ran %d input%s through %d target%s and the harness handled every one."
                   executions (if (= 1 executions) "" "s")
                   (length (plist-get report :targets))
                   (if (= 1 (length (plist-get report :targets))) "" "s")))
         (if (> (length crashes) maximum)
             (format "\n  ... and %d more crash%s" (- (length crashes) maximum)
                     (if (= (- (length crashes) maximum) 1) "" "es"))
           "")
         (if crashes
             "\nA crash is a signal, a broken invariant or a hang at a boundary that must not break; afl-tmin minimised the ones marked so."
           ""))))))

;;;; Replay

(defun harness-fuzz--read-input (text)
  "Read TEXT, printed Lisp, as an input string.
Emacs's reader evaluates nothing while reading.  A unibyte string comes
back as the bytes it printed; a multibyte one is encoded as UTF-8, as a
process would hand the harness."
  (let ((value (condition-case err
                   (car (read-from-string text))
                 (error
                  (error "The input is not readable Lisp: %s"
                         (error-message-string err))))))
    (unless (stringp value)
      (error "A fuzz input is a string, not %S" value))
    (if (multibyte-string-p value)
        (encode-coding-string value 'utf-8)
      value)))

(cl-defun harness-fuzz-replay (target &key input crash)
  "Replay one fuzz input for TARGET.
The input is INPUT, printed Lisp as a report prints it, or CRASH, the
1-based number of a crash in the last report.  Run the check again in
an adapter process, with the target's own timeout, and return a plist:
`:target', `:input', `:kind' (`pass', `crash' or `broken'), `:crash',
`:message' and `:signal'."
  (let* ((target (or (harness-fuzz-target-get target)
                     (error "No such fuzz target: %s" target)))
         (bytes (cond
                 (input (harness-fuzz--read-input input))
                 (crash
                  (let* ((report (harness-fuzz-report))
                         (entry (and report (nth (1- (max 1 crash))
                                                 (plist-get report :crashes)))))
                    (unless entry
                      (error "The last fuzz report has no crash %d" crash))
                    (plist-get entry :input)))
                 (t (error "Replay needs :input, or :crash from the last report"))))
         (outcome (harness-fuzz--run-adapter target bytes)))
    (list :target (harness-fuzz-target-name target)
          :input bytes
          :kind (plist-get outcome :status)
          :crash (eq (plist-get outcome :status) 'crash)
          :message (plist-get outcome :message)
          :signal (plist-get outcome :signal))))

(defun harness-fuzz-describe-replay (result)
  "Return REPLAY RESULT, a plist from `harness-fuzz-replay', as text."
  (let ((printed (harness-fuzz--print-input (plist-get result :input))))
    (pcase (plist-get result :kind)
      ('crash
       (format "Replayed %s: it still crashes%s: %s\ninput: %s%s"
               (plist-get result :target)
               (if (plist-get result :signal)
                   (format " (signal %d)" (plist-get result :signal))
                 "")
               (or (plist-get result :message) "no message")
               (car printed) (if (cdr printed) " [truncated]" "")))
      ('timeout
       (format "Replayed %s: it hangs: %s\ninput: %s"
               (plist-get result :target)
               (or (plist-get result :message) "no message")
               (car printed)))
      ('broken
       (format "Replayed %s: the adapter could not run: %s"
               (plist-get result :target)
               (or (plist-get result :message) "no message")))
      (_
       (format "Replayed %s: it no longer crashes.\ninput: %s"
               (plist-get result :target) (car printed))))))

;;;; Built-in targets
;;
;; A check gets bytes and decides for itself what they mean.  A parse
;; error on something that is not a message is the answer, not a crash:
;; the fuzzer's input is arbitrary, and the harness's job is to survive
;; it.  A check signal is a real break.  A target that needed a session,
;; a file or a process would belong in a test of its own, not in an
;; unattended campaign.

(defun harness-fuzz--parse-json (text)
  "Return (nil . VALUE) for TEXT parsed as JSON, or nil when it is not JSON."
  (when (and (stringp text) (not (string-blank-p text)))
    (condition-case nil
        (cons nil (harness-json-parse text))
      (error nil))))

(defun harness-fuzz--read-lisp (text)
  "Return (nil . VALUE) for TEXT read as Lisp, or nil when it is unreadable."
  (when (and (stringp text) (not (string-blank-p text)))
    (condition-case nil
        (cons nil (car (read-from-string text)))
      (error nil))))

(defun harness-fuzz--mcp-server ()
  "Return the tiny MCP server the mcp-serve target answers as."
  (harness-mcp-make-server
   :name "fuzz" :title "Fuzz server" :version "1"
   :instructions "A server for fuzzing the protocol, not for use."
   :tools (list
           (harness-mcp-make-tool
            :name "echo" :description "Repeat the arguments."
            :handler (lambda (arguments _context) (format "%S" arguments)))
           (harness-mcp-make-tool
            :name "fail" :description "Signal."
            :handler (lambda (_arguments _context) (error "The fuzz tool failed")))
           (harness-mcp-make-tool
            :name "later" :description "Answer from a promise."
            :handler (lambda (_arguments _context) (harness-resolved "later")))
           (harness-mcp-make-tool
            :name "strange" :description "Return a tool result of an odd shape."
            :handler (lambda (arguments _context)
                       (pcase (mod (length (format "%S" arguments)) 4)
                         (0 (cons :content "a dotted result"))
                         (1 (list :content 42 :is-error :false))
                         (2 (vector :content "a vector"))
                         (_ (list :content "text" :unexpected 'extra))))))))

(defun harness-fuzz--check-mcp-serve (bytes)
  "Check that the MCP server survives BYTES and answers in JSON."
  (when-let* ((message (condition-case nil
                           (harness-mcp-decode-line bytes)
                         (error nil))))
    (let ((response (harness-mcp-serve (harness-fuzz--mcp-server) message)))
      (when (harness-promise-p response)
        (setq response (harness-await response 2)))
      (when response
        (unless (and (listp response) (keywordp (car response)))
          (error "MCP server answered something that is no message: %S" response))
        (harness-json-encode response))))
  t)

(defun harness-fuzz--check-mcp-result (bytes)
  "Check that BYTES as a malformed MCP result becomes a well-formed tool result."
  (when-let* ((parsed (harness-fuzz--parse-json bytes)))
    (let ((tool-result (harness-mcp-call-result-to-tool-result (cdr parsed))))
      (unless (and (listp tool-result) (proper-list-p tool-result))
        (error "MCP result conversion gave no plist: %S" tool-result))
      (unless (stringp (plist-get tool-result :content))
        (error "MCP result conversion gave non-text content: %S"
               (plist-get tool-result :content)))
      (unless (memq (plist-get tool-result :is-error) '(nil t))
        (error "MCP result conversion gave a non-boolean is-error: %S"
               (plist-get tool-result :is-error)))
      (let ((call-result (harness-mcp-tool-result-to-call-result tool-result)))
        (unless (and (listp call-result) (plist-member call-result :content))
          (error "Converting the tool result back gave no CallToolResult: %S"
                 call-result)))))
  t)

(defun harness-fuzz--check-mcp-line (bytes)
  "Check that BYTES as a JSON-RPC message survive the MCP stdio framing."
  (when-let* ((message (condition-case nil
                           (harness-mcp-decode-line bytes)
                         (error nil))))
    (let* ((line (harness-mcp-encode-line message))
           (decoded (harness-mcp-decode-line line)))
      (unless (equal decoded message)
        (error "MCP line round-trip changed %S to %S" message decoded))
      (unless (string-suffix-p "\n" line)
        (error "MCP line does not end in a newline: %S" line))))
  t)

(defconst harness-fuzz--chunk-sizes [1 3 7 2 11 5]
  "Chunk sizes the acp-lines target splits its input into.")

(defun harness-fuzz--split-in-chunks (text)
  "Split TEXT into chunks of a fixed cycle of sizes and frame them as ACP does."
  (let ((pending nil) (lines nil) (position 0) (length (length text)) (step 0))
    (while (< position length)
      (let* ((size (aref harness-fuzz--chunk-sizes
                         (mod step (length harness-fuzz--chunk-sizes))))
             (end (min length (+ position size)))
             (framed (harness-acp--split-lines pending (substring text position end))))
        (setq lines (append lines (car framed))
              pending (cdr framed)
              position end
              step (1+ step))))
    (cons lines pending)))

(defun harness-fuzz--pending-text (pending)
  "Return PENDING, what ACP line framing left of a line, as one string.
PENDING is a string, a list of strings newest first, or nil."
  (cond ((null pending) "")
        ((stringp pending) pending)
        (t (apply #'concat (nreverse pending)))))

(defun harness-fuzz--check-acp-lines (bytes)
  "Check that ACP line framing does not depend on how BYTES are chunked."
  (let ((whole (harness-acp--split-lines nil bytes))
        (pieces (harness-fuzz--split-in-chunks bytes)))
    (unless (equal (car whole) (car pieces))
      (error "ACP framing changed with chunking: %S vs %S"
             (car whole) (car pieces)))
    (unless (equal (harness-fuzz--pending-text (cdr whole))
                   (harness-fuzz--pending-text (cdr pieces)))
      (error "ACP incomplete line changed with chunking: %S vs %S"
             (harness-fuzz--pending-text (cdr whole))
             (harness-fuzz--pending-text (cdr pieces))))
    (dolist (line (car whole))
      (when (string-search "\n" line)
        (error "ACP framing returned a line holding a newline: %S" line))))
  t)

(defconst harness-fuzz--acp-signatures
  (list (lambda (session-id &optional cwd limit &rest rest)
          (list session-id cwd limit rest))
        (lambda (&rest rest) rest)
        (lambda (a b) (list a b))
        (lambda (a &optional b c) (list a b c)))
  "Method argument lists the ACP parameter mapper is fuzzed against.")

(defun harness-fuzz--check-acp-params (bytes)
  "Check that ACP parameter mapping of BYTES only refuses with invalid-params."
  (when-let* ((parsed (harness-fuzz--parse-json bytes)))
    (let* ((params (cdr parsed))
           (signature (nth (mod (length bytes) (length harness-fuzz--acp-signatures))
                           harness-fuzz--acp-signatures)))
      (condition-case err
          (harness-acp--map-params signature params)
        (harness-acp-invalid-params nil)
        (error (error "ACP parameter mapping signalled %S instead of refusing: %s"
                      (car err) (error-message-string err))))))
  t)

(defun harness-fuzz--check-acp-normalise (bytes)
  "Check that ACP wire normalisation of BYTES returns, whatever they hold."
  (when-let* ((parsed (harness-fuzz--read-lisp bytes)))
    (harness-acp--normalise (cdr parsed))
    (harness-acp--intern-enums (cdr parsed)))
  t)

(defun harness-fuzz--check-links (bytes)
  "Check that the harness link readers survive BYTES."
  (let ((link (harness-links-parse bytes)))
    (when link
      (unless (plist-get link :kind)
        (error "A parsed link has no kind: %S" link))))
  (let ((handle (harness-links-parse-handle bytes)))
    (when handle
      (unless (or (plist-get handle :nth) (plist-get handle :first))
        (error "A parsed handle names no position: %S" handle))))
  (harness-links-scan bytes)
  t)

(defun harness-fuzz--check-search-query (bytes)
  "Check that the session search query parser survives BYTES."
  (dolist (item (harness-session-search--parse-query bytes))
    (unless (or (eq item 'or)
                (and (consp item) (stringp (plist-get item :text))))
      (error "A parsed search term is malformed: %S" item)))
  t)

(defun harness-fuzz--check-http-headers (bytes)
  "Check that the HTTP header and URL readers survive BYTES."
  (let ((parsed (harness-http--parse-headers bytes)))
    (unless (consp parsed)
      (error "HTTP header parsing gave no status and headers: %S" parsed))
    (unless (or (null (car parsed)) (integerp (car parsed)))
      (error "HTTP header parsing gave a non-integer status: %S" (car parsed)))
    (dolist (header (cdr parsed))
      (unless (and (consp header) (stringp (car header)) (stringp (cdr header)))
        (error "HTTP header parsing gave a malformed header: %S" header))))
  (harness-http--disposition-filename bytes)
  (harness-http-url-file-name bytes)
  (harness-http-clean-url bytes)
  t)

(defun harness-fuzz--check-provider-events (bytes)
  "Check that the provider event guard contains BYTES as an event sequence.
The consumer fails on its first event, to exercise the guard's
containment, and records the rest; the guard must never deliver an
event once `done' has gone through."
  (when-let* ((parsed (harness-fuzz--read-lisp bytes)))
    (let ((events (cdr parsed)))
      (when (and (listp events)
                 (proper-list-p events)
                 (cl-every (lambda (event)
                             (and (consp event) (keywordp (car event))))
                           events))
        (let ((seen nil) (failed nil))
          (let ((guard (harness-provider--guard-events
                        (lambda (event)
                          (push event seen)
                          (unless failed
                            (setq failed t)
                            (error "The fuzz consumer refuses its first event"))))))
            (dolist (event events)
              (funcall guard event)))
          (setq seen (nreverse seen))
          (let ((done (cl-position-if (lambda (event)
                                        (eq (plist-get event :type) 'done))
                                      seen)))
            (when (and done (cdr (nthcdr done seen)))
              (error "The provider guard delivered events after done")))))))
  t)

;;;; The built-in registry
;;
;; The seeds are samples of what the boundary really reads, one per
;; shape worth mutating; AFL++ does the rest.  They are deliberately
;; small: every byte AFL++ flips should reach the parser, not sail
;; through a page of text the parser skips.

(harness-fuzz-define-target
 'mcp-serve
 :description "JSON-RPC messages at an MCP server with hostile tools."
 :seeds (list "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
              "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
              "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"hi\"}}}"
              "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
 :check #'harness-fuzz--check-mcp-serve)

(harness-fuzz-define-target
 'mcp-result
 :description "CallToolResults a hostile or broken MCP server could send."
 :seeds (list "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}"
              "{\"content\":\"plain text\",\"isError\":false}"
              "{\"content\":[{\"type\":\"image\",\"data\":\"AAAA\"}],\"_meta\":{\"harness/result\":{\"id\":7}}}"
              "{\"content\":42,\"structuredContent\":{\"a\":1}}")
 :check #'harness-fuzz--check-mcp-result)

(harness-fuzz-define-target
 'mcp-line
 :description "The MCP stdio line framing round-trip."
 :seeds (list "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
              "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}"
              "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32603,\"message\":\"x\"}}")
 :check #'harness-fuzz--check-mcp-line)

(harness-fuzz-define-target
 'acp-lines
 :description "ACP line framing under chunk boundaries it did not choose."
 :seeds (list "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\"}\n"
              "{\"jsonrpc\":\"2.0\",\"id\":1}\r\n{\"jsonrpc\":\"2.0\"}\n"
              "{\"jsonrpc\":\"2.0\"}")
 :check #'harness-fuzz--check-acp-lines)

(harness-fuzz-define-target
 'acp-params
 :description "ACP parameters mapped onto method argument lists."
 :seeds (list "{\"sessionId\":\"s\",\"cwd\":\"/tmp\",\"limit\":10}"
              "{}" "null" "{\"args\":[1,\"two\"]}" "\"x\"")
 :check #'harness-fuzz--check-acp-params)

(harness-fuzz-define-target
 'acp-normalise
 :description "ACP wire normalisation of Lisp values code, not JSON, can hand it."
 :seeds (list "(:a 1)" "(:a 1 . 2)" "[1 2 :b]" "(\"a\" . \"b\")"
              "#(\"x\" 0 1 (face bold))")
 :check #'harness-fuzz--check-acp-normalise)

(harness-fuzz-define-target
 'links
 :description "Harness links, handles and link scanning in arbitrary text."
 :seeds (list "harness:session/abc" "harness:call/last"
              "see harness:task/t/thread/th"
              "harness:session/abc#2 and harness:bash#3"
              "[harness:session/x]")
 :check #'harness-fuzz--check-links)

(harness-fuzz-define-target
 'search-query
 :description "The session search query parser."
 :seeds (list "foo bar" "foo OR bar" "\"exact phrase\"" "foo -bar baz*")
 :check #'harness-fuzz--check-search-query)

(harness-fuzz-define-target
 'http-headers
 :description "HTTP response headers, dispositions and URL file names."
 :seeds (list "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\n"
              "HTTP/1.1 302 Found\r\nLocation: /next\r\n\r\n"
              "Content-Disposition: attachment; filename=\"a b.txt\"\r\n\r\n"
              "HTTP/1.1 200 OK\nContent-Disposition: attachment; filename*=UTF-8''a%20b.txt\n\n")
 :check #'harness-fuzz--check-http-headers)

(harness-fuzz-define-target
 'provider-events
 :description "Provider events of every shape through the guard that ends a turn once."
 :seeds (list "((:type text :delta \"hi\"))"
              "((:type done :stop-reason end-turn))"
              "((:type text :delta \"a\") (:type done) (:type text :delta \"b\"))"
              "((:type tool-call :id 1 :name \"bash\" :input (:command \"ls\")))"
              "((:type usage :input 10 :output 20 :cost 0.1))")
 :check #'harness-fuzz--check-provider-events)

(harness-define-module 'fuzz
  :doc "AFL++ fuzzing of the harness's protocol boundaries, through an adapter.")

(provide 'harness-fuzz)
;;; harness-fuzz.el ends here
