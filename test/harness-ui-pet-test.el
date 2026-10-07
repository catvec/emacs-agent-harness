;;; harness-ui-pet-test.el --- Tests for the companion pet's buffer  -*- lexical-binding: t; -*-
;;; Commentary:

;; The pet's buffer against the real state layer, the in-process ACP
;; connection and the demo provider: the art of every species, the egg
;; and its [Hatch it], the card it hatches into, what it says on a band
;; of its own, a narrow window, the harness told while the buffer is on
;; screen and no longer once it goes, and animations that stop on their
;; own.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-sessions)
(defvar harness-model)
(defvar harness-pet--pet)
(defvar harness-pet--loaded)
(defvar harness-pet--dirty)
(defvar harness-pet--watchers)
(defvar harness-pet--hatching)
(defvar harness-pet--speaking)
(defvar harness-pet--last-unasked)
(defvar harness-pet--last-spoke)
(defvar harness-pet--last-pet)
(defvar harness-pet--save-timer)
(defvar harness-pet-reactions)
(defvar harness-pet-model)
(defvar harness-pet-chance)
(defvar harness-pet-cooldown)
(defvar harness-pet-species)
(defvar harness-pet-eyes)
(defvar harness-pet-hats)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui--sessions)
(defvar harness-ui-default-position)
(defvar harness-ui-pet-animations)
(defvar harness-ui-pet--sprites)
(defvar harness-ui-pet--heads)
(defvar harness-ui-pet--hats)
(defvar harness-ui-pet--hearts)
(defvar harness-ui-pet--sparkles)
(defvar harness-ui-pet--stats-column)
(defvar harness-ui-pet--view)
(defvar harness-ui-pet--anim)
(defvar harness-ui-pet--queued)
(defvar harness-ui-pet--timer)
(defvar harness-ui-pet--error)
(declare-function harness-pet "harness-ui-pet")
(declare-function harness-ui-pet-art "harness-ui-pet")
(declare-function harness-ui-pet--header "harness-ui-pet")
(declare-function harness-ui-pet--render "harness-ui-pet")
(declare-function harness-ui-pet--animate "harness-ui-pet")
(declare-function harness-ui-pet--step "harness-ui-pet")
(declare-function harness-ui-pet--on-event "harness-ui-pet")
(declare-function harness-ui-pet--shutdown "harness-ui-pet")
(declare-function harness-ui-pet--window-width "harness-ui-pet")
(declare-function harness-ui-pet-hatch "harness-ui-pet")
(declare-function harness-ui-pet-pet "harness-ui-pet")
(declare-function harness-ui-pet-rename "harness-ui-pet")
(declare-function harness-ui-pet-toggle-mute "harness-ui-pet")
(declare-function harness-ui-pet-release "harness-ui-pet")
(declare-function harness-ui-pet-refresh "harness-ui-pet")
(declare-function harness-ui-pet--stop "harness-ui-pet")
(declare-function harness-ui-pet--shown-p "harness-ui-pet")
(declare-function harness-ui-pet--update-watch "harness-ui-pet")
(declare-function harness-ui-pet--when "harness-ui-pet")
(declare-function harness-acp--drop-client "harness-acp")

(defconst harness-ui-pet-test--buffer "*harness pet*")

(defun harness-ui-pet-test-reset ()
  "Forget the pet the harness knows of, as a fresh harness would."
  (when (timerp harness-pet--save-timer) (cancel-timer harness-pet--save-timer))
  (setq harness-pet--pet nil harness-pet--loaded nil harness-pet--dirty nil
        harness-pet--hatching nil harness-pet--speaking nil harness-pet--save-timer nil
        harness-pet--last-unasked 0 harness-pet--last-spoke 0 harness-pet--last-pet 0)
  (clrhash harness-pet--watchers))

(defmacro harness-ui-pet-test-with (&rest body)
  "Load the state layer with the pet and the demo provider, then the UI; run BODY.
The pet speaks with the demo model each time it may (chance 1, no
cooldown).  Animations are off unless BODY turns them on; views take
the whole frame."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent pet acp))
         (harness-test-load-module m)))
     (harness-ui-pet-test-reset)
     (clrhash harness-sessions)
     (setq harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-acp-token nil)
           (harness-model "demo:scripted")
           (harness-pet-model "demo:scripted")
           (harness-pet-reactions t)
           (harness-pet-chance 1)
           (harness-pet-cooldown 0)
           (harness-ui-pet-animations nil)
           (harness-ui-default-position 'full)
           (default-directory dir))
       ;; The UI modules load once the client list is clear, so their
       ;; connection is the one the harness events reach.
       (harness-test-load-module 'ui)
       (harness-test-load-module 'ui-pet)
       (clrhash harness-ui--sessions)
       (unwind-protect (progn ,@body)
         (when (get-buffer harness-ui-pet-test--buffer)
           (kill-buffer harness-ui-pet-test--buffer))
         (harness-ui-pet--shutdown)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))
         (harness-ui-pet-test-reset)))))

(defun harness-ui-pet-test--text ()
  "The pet's buffer as plain text."
  (with-current-buffer harness-ui-pet-test--buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-pet-test--flat-text ()
  "The pet's buffer as plain text, its runs of whitespace one space."
  (replace-regexp-in-string "[ \t\n]+" " " (harness-ui-pet-test--text)))

(defun harness-ui-pet-test--wait-text (regexp)
  "Wait until the pet's buffer shows REGEXP."
  (harness-test-wait (lambda () (string-match-p regexp (harness-ui-pet-test--text)))
                     5 (format "the pet's buffer to show %s" regexp)))

(defun harness-ui-pet-test--open ()
  "Open the pet's buffer and wait for the pet; return the buffer."
  (harness-pet)
  (harness-test-wait (lambda () (buffer-local-value 'harness-ui-pet--view
                                                    (get-buffer harness-ui-pet-test--buffer)))
                     5 "the pet to arrive")
  (get-buffer harness-ui-pet-test--buffer))

(defun harness-ui-pet-test--hatch ()
  "Hatch the egg from the open buffer and wait for its first words."
  (with-current-buffer harness-ui-pet-test--buffer (harness-ui-pet-hatch))
  (harness-test-wait (lambda () (plist-get (buffer-local-value 'harness-ui-pet--view
                                                               (get-buffer harness-ui-pet-test--buffer))
                                           :said))
                     5 "the pet's first words"))

(defun harness-ui-pet-test--line-of (regexp)
  "The text of the line of the pet's buffer that matches REGEXP, or nil."
  (with-current-buffer harness-ui-pet-test--buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward regexp nil t)
        (buffer-substring-no-properties (line-beginning-position) (line-end-position))))))

;;;; The art

(ert-deftest harness-ui-pet-art-draws-every-species ()
  "Every species has three frames of five lines, clear of the stats beside it."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (should (equal (sort (mapcar #'car harness-ui-pet--sprites) #'string<)
                 (sort (copy-sequence harness-pet-species) #'string<)))
  (dolist (species harness-pet-species)
    (should (= 3 (length (alist-get species harness-ui-pet--sprites))))
    (should (alist-get species harness-ui-pet--heads))
    (dotimes (frame 3)
      (dolist (eye harness-pet-eyes)
        (let ((art (harness-ui-pet-art species eye 'none frame)))
          (should (= 5 (length art)))
          (dolist (line art)
            (should-not (string-search "{E}" line))
            ;; Drawn at 1.25 times the size, two columns in: short of the stats.
            (should (<= (+ 2 (* 1.25 (string-width line))) harness-ui-pet--stats-column)))
          (when (= frame 0)
            (should (string-search eye (string-join art "\n")))))))))

(ert-deftest harness-ui-pet-art-wears-its-hat ()
  "A hat sits on the first line, over the head; none leaves it be."
  (require 'harness-pet)
  (require 'harness-ui-pet)
  (dolist (hat (remq 'none harness-pet-hats))
    (should (assq hat harness-ui-pet--hats)))
  (dolist (species harness-pet-species)
    (let ((head (alist-get species harness-ui-pet--heads))
          (blank (string-blank-p (car (harness-ui-pet-art species "o" 'none 0)))))
      (dolist (hat (remq 'none harness-pet-hats))
        (let* ((drawn (alist-get hat harness-ui-pet--hats))
               (line (car (harness-ui-pet-art species "o" hat 0))))
          (if (not blank)
              (should (equal line (car (harness-ui-pet-art species "o" 'none 0))))
            (should (string-suffix-p drawn line))
            ;; Centred on the head, within a column.
            (let ((middle (+ (- (length line) (length drawn)) (/ (1- (length drawn)) 2.0))))
              (should (<= (abs (- middle head)) 1.0))))))))
  ;; Hats and species by name work as strings too, as they come from the wire.
  (should (equal (harness-ui-pet-art 'duck "o" 'crown 0) (harness-ui-pet-art "duck" "o" "crown" 0)))
  ;; A frame that draws above the head keeps that over a hat.
  (should (string-search "~" (car (harness-ui-pet-art 'dragon "o" 'crown 2))))
  ;; An unknown species is drawn as a blob, not an error.
  (should (equal (harness-ui-pet-art 'blob "o" 'none 0) (harness-ui-pet-art 'gryphon "o" 'none 0))))

;;;; The buffer

(ert-deftest harness-ui-pet-egg-hatches-into-a-card ()
  "The egg offers [Hatch it]; hatched, the card shows the pet and its first words."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (should (eq buf (window-buffer (selected-window))))
      (should (with-current-buffer buf (derived-mode-p 'harness-ui-pet-mode)))
      (let ((text (harness-ui-pet-test--text)))
        (should (string-match-p "An egg" text))
        (should (string-match-p "Hatch it" text))
        (should (string-match-p "one of 18 species" text)))
      (should (string-match-p "Hatch" (format "%s" (with-current-buffer buf (harness-ui-pet--header)))))
      (harness-ui-pet-test--hatch)
      (let* ((view (buffer-local-value 'harness-ui-pet--view buf))
             (text (harness-ui-pet-test--flat-text)))
        (should (eq t (plist-get view :hatched)))
        (should (string-match-p (regexp-quote (plist-get view :name)) text))
        (should (string-match-p (upcase (plist-get view :species)) text))
        (should (string-match-p (upcase (plist-get view :rarity)) text))
        (should (string-match-p "Level 1" text))
        (should (string-match-p "rates every function by how it would taste" text))
        (dolist (stat '("DEBUGGING" "PATIENCE" "CHAOS" "WISDOM" "SNARK"))
          (should (string-match-p stat text)))
        (should (string-match-p "now and then has a word to say, through .*m mutes it" text)))
      ;; Its first words, the action set apart without its asterisks, on the band.
      (harness-ui-pet-test--wait-text "Is it always this bright in here")
      (with-current-buffer buf
        (goto-char (point-min))
        (search-forward "blinks")
        (should-not (eq ?* (char-after (match-end 0))))
        (should (memq 'harness-pet-action-face (ensure-list (get-text-property (match-beginning 0) 'face))))
        (search-forward "bright")
        (should (memq 'harness-pet-speech-face (ensure-list (get-text-property (match-beginning 0) 'face)))))
      (let ((header (format "%s" (with-current-buffer buf (harness-ui-pet--header)))))
        (dolist (label '("Pet" "Rename" "Mute" "Release"))
          (should (string-match-p label header)))
        (should-not (string-match-p "Hatch" header))))))

(ert-deftest harness-ui-pet-buttons-reach-the-harness ()
  "Petting, renaming, muting and releasing go to the harness, and show."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      ;; Asked, it answers at once, but not within seconds of its greeting.
      (setq harness-pet--last-spoke 0)
      (with-current-buffer buf (harness-ui-pet-pet))
      (harness-ui-pet-test--wait-text "petted 1 time")
      (harness-ui-pet-test--wait-text "Yes\\. That\\.")
      (with-current-buffer buf (harness-ui-pet-rename "Pickle"))
      (harness-ui-pet-test--wait-text "Pickle")
      (should (equal "Pickle" (plist-get harness-pet--pet :name)))
      (with-current-buffer buf (harness-ui-pet-toggle-mute))
      (harness-ui-pet-test--wait-text "Muted: it asks no model anything")
      (should (string-match-p "Unmute" (format "%s" (with-current-buffer buf (harness-ui-pet--header)))))
      (with-current-buffer buf (harness-ui-pet-toggle-mute))
      (harness-ui-pet-test--wait-text "now and then has a word to say")
      (with-current-buffer buf (harness-ui-pet-release t))
      (harness-ui-pet-test--wait-text "An egg")
      (should-not harness-pet--pet))))

(ert-deftest harness-ui-pet-fits-a-narrow-window ()
  "Beside the creature in a wide window, the stats go below it in a narrow one,
and the prose is filled to the window."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (harness-ui-pet-test--wait-text "Is it always this bright")
      (cl-letf (((symbol-function 'harness-ui-pet--window-width) (lambda () 100)))
        (with-current-buffer buf (harness-ui-pet--render))
        ;; The second stat shares a line with the creature's head.
        (should (string-match-p "\\S-.*PATIENCE" (harness-ui-pet-test--line-of "PATIENCE"))))
      (cl-letf (((symbol-function 'harness-ui-pet--window-width) (lambda () 44)))
        (with-current-buffer buf (harness-ui-pet--render))
        (should (string-match-p "\\`\\s-*PATIENCE" (harness-ui-pet-test--line-of "PATIENCE")))
        ;; Prose wraps short of the edge; only the stats' meters may reach it.
        (dolist (line (split-string (harness-ui-pet-test--text) "\n"))
          (unless (string-match-p "DEBUGGING\\|PATIENCE\\|CHAOS\\|WISDOM\\|SNARK" line)
            (should (<= (string-width line) 44))))
        (should (string-match-p "rates every function by how it would taste"
                                (harness-ui-pet-test--flat-text)))))))

(ert-deftest harness-ui-pet-tells-the-harness-while-shown ()
  "The harness hears the buffer is on screen, and that it left the screen."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-test-wait (lambda () (> (hash-table-count harness-pet--watchers) 0)) 5 "the watch")
      ;; Redisplay runs the hook as windows change buffers; a batch Emacs
      ;; does not redisplay, so the test runs it.
      (should (memq #'harness-ui-pet--update-watch window-buffer-change-functions))
      ;; Another buffer in its window: not on screen any more.
      (switch-to-buffer (get-buffer-create "*harness-ui-pet-test other*"))
      (harness-ui-pet--update-watch (selected-frame))
      (harness-test-wait (lambda () (= 0 (hash-table-count harness-pet--watchers))) 5 "the watch to end")
      ;; Changes that leave it as it was tell the harness nothing.
      (cl-letf (((symbol-function 'harness-ui-call) (lambda (&rest _) (error "Told the harness again"))))
        (harness-ui-pet--update-watch (selected-frame)))
      ;; Back, then killed.
      (switch-to-buffer buf)
      (harness-ui-pet--update-watch (selected-frame))
      (harness-test-wait (lambda () (> (hash-table-count harness-pet--watchers) 0)) 5 "the watch again")
      (kill-buffer buf)
      (harness-test-wait (lambda () (= 0 (hash-table-count harness-pet--watchers))) 5 "the watch to end at last")
      (kill-buffer "*harness-ui-pet-test other*"))))

(ert-deftest harness-ui-pet-follows-events ()
  "The buffer follows `pet/changed' from elsewhere, and says when there is no pet module."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      ;; Hatched from another UI, or by the harness itself.
      (harness-test-await (harness-call 'pet/hatch))
      (harness-test-wait (lambda () (plist-get (buffer-local-value 'harness-ui-pet--view buf) :name))
                         5 "the pet hatched elsewhere")
      (harness-ui-pet-test--wait-text (regexp-quote (plist-get harness-pet--pet :name)))
      ;; A harness without the pet module.
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (_method _params _callback &optional errback)
                   (funcall errback (list 'error "Method not found: _harness/pet/get")))))
        (with-current-buffer buf (harness-ui-pet-refresh)))
      (should (string-match-p "The harness has no pet" (harness-ui-pet-test--text))))))

(ert-deftest harness-ui-pet-names-the-session-a-saying-is-about ()
  "A saying names its session, by the name it has now when it had none then."
  (harness-ui-pet-test-with
    (let ((now (float-time)))
      (should (equal "just now, about Parser work"
                     (harness-ui-pet--when (list :ts now :session "s1" :session-name "Parser work"))))
      (should (equal "just now" (harness-ui-pet--when (list :ts now :session "s2" :session-name nil))))
      (puthash "s2" (list :id "s2" :name "Renaming things") harness-ui--sessions)
      (should (equal "just now, about Renaming things"
                     (harness-ui-pet--when (list :ts now :session "s2" :session-name nil))))
      (should (equal "just now" (harness-ui-pet--when (list :ts now :session nil :session-name "  ")))))))

;;;; Animations

(ert-deftest harness-ui-pet-animations-stop-on-their-own ()
  "Each animation is a few frames on a timer that ends with it."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (with-current-buffer buf
        (let ((harness-ui-pet-animations t))
          (should-not harness-ui-pet--anim)
          (dolist (kind '(hearts sparkle fidget))
            (harness-ui-pet--animate kind)
            (should (timerp harness-ui-pet--timer))
            (should (eq kind (plist-get harness-ui-pet--anim :kind)))
            (let ((steps 0))
              (while (and harness-ui-pet--anim (< steps 20))
                (harness-ui-pet--step)
                (cl-incf steps))
              (should (< steps 10)))
            (should-not harness-ui-pet--anim)
            (should-not harness-ui-pet--timer))
          ;; Hearts show above the creature while they play, in their own colour.
          (harness-ui-pet--animate 'hearts)
          (harness-ui-pet--step)
          (should (string-search (string-trim (nth 1 harness-ui-pet--hearts)) (harness-ui-pet-test--text)))
          (goto-char (point-min))
          (search-forward "♥")
          (let ((faces (ensure-list (get-text-property (match-beginning 0) 'face))))
            (should (eq 'harness-pet-heart-face (car faces)))
            (should (memq 'harness-pet-art-face (flatten-tree faces))))
          (harness-ui-pet--stop)
          (should-not harness-ui-pet--timer)
          ;; Its first words come as it hatches: it fidgets once the sparkles end.
          (harness-ui-pet--animate 'sparkle)
          (harness-ui-pet--on-event "pet/said" (list (list :text "hi")))
          (should (eq 'sparkle (plist-get harness-ui-pet--anim :kind)))
          (should (eq 'fidget harness-ui-pet--queued))
          (let ((kinds nil))
            (while harness-ui-pet--anim
              (push (plist-get harness-ui-pet--anim :kind) kinds)
              (harness-ui-pet--step))
            (should (equal '(sparkle fidget) (delete-dups (nreverse kinds)))))
          (should-not harness-ui-pet--timer))))))

(ert-deftest harness-ui-pet-animations-only-on-screen ()
  "Nothing moves off screen or with animations off; leaving the screen stops it."
  (harness-ui-pet-test-with
    (let ((buf (harness-ui-pet-test--open)))
      (harness-ui-pet-test--hatch)
      (with-current-buffer buf
        (setq harness-ui-pet--anim nil)
        ;; Off by option.
        (let ((harness-ui-pet-animations nil))
          (harness-ui-pet--animate 'hearts)
          (should-not harness-ui-pet--timer)
          (should-not harness-ui-pet--anim))
        (let ((harness-ui-pet-animations t))
          ;; Off screen.
          (cl-letf (((symbol-function 'harness-ui-pet--shown-p) #'ignore))
            (harness-ui-pet--animate 'hearts)
            (should-not harness-ui-pet--timer))
          ;; Leaving the screen mid-animation stops it at the next frame.
          (harness-ui-pet--animate 'hearts)
          (should (timerp harness-ui-pet--timer))
          (cl-letf (((symbol-function 'harness-ui-pet--shown-p) #'ignore))
            (harness-ui-pet--step))
          (should-not harness-ui-pet--timer)
          (should-not harness-ui-pet--anim))))))

(provide 'harness-ui-pet-test)
;;; harness-ui-pet-test.el ends here
