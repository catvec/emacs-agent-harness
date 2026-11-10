;;; harness-ui-voice-output.el --- Output voice settings and auditions  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The output voice of this client: which voice spoken replies use, what
;; that service lets it be told about pace and volume, and an audition
;; that hears a choice before it is kept.  `harness-voice-output' opens
;; the page; the voice setup list and the compose box's [Setup] reach it
;; too.
;;
;; The voices are the ones the selected speech service reports, never a
;; list made here.  The page asks the harness (`speech/voices' over ACP,
;; see harness-speech.el), which asks the service and passes its answer
;; on: the service's own names with the language and voice a person
;; reads, or one line saying why there is no list (the pipeline stopped,
;; the service has no voice route, the request failed, the answer is
;; still on its way).  A provider with no service behind it -- the
;; scripted fixture, a sidecar of your own, the device voice -- says so
;; and offers no audition.  ChatGPT Live keeps the voice its server
;; defines; the page says `Provider-managed' rather than invent a
;; catalogue for an endpoint nobody verified.
;;
;; What the page keeps is this client's own configuration:
;; `harness-voice-unmute-voice' and `harness-voice-unmute-parameters' for
;; the local service, `harness-voice-chatgpt-voice' for GPT-Live.  They
;; are saved through `harness-voice--save-choice' in this Emacs's custom
;; file, as the provider choice is, so the next Emacs starts with them.
;; The effective value, which speaks the next reply, is the policy's when
;; a policy sets the option, else the saved custom value, else the
;; option's default; the page names which.  A client with no custom file
;; takes the value for the session and the save says so through
;; Customize's own warning.  A running live session is restarted when a
;; saved voice or parameter changes, because its sidecar was started with
;; the old argv; the microphone and the conversation are its own, and
;; the restart ends that call the way a provider change does.
;;
;; An audition never saves.  It asks the service for the drafted voice
;; and parameter values -- including changes not yet saved -- and plays
;; the WAV through this machine's player.  Cancel, Revert, closing the
;; page, choosing another voice, changing a value, changing the provider,
;; reconnecting and another audition all cancel the one in flight: its
;; request is aborted, its player stopped, its audio deleted, and its
;; callbacks see a generation that is no longer the page's, so a slow
;; answer can never speak an older voice over a newer choice.  The page
;; shows `Loading', `Playing`, `Stopped` or `Failed` with [Retry], and
;; `Unsaved changes` while the draft differs from what is saved.
;;
;; An audition sends no prompt, writes no transcript and speaks to no
;; session; the microphone is untouched and a live call keeps running.
;; The audio is real WAV from the real service.  The page's tests use
;; recorded fixtures and a fake player, and say so where they do.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-voice-providers)

(declare-function harness-voice--save-choice "harness-ui-voice-providers")
(declare-function harness-voice-live-stop "harness-ui-voice-live")
(declare-function harness-voice-live-start "harness-ui-voice-live")
(declare-function harness-voice-live--active-p "harness-ui-voice-live")

(defgroup harness-voice-output nil
  "The output voice of this client and its audition."
  :group 'harness-voice
  :prefix "harness-voice-output-")

(defcustom harness-voice-output-audition-text "The merge queue is empty."
  "The words an audition speaks.
A whole short sentence, so pace and volume are heard as they will be
spoken.  It is never sent to a model or written to a conversation."
  :type 'string
  :group 'harness-voice-output)

(defcustom harness-voice-output-audition-timeout 60
  "Seconds an audition may take to produce audio before it fails."
  :type 'number
  :group 'harness-voice-output)

;;;; The page's state

(defvar-local harness-voice-output--draft-voice nil
  "The voice this page has drafted, or nil for the saved one.")

(defvar-local harness-voice-output--draft-parameters nil
  "The parameter values this page has drafted, as an alist.
Nil means nothing was changed on this page, so the saved values show.")

(defvar-local harness-voice-output--audition nil
  "The audition in flight or just finished, as a plist.
See `harness-voice-output-audition'.")

(defvar-local harness-voice-output--error nil
  "The one line a validation or audition failure shows, or nil.")

(defvar-local harness-voice-output--notice nil
  "A one-line note about a saved value, or nil.")

(defvar-local harness-voice-output--catalogue nil
  "The last `speech/voices' answer this page took in, or nil.")

(defvar-local harness-voice-output--catalogue-generation 0
  "Bumped when an answer about another service could no longer be true.")

;;;; What the selected provider can do

(defun harness-voice-output-capability (&optional provider)
  "Return what the client knows about the output voice of PROVIDER.
PROVIDER defaults to `harness-voice-provider'.  The answer is a plist:

  :kind          `service' (a speech service reports its voices),
                 `provider' (the provider's own server defines the
                 voice, and this client has no catalogue for it) or
                 `none' (the provider has no voice to choose)
  :audition      non-nil when the page can play a preview
  :voice-option  the client option the saved voice is kept in, or nil
  :label         the provider, as the page names it
  :reason        why there is nothing to choose, when there is nothing

A provider this client does not know has no output settings, rather
than a list of defaults that would send audio nowhere."
  (let* ((provider (or provider harness-voice-provider))
         (record (harness-voice-provider-get provider)))
    (cond
     ((null record)
      (list :kind 'none :audition nil :voice-option nil
            :label (format "%s" provider)
            :reason "Unknown voice provider"))
     ((eq provider 'unmute)
      (list :kind 'service :audition t
            :voice-option 'harness-voice-unmute-voice
            :label (harness-voice-provider-label provider)))
     ((eq provider 'chatgpt)
      (list :kind 'provider :audition nil
            :voice-option 'harness-voice-chatgpt-voice
            :label (harness-voice-provider-label provider)
            :reason "Audition unavailable · provider-managed voice"))
     ((eq provider 'wav)
      (list :kind 'none :audition nil :voice-option nil
            :label (harness-voice-provider-label provider)
            :reason "Device voice · no catalogue"))
     ((eq provider 'custom)
      (list :kind 'none :audition nil :voice-option nil
            :label (harness-voice-provider-label provider)
            :reason "Sidecar voice · no catalogue"))
     ((eq provider 'fixture)
      (list :kind 'none :audition nil :voice-option nil
            :label (harness-voice-provider-label provider)
            :reason "Scripted fixture · no catalogue"))
     (t
      (list :kind 'none :audition nil :voice-option nil
            :label (harness-voice-provider-label provider)
            :reason "Voice catalogue unavailable")))))

;;;; The catalogue

(defun harness-voice-output--catalogue-state ()
  "Return the last catalogue's state as a symbol, or nil.
The harness sends it as a string over ACP, and a page a test drives may
hold it as a symbol already; both read the same here."
  (let ((state (plist-get harness-voice-output--catalogue :state)))
    (cond ((null state) nil)
          ((symbolp state) state)
          (t (intern (format "%s" state))))))

(defun harness-voice-output--catalogue-voices ()
  "Return the voices of the last catalogue, as a list of plists."
  (append (plist-get harness-voice-output--catalogue :voices) nil))

(defun harness-voice-output--catalogue-parameters ()
  "Return the parameters of the last catalogue, as a list of plists."
  (append (plist-get harness-voice-output--catalogue :parameters) nil))

(defun harness-voice-output--voice-entry (name)
  "Return the catalogue entry of voice NAME, or nil."
  (cl-find name (harness-voice-output--catalogue-voices)
           :key (lambda (v) (plist-get v :id)) :test #'equal))

(defun harness-voice-output-voice-label (name)
  "Return the label of voice NAME: its catalogue label, or the name."
  (let ((entry (and name (harness-voice-output--voice-entry name))))
    (or (and entry (plist-get entry :label)) name)))

(defun harness-voice-output-parameter (key &optional parameters)
  "Return the declaration of parameter KEY among PARAMETERS, or nil."
  (let ((parameters (or parameters (harness-voice-output--catalogue-parameters))))
    (cl-find (format "%s" key) parameters
             :key (lambda (p) (plist-get p :key)) :test #'equal)))

(defun harness-voice-output-parameter-effective (key &optional parameters)
  "Return the drafted value of parameter KEY, else its declared default.
PARAMETERS defaults to the drafted alist; the declaration gives the
default when nothing was drafted, so the page always shows a value."
  (let* ((parameters (or parameters (and (boundp 'harness-voice-output--draft-parameters)
                                          harness-voice-output--draft-parameters)))
         (pair (and parameters (assoc (format "%s" key) parameters)))
         (decl (harness-voice-output-parameter key)))
    (cond (pair (cdr pair))
          (decl (plist-get decl :default))
          (t nil))))

;;;; Saved and effective settings

(defun harness-voice-output-saved-voice (&optional capability)
  "Return the saved voice of CAPABILITY, and where it came from.
The answer is (:value NAME :source policy|saved|default); NAME is nil
when nothing is set, and the page says the service's own default."
  (let* ((capability (or capability (harness-voice-output-capability)))
         (option (plist-get capability :voice-option)))
    (if (null option)
        (list :value nil :source 'default)
      (let ((value (and (boundp option) (symbol-value option))))
        (list :value (and (stringp value) (not (string-empty-p (string-trim value)))
                          (string-trim value))
              :source (cond ((and (fboundp 'harness-policy-pinned-p)
                                  (harness-policy-pinned-p option))
                             'policy)
                            ((get option 'saved-value) 'saved)
                            (t 'default)))))))

(defun harness-voice-output-saved-parameters (&optional capability)
  "Return the saved parameters of CAPABILITY, as an alist.
Only the parameters the selected service declares are returned: a key
saved from another service is not sent to this one, and the page names
it as set aside instead of keeping a setting that does nothing."
  (let ((saved (and (boundp 'harness-voice-unmute-parameters)
                    harness-voice-unmute-parameters))
        (declared (and (eq (plist-get (or capability (harness-voice-output-capability))
                                      :kind)
                           'service)
                       (harness-voice-output--catalogue-parameters))))
    (cl-loop for pair in saved
             for name = (format "%s" (car pair))
             for decl = (and declared
                             (cl-find name declared
                                      :key (lambda (p) (plist-get p :key)) :test #'equal))
             when (and decl (numberp (cdr pair))) collect (cons name (cdr pair)))))

(defun harness-voice-output--set-aside-parameters (&optional capability)
  "Return the saved parameter names CAPABILITY's service does not declare."
  (let ((saved (and (boundp 'harness-voice-unmute-parameters)
                    harness-voice-unmute-parameters))
        (declared (and (eq (plist-get (or capability (harness-voice-output-capability))
                                      :kind)
                           'service)
                       (harness-voice-output--catalogue-parameters))))
    (cl-loop for pair in saved
             for name = (format "%s" (car pair))
             unless (and declared (harness-voice-output-parameter name declared))
             collect name)))

;;;; The draft

(defun harness-voice-output--draft (&optional capability)
  "Return the draft of the page for CAPABILITY, as a plist.
`:voice' and `:parameters' are what the page would audition and save,
`:saved-voice' and `:saved-parameters' what is saved, and `:changed' is
true when the two differ, which is what `Unsaved changes' follows."
  (let* ((capability (or capability (harness-voice-output-capability)))
         (saved (harness-voice-output-saved-voice capability))
         (saved-params (harness-voice-output-saved-parameters capability))
         (voice (or (and (boundp 'harness-voice-output--draft-voice)
                         harness-voice-output--draft-voice)
                    (plist-get saved :value)))
         (drafted (and (boundp 'harness-voice-output--draft-parameters)
                       harness-voice-output--draft-parameters))
         (parameters (or drafted saved-params)))
    (list :voice voice
          :parameters (append parameters nil)
          :saved-voice (plist-get saved :value)
          :saved-source (plist-get saved :source)
          :saved-parameters saved-params
          :changed (or (not (equal voice (plist-get saved :value)))
                       (not (equal (harness-voice-output--effective-parameters parameters)
                                   (harness-voice-output--effective-parameters saved-params)))))))

(defun harness-voice-output--effective-parameters (parameters)
  "Return PARAMETERS without the ones equal to their defaults.
A value left at its default is not a change: `Unsaved changes' does not
count it, and the service is not sent it."
  (cl-loop for (key . value) in parameters
           for decl = (harness-voice-output-parameter key)
           unless (and decl (equal value (plist-get decl :default)))
           collect (cons key value)))

;;;; Validation

(defun harness-voice-output-validate (voice parameters &optional capability)
  "Return nil when VOICE and PARAMETERS may be auditioned or saved, else why not.
A key the service does not declare, a value that is not a finite
number, and a value outside its declared range are refused in the
page's words (`Speed · 5.00 outside 0.25–4.00').  A service that
declares no parameters refuses every parameter.  A voice the service
did not report is accepted: a service of your own may know a voice it
does not list, and the page says so instead of hiding it."
  (let ((capability (or capability (harness-voice-output-capability)))
        (declared (harness-voice-output--catalogue-parameters)))
    (cond
     ((eq (plist-get capability :kind) 'none) "Output voice unsupported")
     ((and (stringp voice) (string-match-p "\n" voice)) "Voice · one line")
     (t (cl-loop for (key . value) in parameters
                 for decl = (harness-voice-output-parameter key declared)
                 when (null decl)
                 return (format "Parameter unsupported · %s" key)
                 when (not (numberp value))
                 return (format "%s · not a number"
                                (or (plist-get decl :label) key))
                 when (not (and (<= (plist-get decl :min) value)
                                (<= value (plist-get decl :max))))
                 return (format "%s · %s outside %s–%s"
                                (or (plist-get decl :label) key)
                                (format "%.2f" value)
                                (format "%.2f" (plist-get decl :min))
                                (format "%.2f" (plist-get decl :max)))
                 finally return nil)))))

;;;; Saving

(defun harness-voice-output-save (&optional voice parameters capability)
  "Save VOICE and PARAMETERS as CAPABILITY's output settings.
The values are validated first, so an unsupported parameter or a value
outside its range is refused before anything changes.  A parameter left
at its default is not saved, and a running live session is restarted
because its sidecar was started with the old argv.  Return the values
saved, as (VOICE PARAMETERS)."
  (let* ((capability (or capability (harness-voice-output-capability)))
         (draft (harness-voice-output--draft capability))
         (parameters (or parameters (plist-get draft :parameters)))
         (voice (or voice (plist-get draft :voice)))
         (problem (harness-voice-output-validate voice parameters capability)))
    (when problem (user-error "%s" problem))
    (let ((option (plist-get capability :voice-option)))
      (cond
       ((eq (plist-get capability :kind) 'service)
        (harness-voice--save-choice 'harness-voice-unmute-voice (or voice ""))
        (harness-voice--save-choice
         'harness-voice-unmute-parameters
         (harness-voice-output--effective-parameters parameters)))
       ((and option (stringp voice) (not (string-empty-p voice)))
        (harness-voice--save-choice option voice))))
    (harness-voice-output--restart-live-session)
    (list voice parameters)))

(defun harness-voice-output--restart-live-session ()
  "Restart a running live session so its sidecar gets the saved argv.
A sidecar was started with the voice and parameters it spoke with, so a
saved change takes effect at its next start; the call ends here, as
`harness-voice-select-provider' ends one, and [Start] begins the next."
  (when (and (fboundp 'harness-voice-live--active-p)
             (harness-voice-live--active-p))
    (when (fboundp 'harness-voice-live-stop) (harness-voice-live-stop))))

;;;; The audition

(defvar harness-voice-output--audition-generation 0
  "Bumped for every audition, so a late answer can tell it is stale.")

(cl-defstruct (harness-voice-output--preview
               (:constructor harness-voice-output--preview-make)
               (:copier nil))
  "One audition of the page's draft, and what it needs to be stopped.
A struct rather than a plist: the page holds this object, a timer, a
process sentinel and a late answer all compare themselves against it by
identity, and `setf' on a plist slot would leave them comparing a copy
that is no longer the page's."
  (state 'loading)
  voice
  parameters
  player
  dir
  generation
  timer
  process
  ;; The page this audition belongs to.  A connection delivers its answer
  ;; with whatever buffer is current, and every value here is
  ;; buffer-local, so a callback must select the page before it acts.
  page)

(defun harness-voice-output-state ()
  "Return the page's audition state: idle, loading, playing, stopped or failed."
  (let ((preview (and (boundp 'harness-voice-output--audition)
                      harness-voice-output--audition)))
    (if preview (harness-voice-output--preview-state preview) 'idle)))

(defun harness-voice-output--audition-stale-p (preview)
  "Non-nil when PREVIEW is no longer the audition its page follows."
  (let ((page (harness-voice-output--preview-page preview)))
    (or (not (buffer-live-p page))
        (not (with-current-buffer page
               (and (derived-mode-p 'harness-voice-output-mode)
                    (eq preview harness-voice-output--audition)))))))

(defun harness-voice-output--with-preview (preview function)
  "Call FUNCTION in PREVIEW's page, unless PREVIEW is stale.
FUNCTION runs with PREVIEW's page current and the page's state around
it; nothing runs at all for an audition the page has replaced, or for a
page that is gone."
  (let ((page (harness-voice-output--preview-page preview)))
    (when (and (buffer-live-p page)
               (not (harness-voice-output--audition-stale-p preview)))
      (with-current-buffer page
        (when (eq preview harness-voice-output--audition)
          (funcall function))))))

(defun harness-voice-output--discard-audio (preview)
  "Delete the private directory PREVIEW wrote its WAV in, and forget it."
  (let ((dir (harness-voice-output--preview-dir preview)))
    (when (and dir (file-directory-p dir))
      (ignore-errors (delete-directory dir t)))
    (setf (harness-voice-output--preview-dir preview) nil)))

(defun harness-voice-output--stop-audition (&optional reason)
  "Stop the audition in flight, discarding its audio, and mark REASON.
REASON `stopped' shows `Stopped'; nil leaves the page `Idle'.  A
callback still to come from the stopped audition is refused by
`harness-voice-output--audition-stale-p'.  The request already sent
cannot be withdrawn from the harness, so its answer is dropped instead
of played."
  (let ((preview (and (boundp 'harness-voice-output--audition)
                      harness-voice-output--audition)))
    (when preview
      (let ((timer (harness-voice-output--preview-timer preview))
            (proc (harness-voice-output--preview-process preview)))
        (when (timerp timer) (cancel-timer timer))
        (when (process-live-p proc)
          (set-process-sentinel proc #'ignore)
          (delete-process proc))
        (harness-voice-output--discard-audio preview)
        (setf (harness-voice-output--preview-process preview) nil
              (harness-voice-output--preview-timer preview) nil
              (harness-voice-output--preview-state preview) (or reason 'idle)))))
  (setq harness-voice-output--audition-generation
        (1+ harness-voice-output--audition-generation)))

(defun harness-voice-output-stop ()
  "Stop the audition now, keeping what the page has drafted."
  (interactive)
  (harness-voice-output--stop-audition 'stopped)
  (harness-voice-output--refresh))

(defun harness-voice-output--audition-player ()
  "Return the argv list of this machine's player, or nil."
  (condition-case nil
      (if (fboundp 'harness-voice--player)
          (harness-voice--player "audition.wav")
        (when-let* ((program (and (fboundp 'harness-ui-media--player-program)
                                  (harness-ui-media--player-program))))
          (harness-ui-media--player-command program "audition.wav")))
    (error nil)))

(defun harness-voice-output--service-stopped-p ()
  "Non-nil when the harness reports no speech service to ask.
A pipeline that runs, one still starting, and one nobody has checked
yet are all asked: the request is what says whether a voice can be
spoken, and its own refusal is what the page shows.  Only a pipeline
the harness reports down with no address behind it is refused before a
request, since nothing would answer one."
  (let ((status (harness-voice-pipeline-status-cached)))
    (and (member (plist-get status :state) '("stopped" "error"))
         (null (plist-get status :tts-url)))))

(defun harness-voice-output--audition-available-p (capability)
  "Non-nil when CAPABILITY can be auditioned now."
  (and (plist-get capability :audition)
       (not (harness-voice-output--service-stopped-p))))

(defun harness-voice-output--params-json (parameters)
  "Return PARAMETERS as the object the harness takes, or nil."
  (when parameters
    (apply #'append
           (mapcar (lambda (pair) (list (intern (concat ":" (car pair))) (cdr pair)))
                   parameters))))

(defun harness-voice-output--synthesize (voice parameters on-ok on-error)
  "Ask the harness to say the audition text in VOICE with PARAMETERS.
ON-OK receives the base64 WAV; ON-ERROR a one-line reason.  The call is
`speech/synthesize' over ACP: it sends no prompt, writes no transcript,
and a connection replaced on purpose is not a failure."
  (harness-ui-call
   "_harness/speech/synthesize"
   (append (list :text harness-voice-output-audition-text)
           (when (and voice (not (string-empty-p voice))) (list :voice voice))
           (when parameters (list :params (harness-voice-output--params-json parameters))))
   (lambda (result)
     (let ((audio (plist-get result :audio)))
       (if (and (stringp audio) (not (string-empty-p audio)))
           (funcall on-ok audio)
         (funcall on-error "Audition · no audio"))))
   (lambda (err)
     (unless (harness-ui-connection-replaced-p err)
       (funcall on-error (harness-error-message err))))))

(defun harness-voice-output--play (preview audio)
  "Play AUDIO, a base64 WAV, for PREVIEW and follow its player.
The player is an external program with the WAV in PREVIEW's private
directory, so [Stop] ends it and the file goes when it does."
  (let* ((dir (harness-voice-output--preview-dir preview))
         (file (expand-file-name "audition.wav" dir))
         (player (harness-voice-output--preview-player preview)))
    (condition-case err
        (progn
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (base64-decode-string audio))
            (write-region (point-min) (point-max) file nil 'silent))
          (setf (harness-voice-output--preview-state preview) 'playing)
          (let ((process
                 (make-process
                  :name "harness-voice-audition"
                  :command (mapcar (lambda (arg)
                                     (if (equal arg "audition.wav") file arg))
                                   player)
                  :connection-type 'pipe :coding 'binary :noquery t
                  :buffer nil
                  :sentinel
                  (lambda (proc _event)
                    (when (memq (process-status proc) '(exit signal))
                      (harness-voice-output--with-preview
                       preview
                       (lambda ()
                         (when (eq proc
                                   (harness-voice-output--preview-process preview))
                           (setf (harness-voice-output--preview-process preview) nil)
                           (unless (eq (harness-voice-output--preview-state preview)
                                       'stopped)
                             (setf (harness-voice-output--preview-state preview)
                                   'stopped))
                           ;; The player has read the file; the audio of a
                           ;; preview that has been heard is not kept.
                           (harness-voice-output--discard-audio preview)
                           (harness-voice-output--refresh)))))))))
            (setf (harness-voice-output--preview-process preview) process)))
      (error
       (setf (harness-voice-output--preview-state preview) 'failed)
       (setq harness-voice-output--error
             (harness-ui-one-line (error-message-string err)))))
    (harness-voice-output--refresh)))

(defun harness-voice-output--timeout (preview)
  "Fail PREVIEW, which outlived `harness-voice-output-audition-timeout'."
  (harness-voice-output--with-preview
   preview
   (lambda ()
     (when (memq (harness-voice-output--preview-state preview) '(loading playing))
       (harness-voice-output--stop-audition)
       (setf (harness-voice-output--preview-state preview) 'failed)
       (setq harness-voice-output--error "Audition · timeout")
       (harness-voice-output--refresh)))))

(defun harness-voice-output-audition (&optional voice parameters)
  "Audition the drafted VOICE with PARAMETERS, without saving either.
VOICE and PARAMETERS default to the draft, so a change not yet saved is
heard.  One audition runs at a time: another replaces this one, and an
answer that still comes from the old one cannot change the page or
play.  The draft is validated first, so a value outside its range is
named instead of sent.  Return the page's audition record, which the
page follows by identity."
  (interactive)
  (let* ((capability (harness-voice-output-capability))
         (draft (harness-voice-output--draft capability))
         (voice (or voice (plist-get draft :voice)))
         (parameters (or parameters (plist-get draft :parameters)))
         (problem (harness-voice-output-validate voice parameters capability)))
    (cond
     ((not (plist-get capability :audition))
      (user-error "%s" (or (plist-get capability :reason) "Audition unavailable")))
     ((not (harness-voice-output--audition-available-p capability))
      (user-error "Audition unavailable · local voice pipeline stopped"))
     (problem (user-error "%s" problem)))
    (unless (harness-voice-output--audition-player)
      (user-error "Voice player unavailable · mpv, pw-play, ffplay or paplay"))
    (harness-voice-output--stop-audition)
    (let* ((generation (1+ harness-voice-output--audition-generation))
           (preview (harness-voice-output--preview-make
                     :state 'loading :voice voice :parameters parameters
                     :player (harness-voice-output--audition-player)
                     :dir (make-temp-file "harness-voice-audition-" t)
                     :generation generation
                     :page (current-buffer))))
      (set-file-modes (harness-voice-output--preview-dir preview) #o700)
      (setq harness-voice-output--audition preview
            harness-voice-output--error nil)
      (setf (harness-voice-output--preview-timer preview)
            (run-at-time harness-voice-output-audition-timeout nil
                         #'harness-voice-output--timeout preview))
      (harness-voice-output--synthesize
       voice
       (harness-voice-output--effective-parameters parameters)
       (lambda (audio)
         (harness-voice-output--with-preview
          preview
          (lambda ()
            (when (timerp (harness-voice-output--preview-timer preview))
              (cancel-timer (harness-voice-output--preview-timer preview))
              (setf (harness-voice-output--preview-timer preview) nil))
            (harness-voice-output--play preview audio))))
       (lambda (reason)
         (harness-voice-output--with-preview
          preview
          (lambda ()
            (when (timerp (harness-voice-output--preview-timer preview))
              (cancel-timer (harness-voice-output--preview-timer preview))
              (setf (harness-voice-output--preview-timer preview) nil))
            (setf (harness-voice-output--preview-state preview) 'failed)
            (setq harness-voice-output--error reason)
            (harness-voice-output--refresh)))))
      (harness-voice-output--refresh)
      preview)))

;;;; Rendering

;; Copy: a heading is a noun phrase, a row is a label and its value, a
;; state is one word.  No row explains itself in a sentence; the tooltip
;; and `harness-voice-output--doc' carry the explanation.

(defconst harness-voice-output--copy
  '((title . "Output voice")
    (provider . "Provider")
    (voice . "Voice")
    (voices . "Voices")
    (parameters . "Parameters")
    (effective . "Effective")
    (audition . "[Audition]")
    (save . "[Save]")
    (revert . "[Revert]")
    (stop . "[Stop]")
    (retry . "[Retry]")
    (refresh . "[Refresh]")
    (changed . "Unsaved changes")
    (selected . "selected")
    (service-default . "Service default")
    (provider-default . "Provider default")
    (unavailable . "Unavailable")
    (saved . "saved")
    (default . "default")
    (policy . "policy")
    (loading-voices . "Loading voices")
    (loading-parameters . "Loading parameters")
    (no-voices . "No voices")
    (no-parameters . "No parameters declared")
    (set-aside . "Set aside")
    (not-in-list . "Not in list")
    (provider-managed . "Provider-managed voice · audition unavailable")
    (state-idle . "Idle")
    (state-loading . "Loading")
    (state-playing . "Playing")
    (state-stopped . "Stopped")
    (state-failed . "Failed"))
  "The page's words, so a test reads the copy from one place.
Every heading, row, state and note the page renders has an entry here,
and the tests assert each of them exactly as it is drawn.")

(defconst harness-voice-output--indent "  "
  "The margin of every row of the page.
A block's rows share it, so the label column lines up down the page.")

(defun harness-voice-output--copy-word (key)
  "Return the word KEY of the page's copy."
  (alist-get key harness-voice-output--copy))

(defun harness-voice-output--button (label action help &optional face)
  "Return a button string LABEL running ACTION, with tooltip HELP."
  (harness-ui-string-action
   (propertize label 'face (or face 'button) 'help-echo help)
   action))

(defun harness-voice-output--labelled (label text)
  "Return the page row naming LABEL with TEXT after it.
The label sits in the column every labelled row of the page shares."
  (format "%-9s %s" label text))

(defun harness-voice-output--dim (text)
  "Return TEXT in the face of a note rather than a value."
  (propertize text 'face 'harness-dim-face))

(defun harness-voice-output--state-word (preview)
  "Return the state word and face of PREVIEW."
  (pcase (if preview (harness-voice-output--preview-state preview) 'idle)
    ('loading (cons (harness-voice-output--copy-word 'state-loading)
                    'harness-caution-face))
    ('playing (cons (harness-voice-output--copy-word 'state-playing)
                    'harness-success-face))
    ('stopped (cons (harness-voice-output--copy-word 'state-stopped)
                    'harness-label-face))
    ('failed (cons (harness-voice-output--copy-word 'state-failed)
                   'harness-failure-face))
    (_ (cons (harness-voice-output--copy-word 'state-idle) 'harness-dim-face))))

(defun harness-voice-output--source-word (source)
  "Return the word for where a saved value comes from, SOURCE."
  (pcase source
    ('policy (harness-voice-output--copy-word 'policy))
    ('saved (harness-voice-output--copy-word 'saved))
    (_ (harness-voice-output--copy-word 'default))))

(defun harness-voice-output--page ()
  "Return the page's text for the current draft and catalogue.
Sections follow one another with a blank line between them; a section's
own rows stay together, the label column lining up down the section."
  (let* ((capability (harness-voice-output-capability))
         (draft (harness-voice-output--draft capability))
         (sections nil))
    (push (list (propertize (harness-voice-output--copy-word 'title)
                            'face 'harness-label-face)) sections)
    (push (list (harness-voice-output--labelled
                 (harness-voice-output--copy-word 'provider)
                 (plist-get capability :label)))
          sections)
    (pcase (plist-get capability :kind)
      ('service
       (setq sections
             (append (nreverse (harness-voice-output--service-sections draft))
                     sections)))
      ('provider
       (push (list (harness-voice-output--labelled
                    (harness-voice-output--copy-word 'voice)
                    (or (plist-get draft :voice)
                        (harness-voice-output--copy-word 'service-default)))
                   (harness-voice-output--dim
                    (harness-voice-output--copy-word 'provider-managed)))
             sections))
      (_
       (push (list (harness-voice-output--dim
                    (or (plist-get capability :reason)
                        (harness-voice-output--copy-word 'unavailable))))
             sections)))
    (when (plist-get capability :voice-option)
      (push (list (harness-voice-output--effective-line draft capability)) sections))
    (when (harness-voice-output--audition-available-p capability)
      (push (list (harness-voice-output--audition-line
                   harness-voice-output--audition))
            sections))
    (push (list (harness-voice-output--controls
                 draft harness-voice-output--audition capability))
          sections)
    (when harness-voice-output--notice
      (push (list (propertize harness-voice-output--notice 'face 'harness-caution-face))
            sections))
    (when harness-voice-output--error
      (push (list (propertize harness-voice-output--error 'face 'harness-failure-face))
            sections))
    (let ((lines nil))
      (dolist (section (nreverse sections))
        (unless (null section)
          (when lines (push "" lines))
          (dolist (line section)
            (push (harness-voice-output--indent-block line) lines))))
      (concat (string-join (nreverse lines) "\n") "\n"))))

(defun harness-voice-output--indent-block (line)
  "Return LINE, a row or heading of the page, with the page's margin."
  (if (string-empty-p line)
      ""
    (concat harness-voice-output--indent line)))

(defun harness-voice-output--service-sections (draft)
  "Return the service's rows for DRAFT as sections: voices, then parameters.
Each section is a list of rows; the page puts the margin on and the
blank line between them."
  (let ((catalogue harness-voice-output--catalogue)
        (voices (harness-voice-output--catalogue-voices))
        (parameters (harness-voice-output--catalogue-parameters))
        (lines nil))
    (push (harness-voice-output--copy-word 'voices) lines)
    (cond
     ((null catalogue)
      (push (harness-voice-output--dim
             (harness-voice-output--copy-word 'loading-voices))
            lines))
     ((eq (harness-voice-output--catalogue-state) 'running)
      (if voices
          (dolist (voice voices)
            (let ((id (plist-get voice :id))
                  (current (equal (plist-get voice :id) (plist-get draft :voice))))
              (push (concat (propertize (if current "●" "○")
                                        'face (if current 'harness-success-face
                                                'harness-label-face))
                            " "
                            (harness-voice-output--button
                             (plist-get voice :label)
                             (lambda () (harness-voice-output-select-voice id))
                             (format "Voice · %s" id)
                             (if current 'harness-label-face 'default))
                            (if current
                                (propertize
                                 (concat "  " (harness-voice-output--copy-word 'selected))
                                 'face 'harness-label-face)
                              ""))
                    lines)))
        (push (harness-voice-output--dim
               (harness-voice-output--copy-word 'no-voices))
              lines)))
     (t
      (push (propertize (or (plist-get catalogue :reason)
                            (harness-voice-output--copy-word 'unavailable))
                        'face 'harness-failure-face)
            lines)))
    (let ((parameter-lines (list (harness-voice-output--copy-word 'parameters))))
      (cond
       ((null catalogue)
        (push (harness-voice-output--dim
               (harness-voice-output--copy-word 'loading-parameters))
              parameter-lines))
       (parameters
        (dolist (decl parameters)
          (push (harness-voice-output--parameter-line decl) parameter-lines)))
       (t
        (push (harness-voice-output--dim
               (harness-voice-output--copy-word 'no-parameters))
              parameter-lines)))
      (let ((set-aside (harness-voice-output--set-aside-parameters)))
        (when set-aside
          (push (propertize
                 (format "%s · %s"
                         (harness-voice-output--copy-word 'set-aside)
                         (string-join set-aside ", "))
                 'face 'harness-caution-face)
                parameter-lines)))
      (list (nreverse lines) (nreverse parameter-lines)))))

(defun harness-voice-output--parameter-line (decl)
  "Return the page row of DECL, a parameter, with its drafted value."
  (let* ((key (plist-get decl :key))
         (value (harness-voice-output-parameter-effective key))
         (step (or (plist-get decl :step) 0.05))
         (unit (or (plist-get decl :unit) "")))
    (concat (propertize (format "%-9s" (plist-get decl :label))
                        'face 'harness-label-face)
            (harness-voice-output--button
             "−" (lambda () (harness-voice-output-adjust key (- step)))
             (format "%s · lower" (plist-get decl :label)))
            " "
            (propertize (format "%.2f%s" value unit)
                        'face 'default
                        'help-echo (plist-get decl :doc))
            " "
            (harness-voice-output--button
             "+" (lambda () (harness-voice-output-adjust key step))
             (format "%s · higher" (plist-get decl :label)))
            "  "
            (harness-voice-output--dim
             (format "%s–%s · default %s"
                     (format "%.2f" (plist-get decl :min))
                     (format "%.2f" (plist-get decl :max))
                     (format "%.2f" (plist-get decl :default)))))))

(defun harness-voice-output--effective-line (draft _capability)
  "Return the row naming what speaks the next reply, for DRAFT.
It shows the saved voice and the saved parameters that apply to this
service, and where the voice comes from: `policy', `saved' or `default'."
  (let* ((voice (plist-get draft :saved-voice))
         (source (harness-voice-output--source-word (plist-get draft :saved-source)))
         (label (if voice (harness-voice-output-voice-label voice)
                  (harness-voice-output--copy-word 'service-default)))
         (parameters (harness-voice-output--effective-parameters
                      (plist-get draft :saved-parameters)))
         (figures (mapconcat (lambda (pair)
                               (let ((decl (harness-voice-output-parameter (car pair))))
                                 (format "%s %s%s"
                                         (or (plist-get decl :label) (car pair))
                                         (format "%.2f" (cdr pair))
                                         (or (plist-get decl :unit) ""))))
                             parameters " · ")))
    (harness-voice-output--labelled
     (harness-voice-output--copy-word 'effective)
     (concat label
             (if (string-empty-p figures) "" (concat " · " figures))
             " · " source))))

(defun harness-voice-output--audition-line (preview)
  "Return the status row of PREVIEW, or the idle one."
  (let* ((state (harness-voice-output--state-word preview))
         (voice (and preview (harness-voice-output--preview-voice preview)))
         (shown (memq (if preview (harness-voice-output--preview-state preview) 'idle)
                      '(loading playing stopped failed))))
    (concat (propertize (car state) 'face (cdr state))
            (if (and shown voice)
                (format " · %s" (harness-voice-output-voice-label voice))
              ""))))

(defun harness-voice-output--controls (draft preview capability)
  "Return the controls row of the page for DRAFT, PREVIEW and CAPABILITY.
Only the controls that do something for this provider are drawn: an
audition needs a service that can speak a chosen voice, Save and Revert
need a client option that keeps one, and Refresh needs a catalogue."
  (let* ((available (harness-voice-output--audition-available-p capability))
         (state (if preview (harness-voice-output--preview-state preview) 'idle))
         (buttons nil))
    (when available
      (if (memq state '(loading playing))
          (push (harness-voice-output--button
                 (harness-voice-output--copy-word 'stop)
                 #'harness-voice-output-stop "Audition · stop")
                buttons)
        (push (harness-voice-output--button
               (if (eq state 'failed)
                   (harness-voice-output--copy-word 'retry)
                 (harness-voice-output--copy-word 'audition))
               #'harness-voice-output-audition
               "Audition · current draft, not saved")
              buttons)))
    (when (plist-get capability :voice-option)
      (push (harness-voice-output--button
             (harness-voice-output--copy-word 'save)
             #'harness-voice-output-save-and-close "Output voice · save")
            buttons)
      (push (harness-voice-output--button
             (harness-voice-output--copy-word 'revert)
             #'harness-voice-output-revert "Output voice · revert")
            buttons))
    (when (eq (plist-get capability :kind) 'service)
      (push (harness-voice-output--button
             (harness-voice-output--copy-word 'refresh)
             #'harness-voice-output-refresh "Voice list · ask again")
            buttons))
    (concat (string-join (nreverse buttons) "  ")
            (if (plist-get draft :changed)
                (propertize
                 (concat "  " (harness-voice-output--copy-word 'changed))
                 'face 'harness-caution-face)
              ""))))

(defun harness-voice-output--refresh ()
  "Redraw every output voice page that is on screen."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'harness-voice-output-mode)
        (harness-voice-output--render)))))

(defun harness-voice-output--render ()
  "Draw the page in the current buffer, keeping point and window starts."
  (let ((inhibit-read-only t))
    (harness-ui-replace-region (point-min) (point-max)
                               (harness-voice-output--page))))


;;;; Choosing and changing

(defun harness-voice-output-select-voice (voice)
  "Draft VOICE for audition and saving, cancelling any audition in flight."
  (interactive
   (list (let* ((voices (harness-voice-output--catalogue-voices))
                (choices (mapcar (lambda (v)
                                   (cons (plist-get v :label) (plist-get v :id)))
                                 voices)))
           (cdr (assoc (completing-read "Output voice: " choices nil t) choices)))))
  (unless (stringp voice)
    (user-error "Voice unset"))
  (setq harness-voice-output--draft-voice voice
        harness-voice-output--error nil
        harness-voice-output--notice nil)
  (harness-voice-output--stop-audition)
  (harness-voice-output--refresh))

(defun harness-voice-output-adjust (key delta)
  "Change parameter KEY in the draft by DELTA, within its declared range."
  (interactive
   (list (let ((keys (mapcar (lambda (p) (plist-get p :key))
                             (harness-voice-output--catalogue-parameters))))
           (completing-read "Parameter: " keys nil t))
         (read-number "Change by: ")))
  (let ((decl (harness-voice-output-parameter key))
        (current (harness-voice-output-parameter-effective key)))
    (unless decl
      (user-error "Parameter unsupported · %s" key))
    (let* ((next (min (plist-get decl :max)
                      (max (plist-get decl :min)
                           (/ (round (* 100 (+ current delta))) 100.0))))
           (drafted (or (and (boundp 'harness-voice-output--draft-parameters)
                             harness-voice-output--draft-parameters)
                        (harness-voice-output-saved-parameters))))
      (setq harness-voice-output--draft-parameters
            (cons (cons key next) (assoc-delete-all key drafted))
            harness-voice-output--error nil)
      (harness-voice-output--stop-audition)
      (harness-voice-output--refresh))))

(defun harness-voice-output-set-parameter (key value)
  "Draft parameter KEY as VALUE, for a typed value and for tests."
  (interactive
   (list (completing-read "Parameter: "
                          (mapcar (lambda (p) (plist-get p :key))
                                  (harness-voice-output--catalogue-parameters))
                          nil t)
         (read-number "Value: ")))
  (let ((decl (harness-voice-output-parameter key)))
    (unless decl (user-error "Parameter unsupported · %s" key))
    (setq harness-voice-output--draft-parameters
          (cons (cons key value)
                (assoc-delete-all key (or (and (boundp 'harness-voice-output--draft-parameters)
                                               harness-voice-output--draft-parameters)
                                          (harness-voice-output-saved-parameters))))
          harness-voice-output--error nil)
    (harness-voice-output--stop-audition)
    (harness-voice-output--refresh)))

(defun harness-voice-output-save-and-close ()
  "Save the page's draft as the output voice, then say so.
Cancel, Revert and closing the page leave the saved value alone; this
is the page's only control that changes it."
  (interactive)
  (let ((problem (harness-voice-output-validate
                  (and (boundp 'harness-voice-output--draft-voice)
                       harness-voice-output--draft-voice)
                  (and (boundp 'harness-voice-output--draft-parameters)
                       harness-voice-output--draft-parameters))))
    (cond
     (problem (setq harness-voice-output--error problem)
              (harness-voice-output--refresh)
              (user-error "%s" problem))
     (t
      (condition-case err
          (progn
            (harness-voice-output-save)
            (setq harness-voice-output--draft-voice nil
                  harness-voice-output--draft-parameters nil
                  harness-voice-output--error nil
                  harness-voice-output--notice nil)
            (harness-voice-output--stop-audition)
            (harness-voice-setup--refresh)
            (harness-voice-output--refresh)
            (let ((saved (harness-voice-output-saved-voice)))
              (message "Output voice · %s"
                       (if (plist-get saved :value)
                           (harness-voice-output-voice-label (plist-get saved :value))
                         (harness-voice-output--copy-word 'service-default)))))
        (user-error
         (setq harness-voice-output--error (error-message-string err))
         (harness-voice-output--refresh)
         (message "%s" (error-message-string err))))))))

(defun harness-voice-output-revert ()
  "Drop the page's draft and show the saved output voice again."
  (interactive)
  (setq harness-voice-output--draft-voice nil
        harness-voice-output--draft-parameters nil
        harness-voice-output--error nil
        harness-voice-output--notice nil)
  (harness-voice-output--stop-audition)
  (harness-voice-output--refresh)
  (message "Output voice · reverted"))

(defun harness-voice-output-refresh ()
  "Ask the harness for the service's voices and parameters again."
  (interactive)
  (harness-voice-output-fetch t)
  (harness-voice-output--refresh))

(defun harness-voice-output-fetch (&optional refresh)
  "Ask the harness for the voices of its speech service.
REFRESH asks the service itself rather than the harness's own answer
kept for a minute.  The answer is drawn when it arrives; an answer from
before the pipeline moved, or for a page that is gone, changes nothing.

The answer is put in the buffer that asked: the page's state is
buffer-local, and a connection delivers its answer with whatever buffer
is current, so the callback selects this page's own buffer first."
  (interactive)
  (let ((buffer (current-buffer))
        (generation harness-voice-output--catalogue-generation))
    (harness-ui-call
     "_harness/speech/voices"
     (when refresh (list :refresh t))
     (lambda (catalogue)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when (equal generation harness-voice-output--catalogue-generation)
             (setq harness-voice-output--catalogue catalogue)
             (harness-voice-output--note-unlisted-voice)
             (harness-voice-output--refresh)))))
     (lambda (err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (unless (harness-ui-connection-replaced-p err)
             (setq harness-voice-output--catalogue
                   (list :state "failed" :voices (vector) :parameters (vector)
                         :reason (format "Voice list unavailable · %s"
                                         (harness-error-message err))))
             (harness-voice-output--refresh))))))))

(defun harness-voice-output--note-unlisted-voice ()
  "Say when the selected or saved voice is not one the service reported.
The choice is kept, not replaced: a service of your own may know a
voice it does not list, and a preview of it is the honest test."
  (let* ((capability (harness-voice-output-capability))
         (saved (plist-get (harness-voice-output-saved-voice capability) :value))
         (draft (and (boundp 'harness-voice-output--draft-voice)
                     harness-voice-output--draft-voice))
         (unlisted (cl-remove-if
                    (lambda (name)
                      (or (null name)
                          (harness-voice-output--voice-entry name)))
                    (list saved draft))))
    (setq harness-voice-output--notice
          (when (and unlisted
                     (eq (harness-voice-output--catalogue-state) 'running)
                     (harness-voice-output--catalogue-voices))
            (format "Not in list · %s" (string-join unlisted ", "))))))

;;;; The buffer

(defvar harness-voice-output-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'harness-voice-output-quit)
    (define-key map (kbd "a") #'harness-voice-output-audition)
    (define-key map (kbd "s") #'harness-voice-output-stop)
    (define-key map (kbd "S") #'harness-voice-output-save-and-close)
    (define-key map (kbd "r") #'harness-voice-output-revert)
    (define-key map (kbd "g") #'harness-voice-output-refresh)
    (define-key map (kbd "c") (lambda () (interactive) (customize-group 'harness-voice)))
    map)
  "Key map of the output voice page.
RET runs the button at point, `a' auditions the draft, `s' stops, `S'
saves, `r' reverts, `g' asks the service again and `q' closes.")

(define-derived-mode harness-voice-output-mode special-mode "Voice output"
  "Mode of the output voice page: voices, their parameters, an audition.
RET on a voice selects it, on a parameter's `−' or `+' changes it, and
on a control runs it.  `a' auditions the draft, `s' stops, `S' saves,
`r' reverts, `g' asks the service again and `q' closes."
  (setq-local mode-line-format '(" Output voice"))
  (add-hook 'kill-buffer-hook #'harness-voice-output--dispose nil t))

(defun harness-voice-output--dispose ()
  "Stop an audition whose page is going away."
  (harness-voice-output--stop-audition))

(defun harness-voice-output-quit ()
  "Stop the audition and close the page."
  (interactive)
  (harness-voice-output--stop-audition)
  (quit-window))

(put 'harness-voice-output-mode 'harness-menu-group
     '("Output voice"
       ["Voice"
        (". a" "Audition" harness-voice-output-audition)
        (". s" "Stop" harness-voice-output-stop)]
       ["Settings"
        (". S" "Save" harness-voice-output-save-and-close)
        (". r" "Revert" harness-voice-output-revert)
        (". g" "Refresh" harness-voice-output-refresh)]))

(defun harness-voice-output ()
  "Show the voices of the selected speech service, and audition one.
The page lists what the service reports, the parameters it declares and
an audition of the current draft; Save keeps the choice, and an
audition never does.  Nothing is sent to a conversation."
  (interactive)
  (let ((buffer (get-buffer-create "*harness voice output*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (harness-voice-output-mode)
        (setq harness-voice-output--draft-voice nil
              harness-voice-output--draft-parameters nil
              harness-voice-output--audition nil
              harness-voice-output--error nil
              harness-voice-output--notice nil
              harness-voice-output--catalogue nil
              harness-voice-output--catalogue-generation
              (1+ harness-voice-output--catalogue-generation))
        (harness-voice-output--render))
      (harness-voice-output-fetch))
    (pop-to-buffer buffer)
    (goto-char (point-min))
    buffer))

;;;; Following the service and the connection

(defun harness-voice-output--on-event (event _args)
  "Drop a catalogue that described a service which has moved.
EVENT is what `harness-ui-event-functions' receive; a `speech/changed'
means the pipeline stopped, started or failed, and its voice list may be
another service's, so every page stops its audition and asks again."
  (when (equal event "speech/changed")
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'harness-voice-output-mode)
          (harness-voice-output--stop-audition)
          (setq harness-voice-output--catalogue nil
                harness-voice-output--catalogue-generation
                (1+ harness-voice-output--catalogue-generation))
          (harness-voice-output-fetch)
          (harness-voice-output--refresh))))))

(defun harness-voice-output--on-redraw ()
  "Discard a preview and a catalogue from a connection that is gone."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'harness-voice-output-mode)
        (harness-voice-output--stop-audition)
        (setq harness-voice-output--catalogue nil
              harness-voice-output--catalogue-generation
              (1+ harness-voice-output--catalogue-generation))
        (harness-voice-output-fetch)))))

(defun harness-voice-output--provider-changed ()
  "Stop a preview of the provider that is no longer selected, and redraw."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'harness-voice-output-mode)
        (harness-voice-output--stop-audition)
        (setq harness-voice-output--draft-voice nil
              harness-voice-output--draft-parameters nil
              harness-voice-output--catalogue nil
              harness-voice-output--catalogue-generation
              (1+ harness-voice-output--catalogue-generation)
              harness-voice-output--error nil
              harness-voice-output--notice nil)
        (harness-voice-output-fetch)
        (harness-voice-output--refresh)))))

(defun harness-voice-output--init ()
  "Wire the output voice page into the voice module."
  (add-hook 'harness-ui-event-functions #'harness-voice-output--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-voice-output--on-redraw))

(provide 'harness-ui-voice-output)
;;; harness-ui-voice-output.el ends here
