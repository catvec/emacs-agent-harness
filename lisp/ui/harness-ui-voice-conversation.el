;;; harness-ui-voice-conversation.el --- The voice conversation of one call  -*- lexical-binding: t; -*-

;;; Commentary:

;; Voice has two records, not one.  The *voice conversation* is what was
;; said and heard on the audio side: every user utterance as the speech
;; model returned it, and every line the voice actually spoke.  A
;; *session message* is what crosses into the chat: the transcript, sent
;; as it came back from speech to text.
;;
;; There is no distillation and no context envelope.  An earlier version
;; removed hesitation sounds here, and added a bounded block of earlier
;; voice turns to a request that looked dependent.  Both were wrong for
;; the same reason: a request is not a thing to be rewritten, and the
;; session's own agent is the only reader that can tell which earlier
;; turn a pronoun points at.  The agent sees the conversation it is in;
;; the voice only delivers the words.  Sending them unchanged is also
;; the shortest path, so a transcript reaches its target in the event
;; that carried it.
;;
;; The design and its alternatives are in docs/design/voice-conversation.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup harness-voice nil
  "Local dictation and live voice."
  :group 'harness-ui)

(defcustom harness-voice-conversation-turns 40
  "How many turns of one call the voice conversation keeps.
The oldest turns are forgotten first.  A long call therefore keeps a
bounded record rather than a second unbounded transcript."
  :type 'natnum
  :group 'harness-voice)

;;;; The conversation

(cl-defstruct (harness-voice-conversation
               (:constructor harness-voice-conversation-create))
  (turns nil)
  (seq 0))

(defconst harness-voice-conversation--turn-limit 4000
  "Maximum characters of one turn the voice conversation keeps.
The context budget is much smaller; this is the record's own bound, so a
long spoken result cannot grow a second unbounded transcript.")

(defun harness-voice-conversation--one-line (text)
  "Return TEXT as one trimmed, bounded line."
  (when (stringp text)
    (let ((text (string-trim (replace-regexp-in-string "[[:space:]]+" " " text))))
      (if (> (length text) harness-voice-conversation--turn-limit)
          (concat (substring text 0 (1- harness-voice-conversation--turn-limit))
                  "…")
        text))))

(defun harness-voice-conversation--trim (conversation)
  "Forget the oldest turns beyond `harness-voice-conversation-turns'."
  (let ((limit (max 1 harness-voice-conversation-turns))
        (turns (harness-voice-conversation-turns conversation)))
    (when (> (length turns) limit)
      (setf (harness-voice-conversation-turns conversation)
            (cl-subseq turns 0 limit)))))

(defun harness-voice-conversation--turn (conversation speaker plist)
  "Make a turn of CONVERSATION for SPEAKER from PLIST."
  (setf (harness-voice-conversation-seq conversation)
        (1+ (harness-voice-conversation-seq conversation)))
  (append (list :id (format "v-%d" (harness-voice-conversation-seq conversation))
                :speaker speaker)
          plist))

(defun harness-voice-conversation-hear (conversation raw &optional sent now)
  "Record that the person said RAW, and that SENT crossed into the session.
SENT is the message the target received, which is RAW itself: nothing
is added to it and nothing is taken out.  Return the new turn, or nil
when RAW is empty."
  (let ((raw (harness-voice-conversation--one-line raw)))
    (when (and raw (not (string-empty-p raw)))
      (let ((turn (harness-voice-conversation--turn
                   conversation 'user
                   (list :raw raw
                         :text raw
                         :sent (or sent raw)
                         :time (or now (float-time))))))
        (setf (harness-voice-conversation-turns conversation)
              (cons turn (harness-voice-conversation-turns conversation)))
        (harness-voice-conversation--trim conversation)
        turn))))

(defun harness-voice-conversation-say (conversation text &optional source now stream)
  "Record that the voice said TEXT.
SOURCE is `commentary', `result', `backchannel', `provider' or `open'.
A STREAM fragment grows the newest voice turn instead of starting one;
it is how a provider's caption deltas stay one turn.  A complete line
that contains the turns after it absorbs them, so a result that repeats
its own sentences is recorded once."
  (let* ((text (harness-voice-conversation--one-line text))
         (turns (harness-voice-conversation-turns conversation)))
    (when (and text (not (string-empty-p text)))
      (let ((last (car turns)))
        (cond
         ((and (eq (plist-get last :speaker) 'voice)
               (equal text (plist-get last :text)))
          ;; The same line once, not twice.
          nil)
         ((and stream (eq (plist-get last :speaker) 'voice))
          (setf (harness-voice-conversation-turns conversation)
                (cons (plist-put last :text
                                 (harness-voice-conversation--one-line
                                  (concat (plist-get last :text) " " text)))
                      (cdr turns)))
          (harness-voice-conversation--trim conversation))
         (t
          (let ((absorbed nil))
            (while (and turns
                        (eq (plist-get (car turns) :speaker) 'voice)
                        (not (eq (plist-get (car turns) :source) 'backchannel))
                        (let ((old (plist-get (car turns) :text)))
                          (and old
                               (not (string-empty-p old))
                               (string-match-p (regexp-quote old) text))))
              (push (pop turns) absorbed))
            (if (and (null absorbed)
                     turns
                     (eq (plist-get (car turns) :speaker) 'voice)
                     (let ((old (plist-get (car turns) :text)))
                       (and old (string-match-p (regexp-quote text) old))))
                ;; A sentence of a turn already recorded.
                nil
              (setf (harness-voice-conversation-turns conversation)
                    (cons (harness-voice-conversation--turn
                           conversation 'voice
                           (list :text text
                                 :source source
                                 :time (or now (float-time))))
                          turns))
              (harness-voice-conversation--trim conversation)))))))))

(defun harness-voice-conversation-clear (conversation)
  "Forget every turn of CONVERSATION; a new call starts empty."
  (setf (harness-voice-conversation-turns conversation) nil
        (harness-voice-conversation-seq conversation) 0))

(provide 'harness-ui-voice-conversation)
;;; harness-ui-voice-conversation.el ends here
