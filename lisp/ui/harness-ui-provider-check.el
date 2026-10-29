;;; harness-ui-provider-check.el --- The provider and model check page  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; `harness-provider-check' (C-c h !, or Model's neighbour in the
;; harness menu) runs the live checks of the model in front of you, or
;; of any model the catalogue lists with a prefix argument.  It opens
;; the report page, which fills in as the checks settle: one line per
;; check, PASS, FAIL or SKIP, with what went wrong and which advertised
;; feature may have to be removed.  Each check that made model requests
;; links to the internal session that recorded them, where the prompt,
;; the reply and the provider's own error are; the page itself never
;; prints a provider's error text, which a plugin may have filled with a
;; key.  The checks themselves run in the harness process
;; (harness-provider-check.el); this page only follows their events and
;; draws them.
;;
;; The two suites are kept apart on purpose.  Provider contract means
;; the generic provider API is broken or lies about a capability; model
;; behavior means the model is not good enough for the harness.  A
;; failure in one says nothing about the other, and neither stops the
;; checks after it.  A SKIP is unverified, never support.
;;
;; These checks make real, paid model requests, so the command asks
;; first unless `harness-ui-provider-check-confirm' is nil.  A rerun
;; from the page is as explicit as the next command: it starts at once.
;;
;; Keys on the page: g runs the same scope again, p checks the provider
;; contract only, m the model behavior only, M chooses another model, E
;; adds an embedding model's check, c cancels a run in flight.  A click
;; or RET on a check's line, or on its [Session] button, opens the
;; internal session of the calls it made: what the page can only say
;; failed -- a provider's error above all -- the session spells out.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defgroup harness-ui-provider-check nil
  "The provider and model check page."
  :prefix "harness-ui-provider-check-"
  :group 'harness-ui)

(defcustom harness-ui-provider-check-confirm t
  "Non-nil asks before the live provider checks start.
They make several paid model requests, so the command asks once and
does nothing when the answer is no.  A rerun from the page is already
an explicit request and does not ask again."
  :type 'boolean
  :group 'harness-ui-provider-check)

(defconst harness-ui-provider-check--buffer-name "*harness provider check*"
  "Name of the provider and model check page.")

(defvar-local harness-ui-provider-check--job nil
  "Id of the check job this page follows, or nil before it starts.")

(defvar-local harness-ui-provider-check--model nil
  "Model id this page checks.")

(defvar-local harness-ui-provider-check--model-label nil
  "Label of `harness-ui-provider-check--model'.")

(defvar-local harness-ui-provider-check--suite 'all
  "Suite this page runs: `provider', `model' or `all'.")

(defvar-local harness-ui-provider-check--embedding-model nil
  "Embedding model id given for the optional embeddings check, or nil.")

(defvar-local harness-ui-provider-check--plan nil
  "Checks of the job, as the harness said: (:id :suite :name) plists.")

(defvar-local harness-ui-provider-check--results nil
  "Results received, as an alist of check id to result plist.")

(defvar-local harness-ui-provider-check--completed 0
  "How many checks have settled.")

(defvar-local harness-ui-provider-check--total 0
  "How many checks the job runs.")

(defvar-local harness-ui-provider-check--state 'starting
  "Where the page is: `starting', `running', `finished', `cancelled' or `error'.")

(defvar-local harness-ui-provider-check--error nil
  "Why the job could not start, when `harness-ui-provider-check--state' is `error'.")

(defvar-local harness-ui-provider-check--summary nil
  "Summary plist of a finished job, or nil while it runs.")

(defvar-local harness-ui-provider-check--started-at nil
  "Time the job started.")

;;;; Reading the harness's values
;;
;; A result crosses ACP as JSON: symbols arrive as strings.  Keep one
;; normalization point so event and answer handling agree.

(defun harness-ui-provider-check--symbol (value)
  "Return VALUE as a symbol, or nil."
  (and value (intern (format "%s" value))))

(defun harness-ui-provider-check--result-status (result)
  "Return RESULT's status as a symbol."
  (or (harness-ui-provider-check--symbol (plist-get result :status)) 'fail))

(defun harness-ui-provider-check--result-suite (result)
  "Return RESULT's suite as a symbol."
  (or (harness-ui-provider-check--symbol (plist-get result :suite)) 'provider))

(defun harness-ui-provider-check--result-id (result)
  "Return RESULT's check id."
  (format "%s" (or (plist-get result :id) "")))

(defun harness-ui-provider-check--result-at (id)
  "Return the result of check ID, or nil."
  (cdr (assoc id harness-ui-provider-check--results)))

(defun harness-ui-provider-check--store-result (result)
  "Store RESULT in the page, replacing an earlier result of the same check."
  (let* ((id (harness-ui-provider-check--result-id result))
         (cell (assoc id harness-ui-provider-check--results)))
    (if cell
        (setcdr cell result)
      (push (cons id result) harness-ui-provider-check--results))))

;;;; Drawing

(defun harness-ui-provider-check--suite-label (suite)
  "Return a description of SUITE."
  (pcase suite
    ('provider "provider contract")
    ('model "model behavior")
    (_ "both suites")))

(defun harness-ui-provider-check--current-check ()
  "Return the check that runs now, or nil."
  (and (eq harness-ui-provider-check--state 'running)
       (< harness-ui-provider-check--completed (length harness-ui-provider-check--plan))
       (nth harness-ui-provider-check--completed harness-ui-provider-check--plan)))

(defun harness-ui-provider-check--counts ()
  "Return (PASS FAIL SKIP) counted from the results received."
  (let ((results (mapcar #'cdr harness-ui-provider-check--results)))
    (list (cl-count 'pass results :key #'harness-ui-provider-check--result-status)
          (cl-count 'fail results :key #'harness-ui-provider-check--result-status)
          (cl-count 'skip results :key #'harness-ui-provider-check--result-status))))

(defun harness-ui-provider-check--insert-buttons ()
  "Insert the actions that make sense where the page is now."
  (let ((first t))
    (cl-labels ((button (label command)
                  (unless first (insert "  "))
                  (setq first nil)
                  (harness-ui-button label command)))
      (if (memq harness-ui-provider-check--state '(starting running))
          (button "[Cancel]" #'harness-ui-provider-check-cancel)
        (button "[Run again]" #'harness-ui-provider-check-rerun)
        (button "[Provider contract]" #'harness-ui-provider-check-provider-suite)
        (button "[Model behavior]" #'harness-ui-provider-check-model-suite)
        (insert "\n")
        (setq first t)
        (button "[Other model…]" #'harness-ui-provider-check-other-model)
        (button "[Embeddings]" #'harness-ui-provider-check-embedding-model)))))

(defun harness-ui-provider-check--result-sessions (result)
  "Return the internal session ids RESULT names, in the order they were made."
  (let ((sessions (and result (plist-get result :sessions))))
    (cond
     ((vectorp sessions) (append sessions nil))
     ((listp sessions) sessions)
     ((and (stringp sessions) (not (string-empty-p sessions))) (list sessions))
     (t nil))))

(defun harness-ui-provider-check--insert-session-buttons (sessions)
  "Insert a button for each of SESSIONS, the calls a check made.
The buttons open the internal session that recorded the call, where the
prompt, the model's reply and any error are; a check with more than one
call gets one button each, in call order."
  (when sessions
    (insert "  ")
    (if (null (cdr sessions))
        (let ((session (car sessions)))
          (harness-ui-button
           "[Session]"
           (lambda () (interactive) (harness-ui-visit-session session))
           :help "Open the session this check ran in: its prompt, the model's reply, and any error"))
      (cl-loop for session in sessions
               for index from 1
               do (progn
                    (unless (= index 1) (insert " "))
                    (let ((id session)
                          (n index))
                      (harness-ui-button
                       (format "[Session %d]" n)
                       (lambda () (interactive) (harness-ui-visit-session id))
                       :help (format "Open session %d of this check: its prompt, the model's reply, and any error" n))))))))

(defun harness-ui-provider-check--insert-check-name (name sessions status)
  "Insert check NAME, a link to the first of SESSIONS, drawn for STATUS."
  (let ((start (point))
        (face (pcase status
                ('fail 'bold)
                ('pass nil)
                (_ 'harness-dim-face))))
    (insert (if face (propertize name 'face face) name))
    (when sessions
      (harness-ui-add-session-keys (current-buffer) (car sessions) name start (point)
                                   (harness-ui-session-action (car sessions))))))

(defun harness-ui-provider-check--insert-check (entry)
  "Insert one check line for ENTRY, with its result when it has one."
  (let* ((id (harness-ui-provider-check--result-id entry))
         (result (harness-ui-provider-check--result-at id))
         (status (and result (harness-ui-provider-check--result-status result)))
         (name (or (plist-get entry :name) id))
         (detail (and result (plist-get result :detail)))
         (advice (and result (plist-get result :advice)))
         (sessions (and result (harness-ui-provider-check--result-sessions result)))
         (line-start (point)))
    (pcase status
      ('pass
       (insert "  " (propertize "PASS" 'face 'harness-success-face) "  "))
      ('fail
       (insert "  " (propertize "FAIL" 'face 'harness-failure-face) "  "))
      ('skip
       (insert "  " (propertize "SKIP" 'face 'harness-dim-face) "  "))
      (_
       (insert "  " (propertize (if (memq harness-ui-provider-check--state '(finished cancelled))
                                     "NOT RUN"
                                   "WAIT")
                                 'face 'harness-dim-face)
               "  ")))
    (harness-ui-provider-check--insert-check-name name sessions status)
    (harness-ui-provider-check--insert-session-buttons sessions)
    ;; The whole line opens the first call the check made; the buttons for
    ;; the calls after it keep their own.
    (when sessions
      (harness-ui-add-session-keys (current-buffer) (car sessions) name
                                   line-start (point)
                                   (harness-ui-session-action (car sessions))))
    (insert "\n")
    (when (and detail (not (string-empty-p detail)))
      (insert "        "
              (propertize detail 'face
                          (if (eq status 'fail) 'harness-failure-face 'harness-dim-face))
              "\n"))
    (when (and advice (not (string-empty-p advice)))
      (insert "        "
              (propertize (concat "Guidance: " advice) 'face 'harness-caution-face)
              "\n"))))

(defun harness-ui-provider-check--footer ()
  "Return the page's status line."
  (pcase harness-ui-provider-check--state
    ('starting (propertize "Starting…\n" 'face 'harness-dim-face))
    ('running
     (let* ((current (harness-ui-provider-check--current-check))
            (total (max harness-ui-provider-check--total
                        (length harness-ui-provider-check--plan))))
       (propertize
        (format "Running %d of %d%s…\n"
                harness-ui-provider-check--completed total
                (if current (format " (%s)" (plist-get current :name)) ""))
        'face 'harness-caution-face)))
    ((or 'finished 'cancelled)
     (let* ((summary harness-ui-provider-check--summary)
            (counts (harness-ui-provider-check--counts))
            (seconds (plist-get summary :seconds))
            (total (plist-get summary :total)))
       (concat
        (propertize
         (format "%s%d passed · %d failed · %d skipped%s.\n"
                 (if (eq harness-ui-provider-check--state 'cancelled)
                     (format "Cancelled after %d of %s checks: "
                             (or (plist-get summary :completed) harness-ui-provider-check--completed)
                             (or total "?"))
                   "")
                 (nth 0 counts) (nth 1 counts) (nth 2 counts)
                 (if (numberp seconds) (format " in %.1fs" seconds) ""))
         'face (if (cl-plusp (nth 1 counts)) 'harness-failure-face 'default))
        (propertize
         "Skipped checks are unverified, not supported.  A FAIL names the feature to fix or turn off; it is not a settings change.\n"
         'face 'harness-dim-face))))
    ('error
     (propertize (format "Could not start the checks: %s\n"
                         (or harness-ui-provider-check--error "unknown error"))
                 'face 'harness-failure-face))))

(defun harness-ui-provider-check--render ()
  "Draw the whole page, keeping point where it was if it can."
  (let ((inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (insert (propertize "Provider & model check\n" 'face 'harness-label-face))
    (when harness-ui-provider-check--model
      (insert (format "%s · %s\n"
                      (or harness-ui-provider-check--model-label
                          harness-ui-provider-check--model)
                      harness-ui-provider-check--model)))
    (when harness-ui-provider-check--started-at
      (insert (format "Started %s · %s checks · %s\n"
                      (format-time-string "%H:%M:%S"
                                          harness-ui-provider-check--started-at)
                      (max harness-ui-provider-check--total
                           (length harness-ui-provider-check--plan))
                      (harness-ui-provider-check--suite-label
                       harness-ui-provider-check--suite))))
    (when harness-ui-provider-check--embedding-model
      (insert (format "Embedding model: %s\n" harness-ui-provider-check--embedding-model)))
    (insert "\n")
    (harness-ui-provider-check--insert-buttons)
    (insert "\n\n")
    (dolist (suite '(provider model))
      (let ((entries (cl-remove-if-not
                      (lambda (entry)
                        (eq (harness-ui-provider-check--symbol
                             (plist-get entry :suite))
                            suite))
                      harness-ui-provider-check--plan)))
        (when entries
          (insert (propertize (pcase suite
                                ('provider "Provider contract\n")
                                ('model "Model behavior\n"))
                              'face 'harness-label-face))
          (dolist (entry entries)
            (harness-ui-provider-check--insert-check entry))
          (insert "\n"))))
    (when (and (null harness-ui-provider-check--plan)
               (eq harness-ui-provider-check--state 'starting))
      (insert (propertize "Starting…\n" 'face 'harness-dim-face)))
    (insert (harness-ui-provider-check--footer))
    (goto-char (min (max 1 position) (point-max)))))

(defun harness-ui-provider-check--redraw ()
  "Draw the page again, when it is live."
  (when (buffer-live-p (get-buffer harness-ui-provider-check--buffer-name))
    (with-current-buffer harness-ui-provider-check--buffer-name
      (harness-ui-provider-check--render))))

;;;; Starting, following and stopping a job

(defun harness-ui-provider-check--reset (model label suite embedding-model)
  "Forget the last job and prepare to check MODEL, shown as LABEL.
SUITE and EMBEDDING-MODEL are the new run's scope."
  (setq harness-ui-provider-check--job nil
        harness-ui-provider-check--model model
        harness-ui-provider-check--model-label label
        harness-ui-provider-check--suite suite
        harness-ui-provider-check--embedding-model embedding-model
        harness-ui-provider-check--plan nil
        harness-ui-provider-check--results nil
        harness-ui-provider-check--completed 0
        harness-ui-provider-check--total 0
        harness-ui-provider-check--state 'starting
        harness-ui-provider-check--error nil
        harness-ui-provider-check--summary nil
        harness-ui-provider-check--started-at (current-time)))

(defun harness-ui-provider-check--on-kill ()
  "Stop the job of a report buffer that is going away.
Nothing would show its results, and every check it has left may spend
real money."
  (when (and harness-ui-provider-check--job
             (memq harness-ui-provider-check--state '(starting running)))
    (harness-ui-notify "_harness/provider/check-cancel"
                       (list :job harness-ui-provider-check--job))))

(defun harness-ui-provider-check--start (buffer model label suite &optional embedding-model)
  "Start a check job for MODEL in BUFFER, drawn as LABEL.
SUITE is `provider', `model' or `all'; EMBEDDING-MODEL checks the
optional embedding hook.  A job already running in BUFFER is cancelled
first, so its events cannot land in the new report."
  (with-current-buffer buffer
    (when (and harness-ui-provider-check--job
               (memq harness-ui-provider-check--state '(starting running)))
      (harness-ui-call "_harness/provider/check-cancel"
                       (list :job harness-ui-provider-check--job)
                       #'ignore))
    (harness-ui-provider-check--reset model label suite embedding-model)
    (add-hook 'kill-buffer-hook #'harness-ui-provider-check--on-kill nil t)
    (let ((job (format "provider-check-%s" (harness-uuid))))
      (setq harness-ui-provider-check--job job)
      (harness-ui-provider-check--render)
      (harness-ui-call
       "_harness/provider/check-start"
       (list :model model
             :suite (symbol-name suite)
             :embedding-model embedding-model
             :job job)
       (lambda (answer)
         (when (and (buffer-live-p buffer)
                    (equal job (buffer-local-value 'harness-ui-provider-check--job buffer)))
           (with-current-buffer buffer
             (unless (memq harness-ui-provider-check--state '(finished cancelled error))
               (setq harness-ui-provider-check--plan
                     (or harness-ui-provider-check--plan (plist-get answer :checks))
                     harness-ui-provider-check--total
                     (or (plist-get answer :total) harness-ui-provider-check--total)
                     harness-ui-provider-check--state 'running)
               (harness-ui-provider-check--render)))))
       (lambda (error)
         (when (and (buffer-live-p buffer)
                    (equal job (buffer-local-value 'harness-ui-provider-check--job buffer)))
           (with-current-buffer buffer
             (unless (memq harness-ui-provider-check--state '(finished cancelled))
               (setq harness-ui-provider-check--state 'error
                     harness-ui-provider-check--error
                     (harness-error-short-message error))
               (harness-ui-provider-check--render)))))))))

(defun harness-ui-provider-check--on-event (event args)
  "Follow EVENT with ARGS when it belongs to the page's job."
  (setq args (append args nil))
  (when (and (string-prefix-p "provider-check/" event)
             (buffer-live-p (get-buffer harness-ui-provider-check--buffer-name)))
    (let* ((id (car args))
           (buffer (get-buffer harness-ui-provider-check--buffer-name))
           (current (buffer-local-value 'harness-ui-provider-check--job buffer)))
      (when (and id current (equal (format "%s" id) (format "%s" current)))
        (with-current-buffer buffer
          (pcase event
            ("provider-check/started"
             (let ((model (nth 1 args))
                   (suite (nth 2 args))
                   (total (nth 3 args))
                   (checks (nth 4 args)))
               (when (stringp model)
                 (setq harness-ui-provider-check--model model
                       harness-ui-provider-check--model-label
                       (or harness-ui-provider-check--model-label
                           (harness-ui-model-label model))))
               (when suite
                 (setq harness-ui-provider-check--suite
                       (harness-ui-provider-check--symbol suite)))
               (when (numberp total)
                 (setq harness-ui-provider-check--total total))
               (when checks
                 (setq harness-ui-provider-check--plan checks))
               (unless (memq harness-ui-provider-check--state '(finished cancelled error))
                 (setq harness-ui-provider-check--state 'running))
               (harness-ui-provider-check--render)))
            ("provider-check/result"
             (let ((result (nth 1 args))
                   (completed (nth 2 args))
                   (total (nth 3 args)))
               (when result
                 (harness-ui-provider-check--store-result result))
               (when (numberp completed)
                 (setq harness-ui-provider-check--completed completed))
               (when (numberp total)
                 (setq harness-ui-provider-check--total total))
               (harness-ui-provider-check--render)))
            ("provider-check/finished"
             (let ((results (nth 2 args))
                   (summary (nth 3 args)))
               (when results
                 (setq harness-ui-provider-check--results
                       (mapcar (lambda (result)
                                 (cons (harness-ui-provider-check--result-id result)
                                       result))
                               results)))
               (setq harness-ui-provider-check--summary summary
                     harness-ui-provider-check--completed
                     (or (plist-get summary :completed)
                         (length harness-ui-provider-check--results))
                     harness-ui-provider-check--total
                     (or (plist-get summary :total)
                         harness-ui-provider-check--total)
                     harness-ui-provider-check--state
                     (if (harness-json-true-p (plist-get summary :cancelled))
                         'cancelled
                       'finished))
               (harness-ui-provider-check--render)))))))))

;;;; Commands

(defun harness-ui-provider-check-rerun ()
  "Run the page's checks again, on the same model and scope."
  (interactive)
  (unless (derived-mode-p 'harness-ui-provider-check-mode)
    (user-error "Not in the provider check page"))
  (harness-ui-provider-check--start (current-buffer)
                                    harness-ui-provider-check--model
                                    harness-ui-provider-check--model-label
                                    harness-ui-provider-check--suite
                                    harness-ui-provider-check--embedding-model))

(defun harness-ui-provider-check-provider-suite ()
  "Run the provider contract checks only."
  (interactive)
  (unless (derived-mode-p 'harness-ui-provider-check-mode)
    (user-error "Not in the provider check page"))
  (harness-ui-provider-check--start (current-buffer)
                                    harness-ui-provider-check--model
                                    harness-ui-provider-check--model-label
                                    'provider
                                    harness-ui-provider-check--embedding-model))

(defun harness-ui-provider-check-model-suite ()
  "Run the model behavior checks only."
  (interactive)
  (unless (derived-mode-p 'harness-ui-provider-check-mode)
    (user-error "Not in the provider check page"))
  (harness-ui-provider-check--start (current-buffer)
                                    harness-ui-provider-check--model
                                    harness-ui-provider-check--model-label
                                    'model))

(defun harness-ui-provider-check-other-model ()
  "Choose another model and check it."
  (interactive)
  (unless (derived-mode-p 'harness-ui-provider-check-mode)
    (user-error "Not in the provider check page"))
  (let ((buffer (current-buffer)))
    (harness-ui-choose-model
     (lambda (model label)
       (when (buffer-live-p buffer)
         (harness-ui-provider-check--start buffer model label 'all))))))

(defun harness-ui-provider-check-embedding-model ()
  "Ask for an embedding model and run the provider contract checks with it."
  (interactive)
  (unless (derived-mode-p 'harness-ui-provider-check-mode)
    (user-error "Not in the provider check page"))
  (let* ((provider (car (split-string (or harness-ui-provider-check--model "") ":")))
         (initial (or harness-ui-provider-check--embedding-model
                      (and provider (concat provider ":"))))
         (model (read-string "Embedding model (PROVIDER:NAME): " initial)))
    (when (string-empty-p (string-trim model))
      (user-error "No embedding model chosen"))
    (setq harness-ui-provider-check--embedding-model (string-trim model))
    (harness-ui-provider-check--start (current-buffer)
                                      harness-ui-provider-check--model
                                      harness-ui-provider-check--model-label
                                      'provider
                                      harness-ui-provider-check--embedding-model)))

(defun harness-ui-provider-check-cancel ()
  "Cancel the check job running in this page."
  (interactive)
  (unless (derived-mode-p 'harness-ui-provider-check-mode)
    (user-error "Not in the provider check page"))
  (if (not (memq harness-ui-provider-check--state '(starting running)))
      (message "The checks are not running")
    (harness-ui-call "_harness/provider/check-cancel"
                     (list :job harness-ui-provider-check--job)
                     (lambda (_cancelled)
                       (message "Cancelling the checks…")))))

(defvar harness-ui-provider-check-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "g") #'harness-ui-provider-check-rerun)
    (define-key map (kbd "p") #'harness-ui-provider-check-provider-suite)
    (define-key map (kbd "m") #'harness-ui-provider-check-model-suite)
    (define-key map (kbd "M") #'harness-ui-provider-check-other-model)
    (define-key map (kbd "E") #'harness-ui-provider-check-embedding-model)
    (define-key map (kbd "c") #'harness-ui-provider-check-cancel)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-provider-check-mode'.")

(define-derived-mode harness-ui-provider-check-mode special-mode "Provider check"
  "Major mode of the provider and model check page.
\\{harness-ui-provider-check-mode-map}"
  (setq truncate-lines nil
        word-wrap t
        buffer-read-only t))

(put 'harness-ui-provider-check-mode 'harness-menu-group
     '("Provider check"
       ["Check"
        (". g" "Run the same checks again" harness-ui-provider-check-rerun)
        (". p" "Provider contract only" harness-ui-provider-check-provider-suite)
        (". m" "Model behavior only" harness-ui-provider-check-model-suite)
        (". M" "Check another model…" harness-ui-provider-check-other-model)
        (". E" "Check an embedding model…" harness-ui-provider-check-embedding-model)
        (". c" "Cancel the running checks" harness-ui-provider-check-cancel)]))

;;;; The command

(defun harness-ui-provider-check--current-model ()
  "Return the model of the session in front of the user, or nil."
  (let ((target (ignore-errors (harness-ui--setting-target nil))))
    (cond
     ((stringp target)
      (plist-get (harness-ui-session target) :model))
     ((consp target)
      (plist-get (car target) :model))
     (t nil))))

(defun harness-ui-provider-check--ask-and-open (model label)
  "Ask to spend the requests, then check MODEL, shown as LABEL."
  (if (and harness-ui-provider-check-confirm
           (not (y-or-n-p
                 (format "Run live checks of %s?  They make several paid API requests.  Continue?"
                         (or label model)))))
      (message "Provider check cancelled")
    (let ((buffer (get-buffer-create harness-ui-provider-check--buffer-name)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'harness-ui-provider-check-mode)
          (harness-ui-provider-check-mode)))
      (harness-ui-display-view buffer)
      (harness-ui-provider-check--start buffer model label 'all))))

;;;###autoload
(defun harness-provider-check (&optional arg)
  "Run live checks of a model's provider and of the model itself.
The checks are the generic provider contract and a separate model
behavior suite; each reports PASS, FAIL or SKIP with guidance, and one
failure does not stop the others.  A SKIP means unverified, not
supported.

The model is the one of the session in front of you.  ARG is the
prefix argument: with it, choose any model the catalogue lists
instead.  The checks make real, paid API requests, so the command asks
first unless `harness-ui-provider-check-confirm' is nil.

The report fills in as each check settles.  On it, g runs the same
checks again, p or m runs one suite, M checks another model, E adds an
embedding model's check, and c cancels the run."
  (interactive "p")
  (if (>= (or arg 1) 4)
      (harness-ui-choose-model
       (lambda (model label)
         (harness-ui-provider-check--ask-and-open model label)))
    (let ((model (harness-ui-provider-check--current-model)))
      (unless (and model (stringp model) (not (string-empty-p model)))
        (user-error "No model to check; give one with `C-u'"))
      (harness-ui-provider-check--ask-and-open
       model (harness-ui-model-label model)))))

;;;; Setup

(declare-function transient-get-suffix "transient")
(declare-function transient-append-suffix "transient")
(declare-function transient-remove-suffix "transient")

(defun harness-ui-provider-check--suffix-command (key)
  "Return the command the harness menu has at KEY, or nil."
  (when-let* ((suffix (ignore-errors (transient-get-suffix 'harness-menu key))))
    (plist-get (if (keywordp (cadr suffix)) (cdr suffix) (car (last suffix)))
               :command)))

(defun harness-ui-provider-check--init ()
  "Follow the harness's check events, and offer the command in the keys."
  (add-hook 'harness-ui-event-functions #'harness-ui-provider-check--on-event)
  (define-key harness-ui-map (kbd "!") #'harness-provider-check)
  (condition-case err
      (pcase (harness-ui-provider-check--suffix-command "!")
        ((pred null)
         (transient-append-suffix
          'harness-menu "m" '("!" "Check provider & model" harness-provider-check)))
        ('harness-provider-check nil)
        (other
         (harness-log 'warn "provider-check: the menu key ! is %s's: no entry"
                      other)))
    (error
     (harness-log 'warn "provider-check: no menu entry: %s"
                  (error-message-string err)))))

(defun harness-ui-provider-check--shutdown ()
  "Stop following the harness's check events and take the keys back."
  (remove-hook 'harness-ui-event-functions #'harness-ui-provider-check--on-event)
  (when (eq (lookup-key harness-ui-map (kbd "!")) #'harness-provider-check)
    (define-key harness-ui-map (kbd "!") nil t))
  (when (eq (harness-ui-provider-check--suffix-command "!")
            #'harness-provider-check)
    (ignore-errors (transient-remove-suffix 'harness-menu "!"))))

(harness-define-module 'ui-provider-check
  :doc "The provider and model check page: live checks of any model, from the harness."
  :requires '(ui)
  :init #'harness-ui-provider-check--init
  :shutdown #'harness-ui-provider-check--shutdown)

(provide 'harness-ui-provider-check)
;;; harness-ui-provider-check.el ends here
