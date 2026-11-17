;;; harness-ui-voice-turn.el --- Conservative speech turn endings  -*- lexical-binding: t; -*-

;;; Commentary:

;; Audio endpoints are not conversational endpoints.  These deliberately
;; small English-language rules only decide whether an unsent transcript
;; needs ordinary grace or an indefinite hold.  They never rewrite it.
;; The cross-client examples live in test/fixtures/voice-turn-completion.json.

;;; Code:

(require 'subr-x)

(defun harness-voice-turn--ending (text)
  "Return TEXT in lower case, without terminal sentence punctuation."
  (string-trim-right (downcase (string-trim text)) "[[:space:].!?,;:]+"))

(defconst harness-voice-turn--continuation-cue-regexp
  (concat "\\(?:one \\(?:second\\|sec\\|moment\\)"
          "\\|hold on\\(?: \\(?:a\\|one\\) \\(?:second\\|sec\\|moment\\)\\)?"
          "\\|let me think\\|give me \\(?:a\\|one\\) \\(?:moment\\|second\\|sec\\)"
          "\\|wait \\(?:a\\|one\\) \\(?:sec\\|second\\|moment\\)"
          "\\|\\(?:i need to \\)?catch my breath\\|um\\|uh\\|erm\\|hmm\\)")
  "Direct pause and hesitation cues, without surrounding words or punctuation.")

(defun harness-voice-turn--control-p (text cue-regexp)
  "Whether all of TEXT matches CUE-REGEXP with bounded polite wrappers.
Only whitespace and commas separate optional discourse prefixes, in order:
`oh', `well', `ok'/`okay'/`all right'/`alright', `actually', then `please'.
A final `please' and terminal punctuation are optional.  Quotation marks
and other content are not removed; matching never changes TEXT."
  (let ((ending (replace-regexp-in-string
                 "[[:space:]]+" " " (harness-voice-turn--ending text))))
    (and (string-match-p
          (concat "\\`\\(?:oh[ ,]+\\)?\\(?:well[ ,]+\\)?"
                  "\\(?:\\(?:ok\\|okay\\|all right\\|alright\\)[ ,]+\\)?"
                  "\\(?:actually[ ,]+\\)?\\(?:please[ ,]+\\)?"
                  "\\(?:" cue-regexp "\\)\\(?:[ ,]+please\\)?\\'")
          ending)
         t)))

(defun harness-voice-turn-recovery-p (text)
  "Whether all of TEXT is an unquoted recovery or explicit send cue.
Recognize `continue', `go on', and `send'/`submit' with `it'/`that' and
optional `now', with the wrappers of `harness-voice-turn--control-p'.
Callers consume a cue only for an existing draft; without one TEXT is an
ordinary request, retained unchanged.  Embedded and named uses are data."
  (harness-voice-turn--control-p
   text "continue\\|go on\\|\\(?:send\\|submit\\) \\(?:it\\|that\\)\\(?: now\\)?"))

(defun harness-voice-turn-continuation-p (text)
  "Whether all of TEXT is an unquoted pause or hesitation cue.
Use the wrappers of `harness-voice-turn--control-p'.  Unlike
`harness-voice-turn-reason', this never matches content ending in a cue;
only a whole control utterance may be omitted from a pending request."
  (harness-voice-turn--control-p text harness-voice-turn--continuation-cue-regexp))

(defun harness-voice-turn-reason (text &optional truncated)
  "Classify the ending of accumulated TEXT.
Return `grace', `continuation' or `cut-off'.  TRUNCATED is the backend's
explicit hard-cut flag, never an inference from audio duration.  Direct
pause intent takes precedence over it; quoted and named cues are data."
  (let* ((case-fold-search t)
         (unquoted (replace-regexp-in-string
                    "[\"“][^\"”]*[\"”]\\|'[^']*'\\|‘[^’]*’" " quoted " text))
         (ending (harness-voice-turn--ending unquoted))
         (cue (string-match
               (concat "\\b" harness-voice-turn--continuation-cue-regexp
                       "\\(?:[,[:space:]]+please\\)?\\'")
               ending))
         (named (and cue (string-match-p
                          "\\b\\(?:called\\|named\\|labelled\\|labeled\\|says\\|phrase\\)[[:space:]]+\\'"
                          (substring ending 0 cue)))))
    (cond
     ((and cue (not named)) 'continuation)
     (truncated 'cut-off)
     (named 'grace)
     ((harness-voice-turn-recovery-p text) 'grace)
     ((string-match-p "\\(?:\\.\\.\\.\\|…\\|[-—–]\\)[[:space:]]*\\'"
                      (string-trim-right text))
      'cut-off)
     ;; A final question preposition can be complete ("What is this for?").
     ((and (string-match-p "\\`\\(?:what\\|who\\|where\\|which\\|how\\|when\\|why\\)\\b" ending)
           (string-match-p "[?][[:space:]]*\\'" text)
           (string-match-p "\\b\\(?:for\\|on\\|in\\|at\\|with\\|from\\|about\\|by\\|of\\)\\'" ending))
      'grace)
     ((string-match-p "\\`\\(?:please \\)?\\(?:turn .+ on\\|log in\\)\\'" ending) 'grace)
     ((or (string-match-p
           "\\b\\(?:and\\|or\\|but\\|because\\|although\\|if\\|unless\\|while\\|whether\\|to\\|with\\|from\\|of\\|for\\|in\\|on\\|at\\|by\\|into\\|about\\|without\\|the\\|a\\|an\\|my\\|your\\|our\\|their\\)\\'"
           ending)
          (string-match-p "\\b\\(?:could\\|would\\|can\\|will\\) you\\'" ending)
          (string-match-p "\\bi \\(?:need\\|want\\|would like\\)\\'" ending))
      'cut-off)
     (t 'grace))))

(provide 'harness-ui-voice-turn)
;;; harness-ui-voice-turn.el ends here
