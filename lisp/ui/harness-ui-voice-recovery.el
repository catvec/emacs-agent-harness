;;; harness-ui-voice-recovery.el --- Taking back a voice turn cut short  -*- lexical-binding: t; -*-

;;; Commentary:

;; A speech endpoint is not the end of a thought.  The live voice
;; transport submits a transcript as soon as the speech model returns
;; one, and the agent answers it; when the person was merely pausing,
;; that answer answers half a sentence.
;;
;; This module is the decision half of taking that turn back.  It keeps
;; no state of its own beyond the record it is handed: no process, no
;; session, no clock.  `harness-ui-voice-live' arms a record when a voice
;; message is submitted, reports the resumed speech's onset and the
;; first words transcribed from it, and asks what the history the turn
;; left behind allows.  The transport does the stopping, the cancelling,
;; the rewinding and the resubmission through the mechanisms it already
;; has: `session/cancel', `session/set-head' and the pending voice turn
;; that submits once, at the end of the thought.
;;
;; Two rules are the whole of the timing and of the safety:
;;
;; - The window is measured from the submission to the *resumed speech's
;;   onset*, never to its transcript.  Speech to text takes as long as it
;;   takes, and a continuation spoken inside the window must still be
;;   recovered when its words arrive late.  A provider that reports no
;;   onset leaves the transcript's arrival as the only evidence, and the
;;   window then applies to that: a slow transcription may fall outside,
;;   and nothing is recovered.
;; - A rewind moves the head back to the node before the voice message
;;   only when that is provably safe: the message is on the head's path,
;;   nothing was typed after it, and the turn ran no tool at all.  A
;;   rewind cannot undo a tool's side effects, so a turn that ran one
;;   keeps its history and the continuation is appended instead.  The
;;   nodes the rewind leaves behind stay in the session's tree, which is
;;   the audit record of what was said and answered.
;;
;; The design, the alternatives and the fallback are in
;; docs/design/voice-turn-recovery.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar harness-voice-recovery--seq 0
  "Counter naming each recovery, for a caller that gives none.")

(defconst harness-voice-recovery--states
  '(armed recovering done abandoned)
  "What a recovery record is doing.
`armed' waits for the person to speak again, `recovering' has taken the
turn back and waits for the cancel or the rewind, `done' put the words
back in the draft, and `abandoned' left the turn as it was.")

(defun harness-voice-recovery-arm (plist)
  "Return a recovery record armed for the submission PLIST describes.
PLIST holds `:session', `:generation', `:turn', `:text', `:items' and
`:segments' of the voice message just submitted, and `:submitted', when
it was sent."
  (list :id (or (plist-get plist :id) (cl-incf harness-voice-recovery--seq))
        :state 'armed
        :session (plist-get plist :session)
        :generation (plist-get plist :generation)
        :turn (plist-get plist :turn)
        :text (or (plist-get plist :text) "")
        :items (plist-get plist :items)
        :segments (plist-get plist :segments)
        :submitted (or (plist-get plist :submitted) (float-time))
        :onset nil
        :onset-source nil
        :measured nil
        :continuations nil
        :captions nil
        :evidence nil))

(defun harness-voice-recovery--put (record key value)
  "Return RECORD with KEY set to VALUE."
  (plist-put (copy-sequence record) key value))

(defun harness-voice-recovery--normal (text)
  "Return TEXT as words to compare: trimmed, inner runs of space collapsed."
  (when (stringp text)
    (string-trim (replace-regexp-in-string "[[:space:]\n]+" " " text))))

(defun harness-voice-recovery-words-p (text)
  "Non-nil when TEXT is words a person said.
An empty transcription, a caption of spaces or punctuation only, and a
character that is no word at all -- a tick of the microphone, a musical
note, a dash -- are not words, and never start a recovery."
  (and (stringp text)
       (let ((text (string-trim text)))
         (and (not (string-empty-p text))
              (string-match-p "[[:alnum:]]" text)
              t))))

(defun harness-voice-recovery-state (record)
  "Return what RECORD is doing (see `harness-voice-recovery--states')."
  (plist-get record :state))

(defun harness-voice-recovery-armed-p (record)
  "Non-nil while RECORD still waits for resumed speech."
  (eq (harness-voice-recovery-state record) 'armed))

(defun harness-voice-recovery-note (record text)
  "Return RECORD with TEXT kept as evidence, newest first."
  (when (and (stringp text) (not (string-empty-p text)))
    (harness-voice-recovery--put
     record :evidence (cons text (plist-get record :evidence)))))

(defun harness-voice-recovery-evidence (record)
  "Return RECORD's evidence lines, oldest first."
  (reverse (plist-get record :evidence)))

(defun harness-voice-recovery-abandon (record why)
  "Return RECORD abandoned for WHY, keeping what it saw as evidence."
  (let ((record (harness-voice-recovery-note record (format "Not recovered · %s" why))))
    (harness-voice-recovery--put record :state 'abandoned)))

(defun harness-voice-recovery-finish (record state)
  "Return RECORD finished in STATE, which is `done' or `abandoned'."
  (harness-voice-recovery--put record :state state))

(defun harness-voice-recovery-continue (record source text)
  "Return RECORD with SOURCE's TEXT kept as part of the thought.
The pairs are kept in the order they were spoken, which is not the order
their transcripts arrived; `harness-voice-recovery-combined' reads
them."
  (let ((text (harness-voice-recovery--normal text)))
    (if (not (harness-voice-recovery-words-p text))
        record
      ;; A source is one utterance: its newest words replace its earlier
      ;; ones where it first stood, so a revised transcript is neither a
      ;; repeat nor a reordering.
      (let* ((pairs (plist-get record :continuations))
             (known (assoc source pairs)))
        (harness-voice-recovery--put
         record :continuations
         (if known
             (mapcar (lambda (pair)
                       (if (equal (car pair) source) (cons source text) pair))
                     pairs)
           (append pairs (list (cons source text)))))))))

(defun harness-voice-recovery-caption (record source text &optional final)
  "Return RECORD keeping SOURCE's caption TEXT, final or still arriving.
A provider that streams captions sends fragments of one utterance; the
thought keeps the whole of each capture, and a final replaces the
fragments it completes, so a partial revision is neither repeated nor
lost.  Text with no words in it changes nothing."
  (let* ((text (or text ""))
         (whole (if final
                    text
                  (concat (or (cdr (assoc source (plist-get record :captions))) "")
                          text))))
    (if (not (harness-voice-recovery-words-p whole))
        record
      (let ((record (harness-voice-recovery--put
                     record :captions
                     (cons (cons source whole)
                           (assq-delete-all source (plist-get record :captions))))))
        (harness-voice-recovery-continue record source whole)))))

(defun harness-voice-recovery-continuations (record)
  "Return RECORD's continuations as (SOURCE . TEXT) pairs, oldest first."
  (plist-get record :continuations))

(defun harness-voice-recovery-fallback (plan why)
  "Return PLAN's safe fallback when PLAN's action cannot be carried out.
A rewind that cannot happen keeps the history as it stands: the message
is already in it, so the draft stays empty and only the continuation is
added.  A message the transcript never held stays in the draft, because
a thought lost is worse than a request made twice.  WHY is short words
for the record."
  (if (eq (plist-get plan :action) 'rewind)
      (list :action 'append :draft nil :why (or why "rollback failed"))
    (list :action (plist-get plan :action)
          :draft (plist-get plan :draft)
          :why (or why (plist-get plan :why)))))

(defun harness-voice-recovery-source-seen-p (record source)
  "Non-nil when SOURCE is a capture RECORD's message was made of.
The voice message's own captions are not resumed speech: the source is
the utterance the words came from, or the delegation id without one."
  (and source
       (cl-some (lambda (seen) (equal (format "%s" seen) (format "%s" source)))
                (plist-get record :segments))))

(defun harness-voice-recovery-onset (record source now)
  "Return RECORD noting that speech resumed from SOURCE at NOW.
Only a capture other than the submitted message's own is resumed
speech, and only the first onset after the submission is kept: it is
what the window is measured from."
  (if (or (not (harness-voice-recovery-armed-p record))
          (plist-get record :onset)
          (harness-voice-recovery-source-seen-p record source)
          (not (numberp now))
          (< now (plist-get record :submitted)))
      record
    (harness-voice-recovery--put
     (harness-voice-recovery--put record :onset now) :onset-source source)))

(defun harness-voice-recovery--delay (record now)
  "Return how long after RECORD's submission the resumed speech began.
That is the onset's own report when there is one, else NOW, the moment
the words arrived: the two are different evidence and the record says
which it used."
  (let ((onset (plist-get record :onset)))
    (if onset
        (cons 'onset (- onset (plist-get record :submitted)))
      (cons 'arrival (- (or now (float-time)) (plist-get record :submitted))))))

(defun harness-voice-recovery-trigger (record text &optional opts)
  "Decide whether TEXT takes back the turn RECORD describes.
OPTS holds `:source' (the capture the words came from), `:now',
`:window' (seconds) and `:certainty' (a provider's own word about its
reading).  Return (TRIGGER . RECORD) when the words are resumed speech
inside the window, else (IGNORE . REASON), REASON one of `empty',
`unsure', `same-capture', `outside-window', `already-recovering',
`finished'."
  (let ((now (or (plist-get opts :now) (float-time)))
        (window (or (plist-get opts :window) 0.6))
        (source (plist-get opts :source)))
    (cond
     ((not (harness-voice-recovery-words-p text))
      (cons 'ignore 'empty))
     ((equal (plist-get opts :certainty) "unsure")
      (cons 'ignore 'unsure))
     ((not (harness-voice-recovery-armed-p record))
      (cons 'ignore (if (eq (harness-voice-recovery-state record) 'done)
                        'finished
                      'already-recovering)))
     ((harness-voice-recovery-source-seen-p record source)
      (cons 'ignore 'same-capture))
     (t
      (let* ((delay (harness-voice-recovery--delay record now))
             (measured (car delay))
             (seconds (cdr delay)))
        (if (> seconds window)
            (cons 'ignore 'outside-window)
          (let* ((noted (harness-voice-recovery-note
                         record
                         (format "Resumed speech · %s · %s"
                                 (harness-voice-recovery--seconds seconds)
                                 (if (eq measured 'onset) "onset" "transcript"))))
                 (taken (harness-voice-recovery--put noted :measured measured)))
            (cons 'trigger
                  (harness-voice-recovery--put taken :state 'recovering)))))))))

(defun harness-voice-recovery--seconds (seconds)
  "Return SECONDS as a short duration: 40ms, 0.2s, 1.4s."
  (if (< seconds 1)
      (format "%dms" (max 0 (round (* 1000 seconds))))
    (format "%.1fs" seconds)))

(defun harness-voice-recovery-combined (record continuations)
  "Return the thought of RECORD followed by CONTINUATIONS.
CONTINUATIONS is a list of (SOURCE . TEXT), oldest first.  A source seen
again with other words is a revised transcript, not a second utterance:
its newest words replace its earlier ones in the place it first had, so
a partial correction neither repeats nor reorders the thought.  Empty
and wordless continuations are left out."
  (let ((order nil)
        (texts (make-hash-table :test 'equal)))
    (dolist (pair continuations)
      (let ((source (car pair))
            (text (harness-voice-recovery--normal (cdr pair))))
        (when (harness-voice-recovery-words-p text)
          (unless (gethash source texts) (push source order))
          (puthash source text texts))))
    (let ((parts (delq nil (cons (harness-voice-recovery--normal (plist-get record :text))
                                 (mapcar (lambda (source) (gethash source texts))
                                         (nreverse order))))))
      (string-join (delq nil (mapcar (lambda (part)
                                       (and part (not (string-empty-p part)) part))
                                     parts))
                   " "))))

(defun harness-voice-recovery-continuation-source-p (record source)
  "Non-nil when SOURCE is one of RECORD's continuations.
Its transcript belongs to the thought being taken back, not to a turn
of its own."
  (and source
       (cl-some (lambda (pair) (equal (format "%s" (car pair)) (format "%s" source)))
                (harness-voice-recovery-continuations record))))

(defun harness-voice-recovery-continuation-text (record)
  "Return only the continuations of RECORD, as one message.
That is what a draft adds to words the history already holds."
  (string-join
   (delq nil (mapcar (lambda (pair)
                       (let ((text (harness-voice-recovery--normal (cdr pair))))
                         (and (harness-voice-recovery-words-p text) text)))
                     (harness-voice-recovery-continuations record)))
   " "))

(defun harness-voice-recovery-draft (record plan)
  "Return the words of RECORD the next message must carry, given PLAN.
A rewind puts the original words back in the draft: the next message is
the whole thought.  A kept history already holds them, so the draft
stays empty and the thought is never said twice; words the transcript
never held are kept in the draft, since a thought lost is worse than a
request made again."
  (and (plist-get plan :draft) (plist-get record :items)))

(defun harness-voice-recovery--kind (node)
  "Return NODE's kind as a string."
  (let ((kind (plist-get node :kind)))
    (and kind (format "%s" kind))))

(defun harness-voice-recovery--same-text-p (a b)
  "Non-nil when A and B are the same words, spacing aside."
  (let ((a (harness-voice-recovery--normal a))
        (b (harness-voice-recovery--normal b)))
    (and a b (equal a b))))

(defun harness-voice-recovery-plan (record nodes)
  "Return what to do with the history RECORD's turn left, given NODES.
NODES is the session's transcript path, oldest first, as `session/nodes'
returns it, or nil when it could not be read.  The value is a plist of
`:action', `:why' and `:draft', with `:node' and `:head' for a rewind:

  rewind   the voice message is on the head's path, no tool ran in the
           turn and no message followed it: move the head to the node
           before it, which leaves the turn's nodes on their own branch
           of the tree.  `:draft' is t: the message goes again.
  intact   the transcript does not hold the message, so the head is
           already where the thought continues and there is nothing to
           move.  `:draft' is t, so the words are not lost.
  append   the message is in the transcript but the history cannot be
           rolled back without claiming more than a rewind can do -- a
           tool ran, a message followed, or there is no earlier node --
           so the history stays and only the continuation is added.
           `:draft' is nil, since the thought is already in it.

`:why' is short words for the record: `voice turn', `no message',
`message missing', `no transcript', `tool calls', `later message',
`no earlier message'."
  (let* ((nodes (delq nil nodes))
         (head (car (last nodes)))
         (submitted (plist-get record :submitted))
         (voice nil)
         (after nil))
    (cond
     ((null nodes)
      (list :action 'intact :why "no transcript" :draft t))
     (t
      ;; The newest user node at or after the submission is the voice
      ;; message when it has the words that were sent.
      (dolist (node nodes)
        (when (and (equal (harness-voice-recovery--kind node) "user")
                   (numberp (plist-get node :ts))
                   (>= (plist-get node :ts) (- submitted 0.001)))
          (setq voice node)))
      (cond
       ((null voice)
        ;; Nothing the person said is on the head's path after the
        ;; submission: the head never moved past the thought, or the
        ;; message is elsewhere and cannot be moved off safely.
        (list :action 'intact
              :why (if (and head (numberp (plist-get head :ts))
                            (>= (plist-get head :ts) (- submitted 0.001)))
                       "message missing"
                     "no message")
              :draft t))
       ((not (harness-voice-recovery--same-text-p
              (plist-get voice :content) (plist-get record :text)))
        (list :action 'append :why "later message" :draft nil))
       (t
        (let ((seen nil))
          (dolist (node nodes)
            (cond
             ((eq node voice) (setq seen t))
             (seen
              (when (equal (harness-voice-recovery--kind node) "tool-call")
                (setq after 'tool-calls))
              (when (and (equal (harness-voice-recovery--kind node) "user")
                         (not (plist-get (plist-get node :meta) :steering)))
                (setq after 'later-message)))))
          (cond
           (after (list :action 'append :draft nil
                        :why (if (eq after 'tool-calls) "tool calls" "later message")))
           ((null (plist-get voice :parent))
            (list :action 'append :why "no earlier message" :draft nil))
           (t (list :action 'rewind :draft t
                    :node (plist-get voice :id)
                    :head (plist-get voice :parent)
                    :why "voice turn"))))))))))

(defun harness-voice-recovery-plan-line (plan)
  "Return PLAN as the short line the transcript shows."
  (pcase (plist-get plan :action)
    ('rewind "History · rewound")
    ('intact "History · unchanged")
    (_ (format "History · kept · %s" (or (plist-get plan :why) "unsafe")))))

(provide 'harness-ui-voice-recovery)
;;; harness-ui-voice-recovery.el ends here
