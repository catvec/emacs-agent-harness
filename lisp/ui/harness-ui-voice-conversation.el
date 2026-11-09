;;; harness-ui-voice-conversation.el --- The voice conversation and the request it sends  -*- lexical-binding: t; -*-

;;; Commentary:

;; Voice has two records, not one.  The *voice conversation* is what was
;; said and heard on the audio side: every user utterance as the speech
;; model returned it, and every line the voice actually spoke.  A
;; *session message* is what crosses into the chat: a request distilled
;; from one delegation, and -- only when the request cannot stand alone
;; -- the last few turns of the voice conversation.
;;
;; Distillation is local and deterministic.  It removes hesitation
;; sounds, comma-set discourse markers, stutters and an explicit
;; self-correction; every content word, name, path and number stays, and
;; the raw transcript is never rewritten.  It starts no process, calls
;; no model and waits for no timer, so a transcript reaches the session
;; in the same event that carried it.  The rules are deliberately
;; conservative: an unset `like' is kept, an affirmation sound that is
;; the whole utterance is kept, and a repeated word that can be real
;; English (`had had', `that that') is kept.
;;
;; Context is the voice conversation's own words, added only for a
;; request that points at something said earlier: a pronoun or deictic
;; near the start, a continuation, or a yes/no answer.  It is the last
;; few turns that fit in a small character budget, in plain text with
;; speaker labels -- not an XML envelope -- and a self-contained request
;; travels without it.  The voice transcript keeps the raw caption; the
;; session gets the distilled request.
;;
;; The design and its alternatives are in docs/design/voice-conversation.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup harness-voice nil
  "Local dictation and live voice."
  :group 'harness-ui)

(defcustom harness-voice-distill t
  "Whether a voice request is distilled before it reaches the session.
Non-nil removes hesitation sounds, stutters and self-corrections from
the transcript; nil sends the transcript as heard.  Either way the raw
words stay in the voice conversation and the live transcript."
  :type 'boolean
  :group 'harness-voice)

(defcustom harness-voice-conversation-carry-context t
  "Whether a dependent voice request carries earlier voice turns.
A request that names what it is about travels alone.  One that points
with a pronoun, a deictic, a continuation or a yes/no answer carries the
last few turns of the voice conversation, within the bounds below."
  :type 'boolean
  :group 'harness-voice)

(defcustom harness-voice-conversation-turns 40
  "How many turns of one call the voice conversation keeps.
The oldest turns are forgotten first.  A long call therefore keeps a
bounded record rather than a second unbounded transcript."
  :type 'natnum
  :group 'harness-voice)

(defcustom harness-voice-conversation-context-turns 4
  "How many earlier voice turns one dependent request may carry."
  :type 'natnum
  :group 'harness-voice)

(defcustom harness-voice-conversation-context-chars 700
  "Maximum characters of voice-conversation context in one request."
  :type 'natnum
  :group 'harness-voice)

(defcustom harness-voice-conversation-turn-chars 240
  "Maximum characters of one earlier voice turn in a request."
  :type 'natnum
  :group 'harness-voice)

;;;; Distillation

(defconst harness-voice-conversation--hesitations
  '("um" "umm" "ummm" "uh" "uhh" "uhm" "er" "erm" "ah" "eh" "hmm" "hmmm")
  "Sounds that carry no request wherever they appear.")

(defconst harness-voice-conversation--affirmations
  '("uh-huh" "mm-hmm" "mhm" "mm")
  "Sounds that mean yes when they are the whole utterance.
They are removed only when something else remains, so a bare answer
still reaches the session.")

(defconst harness-voice-conversation--real-doubles
  '("had" "that" "is" "do" "be")
  "Words that can legitimately repeat and are not collapsed as stutters.")

(defconst harness-voice-conversation--annotations
  (concat "noise\\|music\\|laugh\\|applause\\|silence\\|blank\\|inaudible"
          "\\|cough\\|sigh\\|clap\\|beep\\|sneeze\\|breath\\|crosstalk")
  "What inside brackets or asterisks marks a sound rather than speech.")

(defconst harness-voice-conversation--annotation-regexp
  "\\(?:\\[[^][]*\\]\\|([^()]*)\\|\\*[^*\n]*\\|♪\\|♫\\)"
  "A bracket, parenthesis, asterisk pair or music mark to inspect.")

(defconst harness-voice-conversation--repair-regexp
  (concat "\\(?:"
          "\\bno[,]?[ \t]+wait\\b"
          "\\|\\bwait[,]?[ \t]+no\\b"
          "\\|\\bsorry\\b[,]?[ \t]+i[ \t]+mean\\b"
          "\\|,[ \t]*i[ \t]+mean\\b"
          "\\|,[ \t]*actually\\b"
          "\\|\\`[ \t]*actually\\b"
          "\\)[,;:]?[ \t]*")
  "A speaker retracting what came before it.")

(defconst harness-voice-conversation--stutter-regexp
  (concat "\\(\\b\\(?:[[:alpha:]'’-]+[,]?[ \t]+\\)\\{0,2\\}"
          "[[:alpha:]'’-]+\\)[,;:]?[ \t]+\\1\\b")
  "A word or short phrase repeated immediately.
The first occurrence is group 1, which is what a replacement keeps.")

(defconst harness-voice-conversation--comma-set-hesitation
  (concat ",[ \t]*\\(?:"
          (regexp-opt harness-voice-conversation--hesitations t)
          "\\)[ \t]*,")
  "A hesitation set off by commas on both sides.
The pair of commas goes with it, so `so, um, what' becomes `so what'
rather than `so, what'.")

(defconst harness-voice-conversation--affirmation-only
  (concat "\\`[ \t]*\\(?:"
          (regexp-opt harness-voice-conversation--affirmations t)
          "\\)[ \t]*[.!?]?[ \t]*\\'")
  "An utterance that is only an affirmation sound.")

(defun harness-voice-conversation--strip-annotations (text)
  "Remove bracketed or starred sound annotations from TEXT."
  (let ((case-fold-search t))
    (replace-regexp-in-string
     harness-voice-conversation--annotation-regexp
     (lambda (match)
       (if (string-match-p harness-voice-conversation--annotations match)
           " "
         match))
     text t t)))

(defun harness-voice-conversation--strip-discourse (text)
  "Remove comma-set discourse markers from TEXT.
`like', `you know' and `I mean' are removed only when a comma sets them
aside, or at the start followed by a comma; an unset `like' or `I mean
it' is kept."
  (let ((case-fold-search t))
    (setq text (replace-regexp-in-string
                ",[ \t]*\\(?:you know\\|i mean\\|like\\)[ \t]*," ","
                text t t))
    (setq text (replace-regexp-in-string
                "\\`[ \t]*\\(?:you know\\|i mean\\|like\\)[ \t]*,[ \t]*" ""
                text t t))
    (replace-regexp-in-string
     ",[ \t]*\\(?:you know\\|i mean\\)[ \t]*\\([.!?]\\|\\'\\)" "\\1"
     text t t)))

(defun harness-voice-conversation--repair (text)
  "Keep only the correction after a self-correction marker in TEXT.
The first marker with speech after it wins; a marker with nothing after
it is left alone, because there is no correction to keep."
  (let ((case-fold-search t)
        (guard 0))
    (while (and (< guard 8)
                (string-match harness-voice-conversation--repair-regexp text))
      (let ((after (substring text (match-end 0))))
        (if (string-match-p "[[:alnum:]]" after)
            (setq text after
                  guard (1+ guard))
          (setq guard 8))))
    text))

(defun harness-voice-conversation--remove-words (text words)
  "Remove every whole word in WORDS from TEXT, with a following comma."
  (let ((case-fold-search t))
    (replace-regexp-in-string
     (concat "\\b\\(?:" (regexp-opt words t) "\\)\\b[,;:]?[ \t]*")
     "" text t t)))

(defun harness-voice-conversation--remove-affirmations (text)
  "Remove affirmation sounds from TEXT unless they are all of it."
  (let ((without (harness-voice-conversation--remove-words
                  text harness-voice-conversation--affirmations)))
    (if (string-match-p "[[:alnum:]]" without)
        without
      text)))

(defun harness-voice-conversation--collapse-stutters (text)
  "Collapse an immediately repeated word or short phrase in TEXT.
A word that can legitimately repeat is kept as it is."
  (let ((case-fold-search t)
        (guard 0)
        (previous nil))
    (while (and (< guard 8) (not (equal previous text)))
      (setq previous text
            text (replace-regexp-in-string
                  harness-voice-conversation--stutter-regexp
                  (lambda (match)
                    (let ((phrase (match-string 1 match)))
                      (if (and (not (string-match-p "[[:space:]]" phrase))
                               (member (downcase phrase)
                                       harness-voice-conversation--real-doubles))
                          match
                        phrase)))
                  text t)
            guard (1+ guard)))
    text))

(defun harness-voice-conversation--tidy (text)
  "Collapse the spaces and punctuation the removals left in TEXT."
  (setq text (replace-regexp-in-string "[[:space:]]+" " " text))
  (setq text (replace-regexp-in-string " +\\([,.;:!?]\\)" "\\1" text))
  (setq text (replace-regexp-in-string "\\([,;:]\\)[ \t]*\\1+" "\\1" text))
  (setq text (replace-regexp-in-string "\\([,;:]\\)[ \t]*\\([.!?]\\)" "\\2" text))
  (setq text (replace-regexp-in-string "\\`[ \t,;:]+" "" text))
  (setq text (replace-regexp-in-string "[ \t,;:]+\\'" "" text))
  (string-trim text))

(defun harness-voice-distilled-text (text)
  "Return TEXT with only its mumbles removed, or nil when nothing is left.
The removal rules are the ones in the Commentary: hesitation sounds,
comma-set discourse markers, stutters, an explicit self-correction and
non-speech annotations.  Content words, names, paths, numbers, casing
and punctuation are kept.  This function starts no process, timer or
model call; it is the whole hot path between a transcript and a session
message."
  (when (and (stringp text) (not (string-empty-p (string-trim text))))
    (let ((result (string-trim text)))
      (setq result (harness-voice-conversation--strip-annotations result))
      (setq result (harness-voice-conversation--repair result))
      (setq result (harness-voice-conversation--strip-discourse result))
      (if (let ((case-fold-search t))
            (string-match-p harness-voice-conversation--affirmation-only result))
          ;; A bare `uh-huh' is a yes, not a mumble.
          (harness-voice-conversation--tidy result)
        (setq result (harness-voice-conversation--remove-affirmations result))
        (let ((case-fold-search t))
          (setq result (replace-regexp-in-string
                        harness-voice-conversation--comma-set-hesitation " "
                        result t t)))
        (setq result (harness-voice-conversation--remove-words
                      result harness-voice-conversation--hesitations))
        (setq result (harness-voice-conversation--collapse-stutters result))
        (setq result (harness-voice-conversation--tidy result))
        (when (string-match-p "[[:alnum:]]" result)
          result)))))

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

(defun harness-voice-conversation-hear (conversation raw distilled &optional sent now)
  "Record that the person said RAW and that DISTILLED crossed into the session.
SENT is the whole message the session received, if any.  Return the new
turn, or nil when RAW is empty.  The voice conversation keeps RAW even
when DISTILLED is nil: the raw words are the record."
  (let ((raw (harness-voice-conversation--one-line raw)))
    (when (and raw (not (string-empty-p raw)))
      (let ((turn (harness-voice-conversation--turn
                   conversation 'user
                   (list :raw raw
                         :text (and distilled
                                    (not (string-empty-p distilled))
                                    distilled)
                         :sent sent
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

;;;; What the session sees

(defconst harness-voice-conversation--anaphora
  '("it" "its" "it's" "that" "that's" "this" "these" "those" "them" "they"
    "their" "theirs" "there" "then" "one" "ones")
  "Pronouns and deictics that may point outside the request.")

(defconst harness-voice-conversation--always-dependent
  '("same" "other" "another" "previous" "earlier" "before" "again" "also"
    "too" "either" "both" "latter" "former" "such")
  "Words that mark a link to an earlier turn wherever they appear.")

(defconst harness-voice-conversation--answers
  '("yes" "yeah" "yep" "no" "nope" "okay" "ok" "sure" "right" "correct"
    "wrong" "continue" "stop" "wait")
  "First words of an answer or a command that needs what it answers.")

(defconst harness-voice-conversation--continuations
  '("and" "but" "then" "now" "also" "again")
  "First words of a request that continues an earlier one.")

(defconst harness-voice-conversation--dependent-phrases
  (concat "\\bdo[ \t]+\\(?:it\\|that\\|this\\)\\b"
          "\\|\\bgo[ \t]+ahead\\b"
          "\\|\\bkeep[ \t]+going\\b"
          "\\|\\bcarry[ \t]+on\\b"
          "\\|\\bthe[ \t]+\\(?:first\\|second\\|third\\|last\\|next\\|other\\|same\\)[ \t]+one\\b"
          "\\|\\b\\(?:same\\|other\\)[ \t]+\\(?:thing\\|one\\)\\b"
          "\\|\\`[ \t]*\\(?:fix\\|change\\|update\\|add\\|remove\\|delete\\|use\\|make\\)"
          "[ \t]+\\(?:it\\|that\\|this\\)\\b")
  "Phrases whose request depends on an earlier turn even when it is long.")

(defun harness-voice-conversation-needs-context-p (text)
  "Return non-nil when TEXT points at something it does not name.
A pronoun counts near the start, or in a request of six words or fewer,
so a longer sentence that names its own subject and says `it' later does
not ask for context.  An answer or continuation at the start, a word
that always links to an earlier turn, and a deictic phrase anywhere, do."
  (when (and (stringp text) (not (string-empty-p (string-trim text))))
    (let* ((trimmed (string-trim text))
           (case-fold-search t)
           (words (split-string (downcase trimmed) "[^[:alpha:]']+" t))
           (head (cl-subseq words 0 (min 4 (length words)))))
      (or (cl-some (lambda (word)
                     (and (member word harness-voice-conversation--anaphora) t))
                   head)
          (and (<= (length words) 6)
               (cl-some (lambda (word)
                          (and (member word harness-voice-conversation--anaphora) t))
                        words))
          (cl-some (lambda (word)
                     (and (member word harness-voice-conversation--always-dependent) t))
                   words)
          (and (member (car words) harness-voice-conversation--answers) t)
          (and (member (car words) harness-voice-conversation--continuations) t)
          (and (string-match-p harness-voice-conversation--dependent-phrases
                               (downcase trimmed))
               t)))))

(defun harness-voice-conversation--context-text (turn)
  "Return TURN's text when it belongs in a request's context, else nil."
  (let ((text (plist-get turn :text))
        (source (plist-get turn :source)))
    (when (and text
               (not (string-empty-p text))
               (not (eq source 'backchannel)))
      (if (> (length text) (max 8 harness-voice-conversation-turn-chars))
          (concat (substring text 0 (max 1 (1- harness-voice-conversation-turn-chars)))
                  "…")
        text))))

(defconst harness-voice-conversation--context-header
  "Voice conversation before this request:\n"
  "The line that introduces a bounded voice-conversation block.")

(defun harness-voice-conversation--context-turns (conversation)
  "Return the newest turns of CONVERSATION that fit the context budget.
Oldest first, so they read as a conversation.  The budget covers the
header and the speaker labels as well as the words."
  (let ((turns (harness-voice-conversation-turns conversation))
        (limit (max 1 harness-voice-conversation-context-turns))
        (budget (max 1 harness-voice-conversation-context-chars))
        (kept nil)
        (total (length harness-voice-conversation--context-header)))
    (while (and turns (< (length kept) limit))
      (let* ((turn (car turns))
             (text (harness-voice-conversation--context-text turn)))
        (setq turns (cdr turns))
        (when text
          (setq kept (cons (plist-put (copy-sequence turn) :text text) kept)
                total (+ total
                         (length (if (eq (plist-get turn :speaker) 'user)
                                     "Person" "Voice"))
                         3 (length text))))))
    (while (and (cdr kept) (> total budget))
      (setq total (- total
                      (length (if (eq (plist-get (car kept) :speaker) 'user)
                                  "Person" "Voice"))
                              3 (length (plist-get (car kept) :text))))
      (setq kept (cdr kept)))
    kept))

(defun harness-voice-conversation-context (conversation)
  "Return CONVERSATION's bounded plain-text context block, or nil."
  (let ((turns (harness-voice-conversation--context-turns conversation)))
    (when turns
      (concat harness-voice-conversation--context-header
              (mapconcat
               (lambda (turn)
                 (format "%s: %s"
                         (if (eq (plist-get turn :speaker) 'user) "Person" "Voice")
                         (plist-get turn :text)))
               turns "\n")
              "\n"))))

(defun harness-voice-conversation-request (conversation text)
  "Return TEXT as the session message, with bounded context when it needs it.
TEXT is already distilled; CONVERSATION supplies earlier turns.  A
request that names what it is about is returned unchanged, without a
wrapper."
  (let ((text (string-trim (or text ""))))
    (if (or (string-empty-p text)
            (not harness-voice-conversation-carry-context)
            (not (harness-voice-conversation-needs-context-p text)))
        text
      (let ((context (harness-voice-conversation-context conversation)))
        (if context (concat text "\n\n" context) text)))))

(provide 'harness-ui-voice-conversation)
;;; harness-ui-voice-conversation.el ends here
