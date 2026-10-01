;;; harness-agent.el --- The turn loop  -*- lexical-binding: t; -*-

;;; Commentary:

;; One turn: the user's message goes in, the model streams text and
;; thinking, asks for tools, the harness runs them (through the
;; permission chain) and feeds the results back, until the model stops.
;; Providers that run their own loop (hosted) hand each tool call to us
;; through a `:respond' callback; native providers stop with `tool-use'
;; and are called again with the results.  Steering messages sent while
;; a turn runs are injected at the next step boundary; queued messages
;; go out together when the turn ends.
;;
;; The loop is entirely event driven: nothing here waits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(declare-function harness-tool-title "harness-tools")

(defcustom harness-agent-max-steps 200
  "Maximum model calls in one turn before the harness stops it."
  :type 'integer :group 'harness)

(defcustom harness-agent-base-system-prompt
  "You are an expert software engineering agent working inside the user's GNU Emacs through the Emacs agent harness.

Work carefully and verify what you do. Prefer the provided tools over guessing; read files before editing them; keep edits minimal and correct. When a tool call is denied, read the reason: it tells you what is permitted, so adjust your approach instead of repeating the call. Stay inside the session's working directory unless told otherwise. When you need a decision only the user can make, use the ask_user tool. Keep answers concise and concrete."
  "First section of every system prompt."
  :type 'string :group 'harness)

(defcustom harness-agent-cancel-grace 3
  "Seconds to wait for a provider to acknowledge a cancel before forcing it."
  :type 'number :group 'harness)

(cl-defstruct (harness-agent-turn (:copier nil))
  session-id promise handle (steps 0) cancelled steering
  text-node text-buf think-node think-buf
  (pending 0) waiting-done stop-reason error hosted last-usage started)

(defvar harness-agent--turns (make-hash-table :test 'equal)
  "Session id -> running `harness-agent-turn'.")

(defun harness-agent-turn-for (session-id)
  "Return the running turn of SESSION-ID or nil."
  (gethash session-id harness-agent--turns))

(defun harness-agent-running-p (session-id)
  "Non-nil while SESSION-ID has a running turn."
  (and (gethash session-id harness-agent--turns) t))

;;;; Prompt assembly

(defun harness-agent--system-prompt (session)
  "Return the system prompt for SESSION after the `agent/system-prompt' filter."
  (let ((base (format "%s\n\n## Environment\n- Working directory: %s\n- Project: %s\n- Date: %s\n- System: %s\n- Editor: GNU Emacs %s\n"
                      harness-agent-base-system-prompt
                      (plist-get session :cwd)
                      (or (and (harness-method-exists-p 'project/name)
                               (harness-call 'project/name (plist-get session :project)))
                          (plist-get session :project))
                      (format-time-string "%Y-%m-%d")
                      system-configuration
                      emacs-version)))
    (harness-run-filter 'agent/system-prompt base session)))

(defun harness-agent--vision-p (session)
  (member "image" (plist-get (and (harness-method-exists-p 'provider/model)
                                  (harness-call 'provider/model (plist-get session :model)))
                             :input-modalities)))

(defun harness-agent--file-base64 (path)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (base64-encode-string (buffer-string) t)))

(defun harness-agent--prepare-block (block session)
  "Return BLOCK ready for a provider: images inlined, files described."
  (pcase (plist-get block :type)
    ("image"
     (cond ((plist-get block :data) block)
           ((and (plist-get block :path) (harness-agent--vision-p session)
                 (file-readable-p (plist-get block :path)))
            (list :type "image" :mime (or (plist-get block :mime) "image/png")
                  :data (harness-agent--file-base64 (plist-get block :path))))
           (t (list :type "text" :text (format "[image attached: %s]" (or (plist-get block :path) "clipboard"))))))
    ("audio"
     (if (plist-get block :data) block
       (list :type "text" :text (format "[audio attached: %s]" (plist-get block :path)))))
    ("file"
     (list :type "text"
           :text (format "Attached file: %s (%s bytes)" (plist-get block :path)
                         (or (plist-get block :size) (harness-file-size (plist-get block :path)) "?"))))
    (_ block)))

(defun harness-agent--prepare-messages (session messages)
  (mapcar (lambda (m)
            (if (eq (plist-get m :role) 'user)
                (list :role 'user
                      :content (mapcar (lambda (b) (harness-agent--prepare-block b session))
                                       (plist-get m :content)))
              m))
          messages))

(defun harness-agent--blocks-text (blocks)
  "Return the plain text of BLOCKS for a transcript node."
  (mapconcat (lambda (b)
               (pcase (plist-get b :type)
                 ("text" (plist-get b :text))
                 ("file" (format "@%s" (file-name-nondirectory (or (plist-get b :path) ""))))
                 ("image" "[image]")
                 ("audio" "[audio]")
                 (_ "")))
             blocks " "))

(defun harness-agent--only-text-p (blocks)
  (cl-every (lambda (b) (equal (plist-get b :type) "text")) blocks))

(defun harness-agent-attachments-to-blocks (attachments)
  "Turn ATTACHMENT plists into content blocks."
  (mapcar (lambda (a)
            (let ((mime (or (plist-get a :mime) "")))
              (cond ((string-prefix-p "image/" mime)
                     (list :type "image" :mime mime :path (plist-get a :path)))
                    ((string-prefix-p "audio/" mime)
                     (list :type "audio" :mime mime :path (plist-get a :path)))
                    (t (list :type "file" :path (plist-get a :path) :size (plist-get a :size)
                             :mime mime :name (plist-get a :name))))))
          attachments))

;;;; Turn start

(defun harness-agent--reanimate (session-id)
  "Resume SESSION-ID when it is inactive, so a message sent to it revives it.
A turn still running in it (it was closed mid-turn) keeps it running."
  (when (eq (plist-get (harness-call 'session/get session-id) :status) 'inactive)
    (harness-call 'session/resume session-id)
    (when (gethash session-id harness-agent--turns)
      (harness-call 'session/set-status session-id 'running))))

(harness-defmethod agent/prompt (session-id blocks &optional opts)
  "Send BLOCKS (content blocks, or a string) to SESSION-ID.
Idle session: start a turn and return a promise of (:stop-reason …).
Running session: steer — the message is recorded now and delivered at
the next step boundary; the running turn's promise is returned.  OPTS
`:queue' non-nil only queues the message for the next turn.
An inactive session is resumed first: sending to it brings it back."
  (let* ((blocks (if (stringp blocks) (list (list :type "text" :text blocks)) blocks))
         (turn (gethash session-id harness-agent--turns)))
    (unless (plist-get opts :queue)
      (harness-agent--reanimate session-id))
    (cond
     ((plist-get opts :queue)
      (harness-call 'session/queue session-id (harness-agent--blocks-text blocks)
                    (plist-get opts :attachments))
      (harness-resolved (list :queued t)))
     (turn
      (harness-call 'session/append session-id
                    (list :kind 'user :content (harness-agent--blocks-text blocks)
                          :blocks (unless (harness-agent--only-text-p blocks) blocks)
                          :meta (list :steering t)))
      (setf (harness-agent-turn-steering turn)
            (append (harness-agent-turn-steering turn) (list (harness-agent--blocks-text blocks))))
      (harness-emit 'agent/steered session-id)
      (harness-agent-turn-promise turn))
     (t (harness-agent--start session-id blocks)))))

(defun harness-agent--start (session-id blocks)
  (let* ((session (harness-call 'session/get session-id))
         (promise (harness-make-promise))
         (turn (make-harness-agent-turn :session-id session-id :promise promise :started (float-time)))
         (node (list :kind 'user :content (harness-agent--blocks-text blocks)
                     :blocks (unless (harness-agent--only-text-p blocks) blocks))))
    (puthash session-id turn harness-agent--turns)
    ;; The gate runs first so that an automatic compaction lands before
    ;; the user's new message, never after it.
    (harness-then
     (harness-run-filter-async 'agent/before-turn (list :proceed t) session)
     (lambda (gate)
       (when (harness-call 'session/exists-p session-id)
         (harness-call 'session/append session-id node))
       (if (not (plist-get gate :proceed))
           (progn
             (when (plist-get gate :reason)
               (harness-call 'session/hint session-id (format "Turn not started: %s" (plist-get gate :reason))))
             (harness-agent--end turn 'blocked (plist-get gate :reason)))
         (harness-call 'session/set-status session-id 'running)
         (harness-emit 'agent/turn-started session-id)
         (harness-agent--step turn))))
    promise))

;;;; Steps

(defun harness-agent--step (turn)
  "Call the provider once for TURN."
  (let ((sid (harness-agent-turn-session-id turn)))
    (cond
     ((harness-agent-turn-cancelled turn) (harness-agent--end turn 'cancelled))
     ((>= (harness-agent-turn-steps turn) harness-agent-max-steps)
      (harness-call 'session/hint sid (format "Stopped after %d steps" harness-agent-max-steps))
      (harness-agent--end turn 'max-steps))
     ((not (harness-call 'session/exists-p sid)) (harness-agent--end turn 'error "session deleted"))
     (t
      (cl-incf (harness-agent-turn-steps turn))
      (setf (harness-agent-turn-text-node turn) nil (harness-agent-turn-text-buf turn) nil
            (harness-agent-turn-think-node turn) nil (harness-agent-turn-think-buf turn) nil
            (harness-agent-turn-pending turn) 0 (harness-agent-turn-waiting-done turn) nil
            (harness-agent-turn-stop-reason turn) nil (harness-agent-turn-error turn) nil)
      (let* ((session (harness-call 'session/get sid))
             (request (list :model (plist-get session :model)
                            :session session
                            :system (harness-agent--system-prompt session)
                            :messages (harness-agent--prepare-messages session (harness-call 'session/messages sid))
                            :tools (if (harness-method-exists-p 'tools/list) (harness-call 'tools/list sid) nil)
                            :thinking (plist-get session :thinking)
                            :provider-state (plist-get session :provider-state)
                            :on-event (lambda (ev) (harness-agent--on-event turn ev)))))
        (harness-emit 'agent/step-started sid (harness-agent-turn-steps turn))
        (setf (harness-agent-turn-handle turn) (harness-call 'provider/complete request)))))))

(defun harness-agent--take-steering (turn)
  "Return and clear pending steering text for TURN, or nil."
  (let ((texts (harness-agent-turn-steering turn)))
    (setf (harness-agent-turn-steering turn) nil)
    (and texts (string-join texts "\n\n"))))

(defun harness-agent--on-event (turn ev)
  (let ((sid (harness-agent-turn-session-id turn)))
    (pcase (plist-get ev :type)
      ('start nil)
      ('text (harness-agent--stream turn 'assistant (plist-get ev :delta)))
      ('thinking (harness-agent--stream turn 'thinking (plist-get ev :delta)))
      ('tool-call (harness-agent--tool-call turn ev))
      ('tool-result nil)
      ('usage
       (setf (harness-agent-turn-last-usage turn) ev)
       (harness-call 'session/usage-add sid
                     (list :input (plist-get ev :input) :output (plist-get ev :output)
                           :cache-read (plist-get ev :cache-read) :cache-write (plist-get ev :cache-write)
                           :cost (plist-get ev :cost) :list-cost (plist-get ev :list-cost)
                           :billing (plist-get ev :billing) :plan (plist-get ev :plan)
                           :context (plist-get ev :context))))
      ('provider-state (harness-call 'session/set-provider-state sid (plist-get ev :state)))
      ('quota (harness-call 'session/runtime sid :quota (plist-get ev :windows))
              (harness-emit 'agent/quota sid (plist-get ev :windows)))
      ('hint (harness-call 'session/hint sid (plist-get ev :text)))
      ('done
       (harness-agent--finalize-live turn)
       (setf (harness-agent-turn-stop-reason turn) (plist-get ev :stop-reason)
             (harness-agent-turn-error turn) (plist-get ev :error)
             (harness-agent-turn-waiting-done turn) t)
       (when (eq (plist-get ev :stop-reason) 'error)
         (harness-call 'session/hint sid (format "Error: %s" (or (plist-get ev :error) "unknown"))))
       (harness-agent--maybe-continue turn))
      (other (harness-log 'debug "agent: unknown provider event %S" other)))))

(defun harness-agent--stream (turn kind delta)
  "Append DELTA of KIND (assistant or thinking) to the live node of TURN."
  (when (and delta (not (string-empty-p delta)))
    (let* ((sid (harness-agent-turn-session-id turn))
           (thinking (eq kind 'thinking)))
      ;; Switching between thinking and text closes the other live node.
      (if thinking
          (when (harness-agent-turn-text-node turn) (harness-agent--finalize turn 'assistant))
        (when (harness-agent-turn-think-node turn) (harness-agent--finalize turn 'thinking)))
      (let ((node-id (if thinking (harness-agent-turn-think-node turn) (harness-agent-turn-text-node turn))))
        (if node-id
            (let ((buf (if thinking (harness-agent-turn-think-buf turn) (harness-agent-turn-text-buf turn))))
              (setq buf (concat buf delta))
              (if thinking (setf (harness-agent-turn-think-buf turn) buf) (setf (harness-agent-turn-text-buf turn) buf))
              (harness-call 'session/update-node sid node-id :content buf :transient t))
          (let ((node (harness-call 'session/append sid (list :kind kind :content delta))))
            (setq node-id (plist-get node :id))
            (if thinking
                (setf (harness-agent-turn-think-node turn) node-id (harness-agent-turn-think-buf turn) delta)
              (setf (harness-agent-turn-text-node turn) node-id (harness-agent-turn-text-buf turn) delta))))
        (harness-emit 'agent/stream sid node-id kind delta)))))

(defun harness-agent--finalize (turn kind)
  (let* ((sid (harness-agent-turn-session-id turn))
         (thinking (eq kind 'thinking))
         (node-id (if thinking (harness-agent-turn-think-node turn) (harness-agent-turn-text-node turn)))
         (buf (if thinking (harness-agent-turn-think-buf turn) (harness-agent-turn-text-buf turn))))
    (when node-id
      (harness-call 'session/update-node sid node-id :content (or buf "")
                    :meta (list :model (plist-get (harness-call 'session/get sid) :model)
                                :usage (and (not thinking) (harness-agent-turn-last-usage turn))))
      (if thinking
          (setf (harness-agent-turn-think-node turn) nil (harness-agent-turn-think-buf turn) nil)
        (setf (harness-agent-turn-text-node turn) nil (harness-agent-turn-text-buf turn) nil)))))

(defun harness-agent--finalize-live (turn)
  (harness-agent--finalize turn 'thinking)
  (harness-agent--finalize turn 'assistant))

(defun harness-agent--tool-call (turn ev)
  (let* ((sid (harness-agent-turn-session-id turn))
         (name (plist-get ev :name)) (input (plist-get ev :input))
         (call-id (or (plist-get ev :id) (harness-short-id)))
         (respond (plist-get ev :respond))
         (started (float-time)))
    (harness-agent--finalize-live turn)
    (setf (harness-agent-turn-hosted turn) (and respond t))
    (cl-incf (harness-agent-turn-pending turn))
    (let ((node (harness-call 'session/append sid
                              (list :kind 'tool-call :tool name :call-id call-id :input input
                                    :title (if (fboundp 'harness-tool-title) (harness-tool-title name input) name)))))
      (harness-emit 'agent/tool-call sid node)
      (harness-then
       (harness-call-async 'tools/execute sid (list :id call-id :name name :input input))
       (lambda (result)
         (condition-case err
             (let* ((steer (harness-agent--take-steering turn))
                    (content (plist-get result :content))
                    (content (if steer
                                 (concat content "\n\n<user_message>\n" steer "\n</user_message>")
                               content))
                    (rnode (harness-call 'session/append sid
                                         (list :kind 'tool-result :call-id call-id
                                               :output (plist-get result :content)
                                               :is-error (plist-get result :is-error)
                                               :attachments (plist-get result :attachments)
                                               :meta (list :duration (- (float-time) started)
                                                           :denied (plist-get result :denied)
                                                           :truncated (plist-get result :truncated))))))
               (harness-emit 'agent/tool-result sid rnode)
               (when respond
                 (funcall respond (list :content content :is-error (plist-get result :is-error)))))
           (error
            (harness-log 'error "agent: recording result of %s failed: %S" name err)
            (when respond
              (funcall respond (list :content (plist-get result :content)
                                     :is-error (plist-get result :is-error))))))
         (cl-decf (harness-agent-turn-pending turn))
         (harness-agent--maybe-continue turn))
       (lambda (err)
         (let ((msg (format "Tool %s failed: %s" name (harness-error-message err))))
           (ignore-errors
             (harness-call 'session/append sid (list :kind 'tool-result :call-id call-id :output msg :is-error t)))
           (when respond (funcall respond (list :content msg :is-error t)))
           (cl-decf (harness-agent-turn-pending turn))
           (harness-agent--maybe-continue turn)))))))

(defun harness-agent--maybe-continue (turn)
  "Decide what happens once the provider is done and no tools are running."
  (when (and (harness-agent-turn-waiting-done turn)
             (zerop (harness-agent-turn-pending turn)))
    (setf (harness-agent-turn-waiting-done turn) nil)
    (let ((sid (harness-agent-turn-session-id turn))
          (reason (harness-agent-turn-stop-reason turn)))
      (pcase reason
        ((or 'tool-use (and 'end-turn (guard (harness-agent-turn-steering turn))))
         (if (harness-agent-turn-cancelled turn)
             (harness-agent--end turn 'cancelled)
           (harness-then
            (harness-run-filter-async 'agent/step (list :proceed t) (harness-call 'session/get sid))
            (lambda (gate)
              (if (plist-get gate :proceed)
                  (harness-agent--step turn)
                (when (plist-get gate :reason) (harness-call 'session/hint sid (plist-get gate :reason)))
                (harness-agent--end turn 'blocked (plist-get gate :reason)))))))
        ('end-turn (harness-agent--end turn 'end-turn))
        ('max-tokens (harness-call 'session/hint sid "The model hit its output limit.")
                     (harness-agent--end turn 'max-tokens))
        ('cancelled (harness-agent--end turn 'cancelled))
        ('error (harness-agent--end turn 'error (harness-agent-turn-error turn)))
        (_ (harness-agent--end turn (or reason 'end-turn)))))))

(defun harness-agent--end (turn reason &optional error)
  (let ((sid (harness-agent-turn-session-id turn)))
    (when (eq (gethash sid harness-agent--turns) turn)
      (remhash sid harness-agent--turns)
      (when (harness-call 'session/exists-p sid)
        (harness-call 'session/usage-add sid (list :turns 1))
        (let ((session (harness-call 'session/get sid)))
          (unless (eq (plist-get session :status) 'inactive)
            (harness-call 'session/set-status sid (if (plist-get session :pending) 'blocked 'idle)))))
      (harness-emit 'agent/turn-ended sid reason)
      (harness-resolve (harness-agent-turn-promise turn)
                       (list :stop-reason reason :error error
                             :duration (- (float-time) (harness-agent-turn-started turn))))
      (when (and (eq reason 'end-turn)
                 (harness-call 'session/exists-p sid)
                 (plist-get (harness-call 'session/get sid) :queue))
        (harness-run-soon #'harness-call 'agent/send-queue sid)))))

;;;; Cancel and queue

(harness-defmethod agent/cancel (session-id)
  "Cancel the running turn of SESSION-ID, if any."
  (let ((turn (gethash session-id harness-agent--turns)))
    (when turn
      (setf (harness-agent-turn-cancelled turn) t)
      (let ((cancel (plist-get (harness-agent-turn-handle turn) :cancel)))
        (when cancel (ignore-errors (funcall cancel))))
      (run-at-time harness-agent-cancel-grace nil
                   (lambda () (when (eq (gethash session-id harness-agent--turns) turn)
                                (harness-agent--finalize-live turn)
                                (harness-agent--end turn 'cancelled))))
      t)))

(harness-defmethod agent/send-queue (session-id)
  "Send every queued message of SESSION-ID as one turn; return its promise."
  (let ((items (harness-call 'session/queue-take session-id)))
    (if (null items)
        (harness-resolved (list :stop-reason 'nothing-queued))
      (let ((blocks (cl-loop for it in items
                             append (cons (list :type "text" :text (plist-get it :text))
                                          (harness-agent-attachments-to-blocks (plist-get it :attachments))))))
        (harness-call 'agent/prompt session-id blocks)))))

(harness-defmethod agent/running (&optional session-id)
  "Return running session ids, or non-nil when SESSION-ID is running."
  (if session-id
      (harness-agent-running-p session-id)
    (let (out) (maphash (lambda (k _) (push k out)) harness-agent--turns) out)))

(dolist (ev '((agent/turn-started . "(SESSION-ID)") (agent/turn-ended . "(SESSION-ID REASON)")
              (agent/step-started . "(SESSION-ID STEP)")
              (agent/stream . "(SESSION-ID NODE-ID KIND DELTA)")
              (agent/tool-call . "(SESSION-ID NODE)") (agent/tool-result . "(SESSION-ID NODE)")
              (agent/steered . "(SESSION-ID)") (agent/quota . "(SESSION-ID WINDOWS)")))
  (harness-declare-event (car ev) (cdr ev)))

;;;; Exit

(defun harness-agent--save-live ()
  "Write the text that running turns have streamed so far.
Streaming updates are not written one by one, so a harness exiting
mid-turn would otherwise keep only the first chunk of the message it
was receiving."
  (maphash (lambda (_ turn)
             (condition-case err
                 (harness-agent--finalize-live turn)
               (error (harness-log 'warn "agent: saving a streamed message failed: %S" err))))
           harness-agent--turns))

(defun harness-agent--init ()
  "Save streamed text when Emacs exits (idempotent)."
  (add-hook 'kill-emacs-hook #'harness-agent--save-live))

(harness-define-module 'agent
  :doc "The turn loop: prompt, stream, run tools, steer, queue."
  :requires '(session provider tools)
  :init #'harness-agent--init
  :shutdown #'harness-agent--save-live)

(provide 'harness-agent)
;;; harness-agent.el ends here
