;;; harness-ui-workspace-speech-test.el --- Tests for the speech panel and its copy  -*- lexical-binding: t; -*-

;;; Commentary:

;; The panel's rendered copy, exactly: the headings, the states, the
;; buttons and their tooltips -- nouns and adjectives, as this
;; repository's interface copy is -- and the rules that keep a stale
;; answer, a hold and another client's claim from talking.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-acp-token)
(defvar harness-ui-map)
(defvar harness-ui-event-functions)
(defvar harness-ui--queue)
(defvar harness-ui--sessions)
(defvar harness-workspace-speech--floors)
(defvar harness-workspace-speech--player)
(defvar harness-workspace-speech--busy)
(defvar harness-workspace-speech--id)
(defvar harness-workspace-speech-speak)
(defvar harness-ui-workspace--id)
(defvar harness-ui-workspace--data)

(defmacro harness-ui-workspace-speech-test-with (&rest body)
  "Load the UI and the speech panel, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil)
           (harness-acp-token nil))
       (harness-test-load-module 'acp)
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-chat)
       (harness-test-load-module 'ui-compose)
       (harness-test-load-module 'ui-workspace)
       (harness-test-load-module 'ui-workspace-speech)
       (clrhash harness-workspace-speech--floors)
       (setq harness-workspace-speech--player nil
             harness-workspace-speech--busy nil)
       (unwind-protect (progn ,@body)
         (harness-workspace-speech-ui--shutdown)))))

(defun harness-ui-workspace-speech-test-floor (&rest plist)
  "Return a floor of workspace \"w-1\" with PLIST merged in."
  (harness-plist-merge (list :workspace "w-1"
                :revision 4
                :enabled t
                :solo nil
                :solo-title nil
                :hold nil
                :held nil
                :speaking nil
                :waiting nil
                :active nil
                :count 0
                :recent nil)
                        plist))

(defun harness-ui-workspace-speech-test-entry (&rest plist)
  "Return a floor entry with PLIST merged in."
  (harness-plist-merge (list :id "sp-1" :thread "th-1" :thread-title "Kitchen renovation"
                :text "The quote is accepted." :preview "The quote is accepted."
                :state "queued" :at 1.0 :session "s-1" :source "reply")
                       plist))

(defun harness-ui-workspace-speech-test-render (floor)
  "Render FLOOR in the speech panel and return its text."
  (let ((buffer (get-buffer-create " *speech-test*")))
    (with-current-buffer buffer
      (harness-workspace-speech-mode)
      (setq harness-workspace-speech--id "w-1")
      (puthash "w-1" floor harness-workspace-speech--floors)
      (harness-workspace-speech--render-panel)
      (buffer-string))))

(defun harness-ui-workspace-speech-test-help (text label)
  "Return the tooltip TEXT has for the button LABEL, or nil."
  (let ((pos 0) found)
    (while (and (not found) (string-match (regexp-quote label) text pos))
      (setq pos (match-beginning 0))
      (let ((end (+ pos (length label))))
        (when-let* ((help (get-text-property pos 'help-echo text)))
          (setq found help))
        (setq pos (max (1+ pos) end))))
    found))

(ert-deftest harness-ui-workspace-speech-empty-copy ()
  "An empty floor says so, in nouns, with its controls."
  (harness-ui-workspace-speech-test-with
    (let ((text (harness-ui-workspace-speech-test-render
                 (harness-ui-workspace-speech-test-floor))))
      (should (string-match-p "\\`Speech · No speech" text))
      (should (string-match-p "\\[Hold\\]" text))
      (should (string-match-p "\\[Refresh\\]" text))
      (should (string-match-p "Nothing to say" text))
      (should-not (string-match-p "Waiting" text))
      (should-not (string-match-p "Solo" text)))))

(ert-deftest harness-ui-workspace-speech-waiting-copy ()
  "A waiting floor names its threads, in order, with the count."
  (harness-ui-workspace-speech-test-with
    (let* ((one (harness-ui-workspace-speech-test-entry
                 :id "sp-1" :thread "th-1" :thread-title "Kitchen renovation"
                 :preview "The quote is accepted."))
           (two (harness-ui-workspace-speech-test-entry
                 :id "sp-2" :thread "th-2" :thread-title "Garden lights"
                 :preview "The timer works."))
           (text (harness-ui-workspace-speech-test-render
                  (harness-ui-workspace-speech-test-floor
                   :waiting (list one two) :count 2))))
      (should (string-match-p "\\`Speech · 2 waiting" text))
      (should (string-match-p "Waiting · 2" text))
      (should (string-match-p "Kitchen renovation" text))
      (should (string-match-p "The quote is accepted." text))
      (should (string-match-p "Garden lights" text))
      ;; The order the floor gave is the order the panel draws.
      (should (< (string-match "Kitchen renovation" text)
                 (string-match "Garden lights" text)))
      (should (string-match-p "\\[Solo\\]" text))
      (should (equal "Speech · solo"
                     (harness-ui-workspace-speech-test-help text "[Solo]")))
      (should (equal "Speech · hold"
                     (harness-ui-workspace-speech-test-help text "[Hold]")))
      (should (equal "Speech · refresh"
                     (harness-ui-workspace-speech-test-help text "[Refresh]"))))))

(ert-deftest harness-ui-workspace-speech-speaking-copy ()
  "The thread speaking is named, with its position, hold and skip."
  (harness-ui-workspace-speech-test-with
    (let* ((entry (harness-ui-workspace-speech-test-entry
                   :state "speaking" :thread-title "Kitchen renovation"
                   :preview "The quote is accepted."))
           (text (harness-ui-workspace-speech-test-render
                  (harness-ui-workspace-speech-test-floor
                   :speaking entry :active "th-1"))))
      (should (string-match-p "\\`Speech · Speaking" text))
      (should (string-match-p "Speaking · Kitchen renovation" text))
      (should (string-match-p "\\[Hold\\]" text))
      (should (string-match-p "\\[Skip\\]" text))
      (should (equal "Speech · skip"
                     (harness-ui-workspace-speech-test-help text "[Skip]")))
      (should-not (string-match-p "Solo · " text)))))

(ert-deftest harness-ui-workspace-speech-solo-copy ()
  "A solo is named, held entries say why, and leaving is one click."
  (harness-ui-workspace-speech-test-with
    (let* ((held (harness-ui-workspace-speech-test-entry
                  :id "sp-2" :thread "th-2" :thread-title "Garden lights"
                  :held "Solo" :preview "The timer works."))
           (text (harness-ui-workspace-speech-test-render
                  (harness-ui-workspace-speech-test-floor
                   :solo "th-1" :solo-title "Kitchen renovation"
                   :waiting (list held) :count 1))))
      (should (string-match-p "\\`Speech · Solo" text))
      (should (string-match-p "Solo · Kitchen renovation" text))
      (should (string-match-p "\\[Leave solo\\]" text))
      (should (string-match-p "Garden lights  Solo" text))
      (should (equal "Speech · leave solo"
                     (harness-ui-workspace-speech-test-help text "[Leave solo]")))
      ;; A held thread offers the solo of its own, to move the floor to it,
      ;; and the soloed floor offers its way out.
      (should (string-match-p "Garden lights  Solo  \\[Solo\\]" text)))))

(ert-deftest harness-ui-workspace-speech-held-copy ()
  "A hold names the held words and offers the resume."
  (harness-ui-workspace-speech-test-with
    (let* ((entry (harness-ui-workspace-speech-test-entry
                   :state "held" :played 4.0 :thread-title "Kitchen renovation"
                   :preview "The quote is accepted."))
           (text (harness-ui-workspace-speech-test-render
                  (harness-ui-workspace-speech-test-floor
                   :hold t :held t :speaking entry :active "th-1"))))
      (should (string-match-p "\\`Speech · Held" text))
      (should (string-match-p "Held · Kitchen renovation  4s" text))
      (should (string-match-p "\\[Resume\\]" text))
      (should (equal "Speech · resume"
                     (harness-ui-workspace-speech-test-help text "[Resume]")))
      (should-not (string-match-p "Nothing to say" text)))))

(ert-deftest harness-ui-workspace-speech-recent-copy ()
  "What was said, failed or cancelled is shown with its reason."
  (harness-ui-workspace-speech-test-with
    (let* ((done (harness-ui-workspace-speech-test-entry
                  :id "sp-1" :state "finished" :outcome "finished"
                  :thread-title "Kitchen renovation"))
           (failed (harness-ui-workspace-speech-test-entry
                    :id "sp-2" :state "failed" :outcome "failed"
                    :why "Playback failed" :thread-title "Garden lights"))
           (interrupted (harness-ui-workspace-speech-test-entry
                         :id "sp-3" :state "cancelled" :outcome "interrupted"
                         :why "Solo" :thread-title "Harness memory"))
           (text (harness-ui-workspace-speech-test-render
                  (harness-ui-workspace-speech-test-floor
                   :recent (list interrupted failed done)))))
      (should (string-match-p "Recent" text))
      (should (string-match-p "Cancelled · Solo" text))
      (should (string-match-p "Failed · Playback failed" text))
      (should (string-match-p "Spoken · finished" text))
      ;; The count line stays a state, not a sentence.
      (should (string-match-p "\\`Speech · Idle" text)))))

(ert-deftest harness-ui-workspace-speech-a-stale-answer-changes-nothing ()
  "An older revision never rolls the panel back."
  (harness-ui-workspace-speech-test-with
    (let ((fresh (harness-ui-workspace-speech-test-floor :revision 9 :count 3))
          (stale (harness-ui-workspace-speech-test-floor :revision 4 :count 0)))
      (should (harness-workspace-speech--note "w-1" fresh))
      (should-not (harness-workspace-speech--note "w-1" stale))
      (should (= 9 (plist-get (harness-workspace-speech--floor "w-1") :revision)))
      ;; The same revision is taken: a client may need its own answer.
      (should (harness-workspace-speech--note
               "w-1" (harness-ui-workspace-speech-test-floor :revision 9 :count 1)))
      (should (= 1 (plist-get (harness-workspace-speech--floor "w-1") :count))))))

(ert-deftest harness-ui-workspace-speech-count-labels ()
  "The one-line state of the floor is a noun phrase in every state."
  (harness-ui-workspace-speech-test-with
    (let ((case-fold-search nil))
      (should (equal "No speech"
                     (harness-workspace-speech--count-label
                      (harness-ui-workspace-speech-test-floor))))
      (should (equal "2 waiting"
                     (harness-workspace-speech--count-label
                      (harness-ui-workspace-speech-test-floor :count 2))))
      (should (equal "Speaking"
                     (harness-workspace-speech--count-label
                      (harness-ui-workspace-speech-test-floor
                       :speaking (harness-ui-workspace-speech-test-entry)))))
      (should (equal "Solo"
                     (harness-workspace-speech--count-label
                      (harness-ui-workspace-speech-test-floor :solo "th-1"))))
      (should (equal "Held"
                     (harness-workspace-speech--count-label
                      (harness-ui-workspace-speech-test-floor :hold t))))
      (should (equal "Idle"
                     (harness-workspace-speech--count-label
                      (harness-ui-workspace-speech-test-floor
                       :recent (list (harness-ui-workspace-speech-test-entry)))))))))

(ert-deftest harness-ui-workspace-speech-a-thread-of-another-workspace-is-not-shown ()
  "The panel draws the floor it was given, and names no other thread."
  (harness-ui-workspace-speech-test-with
    (let* ((entry (harness-ui-workspace-speech-test-entry
                   :thread "th-secret" :thread-title "Private thread"))
           (text (harness-ui-workspace-speech-test-render
                  (harness-ui-workspace-speech-test-floor
                   :waiting (list entry) :count 1))))
      ;; What the harness answered is what the panel shows; a thread it
      ;; did not answer is not invented here.
      (should (string-match-p "Private thread" text))
      (should-not (string-match-p "Harness memory" text)))))

(ert-deftest harness-ui-workspace-speech-the-speaker-stays-quiet-under-a-hold ()
  "A held floor starts no utterance, and a quiet client never speaks."
  (harness-ui-workspace-speech-test-with
    (let* ((entry (harness-ui-workspace-speech-test-entry :state "held"))
           (calls nil))
      (puthash "w-1" (harness-ui-workspace-speech-test-floor
                      :hold t :speaking entry :active "th-1")
               harness-workspace-speech--floors)
      (cl-letf (((symbol-function 'harness-workspace-speech--claim-and-speak)
                 (lambda (&rest _) (push 'spoke calls))))
        (harness-workspace-speech--pump "w-1")
        (should (null calls))
        ;; With the hold off but the client told to stay quiet, still none.
        (puthash "w-1" (harness-ui-workspace-speech-test-floor
                        :speaking (harness-ui-workspace-speech-test-entry
                                   :state "speaking"))
                 harness-workspace-speech--floors)
        (let ((harness-workspace-speech-speak nil))
          (harness-workspace-speech--pump "w-1"))
        (should (null calls))
        ;; A busy client claims nothing twice.
        (let ((harness-workspace-speech--busy t))
          (harness-workspace-speech--pump "w-1"))
        (should (null calls))
        ;; An eligible floor asks for the entry once.
        (harness-workspace-speech--pump "w-1")
        (should (equal '(spoke) calls))))))

(ert-deftest harness-ui-workspace-speech-a-second-client-does-not-speak ()
  "A claim held by another client keeps this one silent."
  (harness-ui-workspace-speech-test-with
    (let ((spoke nil)
          (answer '(:claimed nil :applied nil :holder "phone")))
      (cl-letf (((symbol-function 'harness-workspace-speech--synthesize-and-play)
                 (lambda (&rest _) (setq spoke t)))
                ((symbol-function 'harness-ui-call)
                 (lambda (_method _params callback &optional _on-error)
                   (funcall callback answer))))
        (harness-workspace-speech--claim-and-speak
         "w-1" "sp-1" (harness-ui-workspace-speech-test-entry :state "speaking"))
        (should-not spoke)
        (should-not harness-workspace-speech--busy)))))

(ert-deftest harness-ui-workspace-speech-the-spoken-text-has-no-markup ()
  "The words spoken are the words, without markup or fences."
  (harness-ui-workspace-speech-test-with
    (dolist (case '(("The **quote** is `accepted`." . "The quote is accepted.")
                    ("See [the docs](https://example.com/x)." . "See the docs.")
                    ("```\ncode\n```\nAfter." . "After.")))
      (should (equal (cdr case)
                     (harness-workspace-speech--spoken-text (car case)))))))

(provide 'harness-ui-workspace-speech-test)
;;; harness-ui-workspace-speech-test.el ends here
