;;; harness-pet-test.el --- Tests for the companion pet  -*- lexical-binding: t; -*-
;;; Commentary:

;; The companion pet: bones rolled from a seed (checked against the
;; JavaScript the generator comes from), hatching with a name from a
;; cheap model or without one, growing, and when it speaks -- only while
;; a UI shows it, unmuted, with reactions on, unasked by chance after a
;; cooldown, asked every time -- and when it does not.

;;; Code:

(require 'harness-test-helpers)

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
(defvar harness-pet-enabled)
(defvar harness-pet-model)
(defvar harness-pet-chance)
(defvar harness-pet-cooldown)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(declare-function harness-pet--hash "harness-pet")
(declare-function harness-pet--rng "harness-pet")
(declare-function harness-pet-roll "harness-pet")
(declare-function harness-pet--inspiration "harness-pet")
(declare-function harness-pet-level "harness-pet")
(declare-function harness-pet-level-xp "harness-pet")
(declare-function harness-pet-sanitise "harness-pet")
(declare-function harness-pet-turn-reason "harness-pet")
(declare-function harness-pet-flush "harness-pet")
(declare-function harness-pet--soul "harness-pet")
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp-set-handler "harness-acp")
(declare-function harness-acp-close "harness-acp")

(defun harness-pet-test-reset ()
  "Forget the pet this process knows of, as a fresh process would."
  (when (timerp harness-pet--save-timer) (cancel-timer harness-pet--save-timer))
  (setq harness-pet--pet nil harness-pet--loaded nil harness-pet--dirty nil
        harness-pet--hatching nil harness-pet--speaking nil harness-pet--save-timer nil
        harness-pet--last-unasked 0 harness-pet--last-spoke 0 harness-pet--last-pet 0)
  (clrhash harness-pet--watchers))

(defmacro harness-pet-test-with (&rest body)
  "Load the state layer with the demo provider and the pet; run BODY.
The pet speaks with the demo model, every time it may (chance 1, no
cooldown), and no UI shows it until BODY says one does."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent pet acp))
         (harness-test-load-module m)))
     (harness-pet-test-reset)
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
           (default-directory dir))
       (unwind-protect (progn ,@body)
         (harness-pet-test-reset)))))

(defun harness-pet-test-session ()
  "Create a demo session; return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted" :name "Parser work")
             :id))

(defun harness-pet-test-hatch ()
  "Hatch the pet with the demo model; return the view."
  (harness-test-await (harness-call 'pet/hatch)))

(defun harness-pet-test-watch (&optional on)
  "Have a UI show the pet (ON nil) or stop showing it."
  (harness-call 'pet/watch "test-ui" (if (eq on 'off) :false t)))

(defmacro harness-pet-test-counting-requests (var &rest body)
  "Run BODY with VAR collecting the requests made to providers, newest first."
  (declare (indent 1))
  `(let ((,var nil))
     (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                ((symbol-function 'harness-method/provider/complete)
                 (lambda (req) (push req ,var) (funcall orig req))))
       ,@body)))

(defun harness-pet-test-request-text (request)
  "The text of the last message of REQUEST."
  (plist-get (car (plist-get (car (last (plist-get request :messages))) :content)) :text))

(defun harness-pet-test-said ()
  "Collect what the pet says from now on; return a function that lists it, oldest first."
  (let ((said nil))
    (harness-on 'pet/said (lambda (saying) (push saying said)))
    (lambda () (reverse said))))

;;;; Bones

(ert-deftest harness-pet-hash-and-generator-match-javascript ()
  "FNV-1a and Mulberry32 give what the JavaScript they come from gives."
  (require 'harness-pet)
  ;; node -e: the 32-bit FNV-1a by charCodeAt, and mulberry32(42) thrice.
  (should (= 1335831723 (harness-pet--hash "hello")))
  (should (= 2166136261 (harness-pet--hash "")))
  (should (= 4143183268 (harness-pet--hash "harness-pet-2026")))
  (let ((rng (harness-pet--rng 42)))
    (should (= 0.6011037519201636 (funcall rng)))
    (should (= 0.44829055899754167 (funcall rng)))
    (should (= 0.8524657934904099 (funcall rng)))))

(ert-deftest harness-pet-roll-is-fixed-by-the-seed ()
  "A seed always makes the same pet, the one the JavaScript port makes."
  (require 'harness-pet)
  (should (equal '(:rarity uncommon :species axolotl :eye "✦" :hat tinyduck :shiny nil
                   :stats (:debugging 45 :patience 37 :chaos 28 :wisdom 14 :snark 87)
                   :inspiration 868700438)
                 (harness-pet-roll "a")))
  (should (equal '(:rarity epic :species duck :eye "·" :hat crown :shiny nil
                   :stats (:debugging 100 :patience 26 :chaos 63 :wisdom 54 :snark 68)
                   :inspiration 271547805)
                 (harness-pet-roll "seed-1")))
  (should (equal (harness-pet-roll "f47ac10b-58cc-4372-a567-0e02b2c3d479")
                 (harness-pet-roll "f47ac10b-58cc-4372-a567-0e02b2c3d479"))))

(ert-deftest harness-pet-roll-follows-the-tables ()
  "Over many seeds: rarities by their weights, every species, hats and stats in bounds."
  (require 'harness-pet)
  (let ((rarities (make-hash-table)) (species (make-hash-table)) (shiny 0) (n 4000))
    (dotimes (i n)
      (let* ((bones (harness-pet-roll (format "seed-%d" i)))
             (rarity (plist-get bones :rarity))
             (floor (plist-get (cdr (assq rarity harness-pet-rarities)) :floor))
             (stats (plist-get bones :stats))
             (values (cl-loop for (_k v) on stats by #'cddr collect v)))
        (cl-incf (gethash rarity rarities 0))
        (cl-incf (gethash (plist-get bones :species) species 0))
        (when (plist-get bones :shiny) (cl-incf shiny))
        (should (member (plist-get bones :eye) harness-pet-eyes))
        (should (memq (plist-get bones :hat) harness-pet-hats))
        ;; A common pet never wears a hat.
        (when (eq rarity 'common) (should (eq 'none (plist-get bones :hat))))
        (should (= 5 (length values)))
        ;; One stat peaks, one sags (to at most 4 over the floor); none leaves 1..100.
        (should (cl-every (lambda (v) (<= 1 v 100)) values))
        (should (cl-some (lambda (v) (>= v (min 100 (+ floor 50)))) values))
        (should (cl-some (lambda (v) (<= v (+ floor 4))) values))
        (should (<= (cl-count-if (lambda (v) (< v floor)) values) 1))
        (should (natnump (plist-get bones :inspiration)))))
    (should (= 18 (hash-table-count species)))
    (let ((share (lambda (r) (/ (gethash r rarities 0) (float n)))))
      (should (< 0.55 (funcall share 'common) 0.65))
      (should (< 0.21 (funcall share 'uncommon) 0.29))
      (should (< 0.07 (funcall share 'rare) 0.13))
      (should (< 0.02 (funcall share 'epic) 0.06))
      (should (< 0.0 (funcall share 'legendary) 0.025)))
    (should (< 0 shiny (* n 0.03)))))

(ert-deftest harness-pet-inspiration-words ()
  (require 'harness-pet)
  (let ((words (harness-pet--inspiration 868700438)))
    (should (= 4 (length words)))
    (should (= 4 (length (delete-dups (copy-sequence words)))))
    (should (equal words (harness-pet--inspiration 868700438)))
    (should-not (equal words (harness-pet--inspiration 271547805)))))

(ert-deftest harness-pet-levels ()
  (require 'harness-pet)
  (should (= 1 (harness-pet-level 0)))
  (should (= 1 (harness-pet-level 9)))
  (should (= 2 (harness-pet-level 10)))
  (should (= 2 (harness-pet-level 29)))
  (should (= 3 (harness-pet-level 30)))
  (should (= 4 (harness-pet-level 60)))
  (should (= 10 (harness-pet-level 450)))
  (should (= 1 (harness-pet-level nil)))
  (dotimes (level 30)
    (let ((level (1+ level)))
      (should (= level (harness-pet-level (harness-pet-level-xp level))))
      (should (= level (harness-pet-level (1- (harness-pet-level-xp (1+ level)))))))))

(ert-deftest harness-pet-sanitise ()
  (require 'harness-pet)
  (should (equal "*tilts head* Bold." (harness-pet-sanitise "  \"*tilts head* Bold.\"  " "Fennel")))
  (should (equal "Hello there." (harness-pet-sanitise "Fennel: Hello there." "Fennel")))
  (should (equal "Hello there." (harness-pet-sanitise "**fennel**: Hello there." "Fennel")))
  (should (equal "One. Two." (harness-pet-sanitise "One.\nTwo.\nThree." "Fennel")))
  (should (null (harness-pet-sanitise "..." "Fennel")))
  (should (null (harness-pet-sanitise "  …  " "Fennel")))
  (should (null (harness-pet-sanitise "" "Fennel")))
  (should (null (harness-pet-sanitise nil "Fennel")))
  (let ((long (harness-pet-sanitise (make-string 400 ?x) "Fennel")))
    (should (<= (length long) 220))
    (should (string-suffix-p "…" long))))

(ert-deftest harness-pet-soul-without-an-answer ()
  "A model that does not answer in JSON leaves the pet a name and a personality all the same."
  (require 'harness-pet)
  (let* ((bones (harness-pet-roll "a"))
         (soul (harness-pet--soul "I cannot do that" bones)))
    (should (member (car soul) '("Biscuit" "Noodle" "Pebble" "Mochi" "Tater" "Widget" "Crouton" "Pip")))
    (should (equal "An uncommon axolotl that says little and notices everything." (cdr soul))))
  (let ((soul (harness-pet--soul "Sure! {\"name\": \"grommet the great\", \"personality\": \"Hums.\"}"
                                 (harness-pet-roll "a"))))
    (should (equal "Grommet" (car soul)))
    (should (equal "Hums." (cdr soul)))))

;;;; Hatching

(ert-deftest harness-pet-starts-as-an-egg ()
  (harness-pet-test-with
    (let ((view (harness-call 'pet/get)))
      (should (eq :false (plist-get view :hatched)))
      (should (eq :false (plist-get view :hatching)))
      (should (eq t (plist-get view :reactions))))
    (should-error (harness-call 'pet/pet) :type 'harness-error)))

(ert-deftest harness-pet-hatch-names-it-with-the-model ()
  "Hatching rolls the bones and has the cheap model name the pet, once."
  (harness-pet-test-with
    (harness-pet-test-counting-requests requests
      (let* ((changes nil)
             (_ (harness-on 'pet/changed (lambda (view) (push view changes))))
             (first (harness-call 'pet/hatch))
             (again (harness-call 'pet/hatch)))
        ;; A hatching in flight is shared.
        (should (eq first again))
        (should (eq t (plist-get (harness-call 'pet/get) :hatching)))
        (let* ((view (harness-test-await first))
               (bones (harness-pet-roll (plist-get view :seed)))
               (word (car (harness-pet--inspiration (plist-get bones :inspiration))))
               (request (car requests))
               (text (harness-pet-test-request-text request)))
          (should (eq t (plist-get view :hatched)))
          (should (eq :false (plist-get view :hatching)))
          (should (equal (capitalize word) (plist-get view :name)))
          (should (string-match-p "rates every function" (plist-get view :personality)))
          (should (equal (symbol-name (plist-get bones :species)) (plist-get view :species)))
          (should (equal (symbol-name (plist-get bones :rarity)) (plist-get view :rarity)))
          (should (equal (plist-get bones :stats) (plist-get view :stats)))
          (should (= 1 (plist-get view :level)))
          (should (= 0 (plist-get view :xp)))
          (should (= 10 (plist-get view :next-xp)))
          ;; One request: no tools, its own session id and directory, a small budget.
          (should (= 1 (length requests)))
          (should (equal "demo:scripted" (plist-get request :model)))
          (should-not (plist-get request :tools))
          ;; A one-off question, without extended thinking.
          (should (eq t (plist-get request :ephemeral)))
          (should (eq t (plist-get request :no-thinking)))
          (should (string-prefix-p "pet-" (plist-get (plist-get request :session) :id)))
          (should (string-suffix-p "/pet/" (plist-get (plist-get request :session) :cwd)))
          (should (<= (plist-get request :max-tokens) 400))
          (should (string-prefix-p "You name newly hatched coding companions" (plist-get request :system)))
          (should (string-match-p (format "Species: %s" (plist-get bones :species)) text))
          (should (string-match-p (format "Inspiration words: %s" word) text))
          ;; Hatched once: asking again hands the same pet back without a request.
          (should (equal (plist-get view :seed) (plist-get (harness-pet-test-hatch) :seed)))
          (should (= 1 (length requests)))
          ;; Announced as it started and as it ended; nobody watches, so it says nothing.
          (should (>= (length changes) 2))
          (should (eq t (plist-get (car changes) :hatched))))))
    ;; It lives on in the state directory, bones and all.
    (let ((name (plist-get harness-pet--pet :name))
          (seed (plist-get harness-pet--pet :seed)))
      (should (file-exists-p (expand-file-name "pet.json" harness-state-directory)))
      (harness-pet-test-reset)
      (let ((view (harness-call 'pet/get)))
        (should (equal name (plist-get view :name)))
        (should (equal seed (plist-get view :seed)))))))

(ert-deftest harness-pet-hatches-without-a-model ()
  "When the model fails, the pet hatches with a name of its own."
  (harness-pet-test-with
    (let* ((harness-provider-demo-script-override
            '((:type done :stop-reason error :error "no credit")))
           (view (harness-pet-test-hatch)))
      (should (eq t (plist-get view :hatched)))
      (should (member (plist-get view :name)
                      '("Biscuit" "Noodle" "Pebble" "Mochi" "Tater" "Widget" "Crouton" "Pip")))
      (should (string-match-p "says little and notices everything" (plist-get view :personality))))))

(ert-deftest harness-pet-greets-when-watched ()
  "A pet a UI shows says its first words as it hatches."
  (harness-pet-test-with
    (let ((said (harness-pet-test-said)))
      (should (eq t (plist-get (harness-pet-test-watch) :watching)))
      (harness-pet-test-hatch)
      (harness-test-wait (lambda () (funcall said)) 5 "the first words")
      (let ((saying (car (funcall said))))
        (should (equal "hatch" (plist-get saying :reason)))
        (should (string-match-p "Is it always this bright" (plist-get saying :text))))
      (harness-test-wait (lambda () (eq :false (plist-get (harness-call 'pet/get) :thinking))) 5 "quiet")
      (should (equal 1 (length (plist-get (harness-call 'pet/get) :said)))))))

;;;; Speaking

(ert-deftest harness-pet-quiet-unless-watched-unmuted-and-on ()
  "No request at all while no UI shows the pet, while it is muted or reactions are off."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (let ((sid (harness-pet-test-session))
          (name (plist-get harness-pet--pet :name)))
      (harness-pet-test-counting-requests requests
        ;; Nobody watches.
        (harness-call 'session/append sid (list :kind 'user :content (format "hey %s, look" name)))
        (sleep-for 0.1)
        (should (null requests))
        ;; Muted.
        (harness-pet-test-watch)
        (harness-call 'pet/set-muted t)
        (should (eq t (plist-get (harness-call 'pet/get) :muted)))
        (harness-call 'session/append sid (list :kind 'user :content (format "hey %s, look" name)))
        (harness-call 'pet/pet)
        (sleep-for 0.1)
        (should (null requests))
        ;; Reactions off.
        (harness-call 'pet/set-muted :false)
        (let ((harness-pet-reactions nil))
          (harness-call 'session/append sid (list :kind 'user :content (format "hey %s, look" name)))
          (harness-call 'pet/pet)
          (sleep-for 0.1))
        (should (null requests))
        ;; The UI went away again.
        (harness-pet-test-watch 'off)
        (should (eq :false (plist-get (harness-call 'pet/get) :watching)))
        (harness-call 'session/append sid (list :kind 'user :content (format "hey %s, look" name)))
        (sleep-for 0.1)
        (should (null requests))))))

(ert-deftest harness-pet-answers-when-named ()
  "A message that names the pet gets an answer about it, whatever the chance."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (harness-pet-test-watch)
    (let* ((sid (harness-pet-test-session))
           (name (plist-get harness-pet--pet :name))
           (said (harness-pet-test-said))
           (harness-pet-chance 0)
           (harness-pet-cooldown 3600))
      (harness-pet-test-counting-requests requests
        (harness-call 'session/append sid (list :kind 'user :content "please fix the tokenizer"))
        (sleep-for 0.1)
        ;; By chance: never.
        (should (null requests))
        (harness-call 'session/append sid (list :kind 'user :content (format "what do you think, %s?" (downcase name))))
        (harness-test-wait (lambda () (funcall said)) 5 "the answer")
        (let* ((saying (car (funcall said)))
               (request (car requests))
               (text (harness-pet-test-request-text request)))
          (should (equal "addressed" (plist-get saying :reason)))
          (should (equal sid (plist-get saying :session)))
          (should (equal "Parser work" (plist-get saying :session-name)))
          (should (string-match-p "You called" (plist-get saying :text)))
          (should (string-prefix-p "You are a coding companion" (plist-get request :system)))
          (should (string-match-p (regexp-quote name) (plist-get request :system)))
          (should (<= (plist-get request :max-tokens) 200))
          (should-not (plist-get request :tools))
          (should (string-match-p "spoke to you by name" text))
          (should (string-match-p "Session \"Parser work\"" text))
          (should (string-match-p "user: please fix the tokenizer" text))
          (should (string-match-p (format "user: what do you think, %s\\?" (downcase name)) text)))))))

(ert-deftest harness-pet-comments-by-chance-after-the-cooldown ()
  "Unasked, the pet comments by chance, and then not again until the cooldown passed."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (harness-pet-test-watch)
    (let ((sid (harness-pet-test-session))
          (said (harness-pet-test-said))
          (harness-pet-cooldown 3600))
      (harness-pet-test-counting-requests requests
        (harness-call 'session/append sid (list :kind 'user :content "rewrite the tokenizer"))
        (harness-test-wait (lambda () (funcall said)) 5 "a comment")
        (should (equal "prompt" (plist-get (car (funcall said)) :reason)))
        (should (equal "*tilts head* Tokenizer? Bold. I like it." (plist-get (car (funcall said)) :text)))
        (should (= 1 (length requests)))
        (harness-test-wait (lambda () (eq :false (plist-get (harness-call 'pet/get) :thinking))) 5 "quiet")
        ;; Within the cooldown: nothing, however likely.
        (setq harness-pet--last-spoke 0)
        (harness-call 'session/append sid (list :kind 'user :content "and the parser"))
        (sleep-for 0.1)
        (should (= 1 (length requests)))
        ;; Its last words go with the next request, so it does not repeat itself.
        (setq harness-pet--last-unasked 0 harness-pet--last-spoke 0)
        (harness-call 'session/append sid (list :kind 'user :content "and the lexer"))
        (harness-test-wait (lambda () (= 2 (length (funcall said)))) 5 "a second comment")
        (should (string-match-p "do not repeat them:\n- \\*tilts head\\* Tokenizer"
                                (harness-pet-test-request-text (car requests))))))))

(ert-deftest harness-pet-ignores-messages-not-from-the-user ()
  "Messages of the harness or of other agents neither grow the pet nor make it speak."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (harness-pet-test-watch)
    (let ((sid (harness-pet-test-session))
          (name (plist-get harness-pet--pet :name)))
      (harness-pet-test-counting-requests requests
        (harness-call 'session/append sid (list :kind 'user :content (format "%s, do the task" name)
                                                :meta (list :from (list :kind 'system :source "tasks"))))
        (harness-call 'session/append sid (list :kind 'assistant :content (format "%s says hi" name)))
        (sleep-for 0.1)
        (should (null requests))
        (should (= 0 (plist-get (harness-call 'pet/get) :xp)))))))

(ert-deftest harness-pet-one-saying-at-a-time ()
  "While a saying is asked for, nothing else asks; a few seconds pass between two."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (harness-pet-test-watch)
    (let ((said (harness-pet-test-said)))
      (harness-pet-test-counting-requests requests
        (harness-call 'pet/pet)
        (harness-call 'pet/pet)
        (harness-test-wait (lambda () (funcall said)) 5 "a purr")
        (should (= 1 (length requests)))
        (should (equal "pet" (plist-get (car (funcall said)) :reason)))
        (should (string-match-p "you were just petted; that makes 1 pets"
                                (harness-pet-test-request-text (car requests))))
        ;; Within the gap: petting again counts, but asks nothing.
        (harness-test-wait (lambda () (eq :false (plist-get (harness-call 'pet/get) :thinking))) 5 "quiet")
        (harness-call 'pet/pet)
        (sleep-for 0.1)
        (should (= 1 (length requests)))
        (should (= 3 (plist-get (harness-call 'pet/get) :pets)))))))

;;;; Turns

(ert-deftest harness-pet-turn-reasons ()
  (require 'harness-pet)
  (let ((call (lambda (tool id &optional input) (list :kind 'tool-call :tool tool :call-id id :input input)))
        (result (lambda (id output &optional error) (list :kind 'tool-result :call-id id :output output
                                                          :is-error (if error t :false)))))
    (should (eq 'test-fail (harness-pet-turn-reason
                            (list (funcall call "bash" "1") (funcall result "1" "12 passed, 3 failed")))))
    (should (eq 'test-fail (harness-pet-turn-reason
                            (list (funcall call "mcp__harness__bash" "1")
                                  (funcall result "1" "Ran 9 tests, 8 results as expected, 1 unexpected")))))
    (should (eq 'test-fail (harness-pet-turn-reason
                            (list (funcall call "Bash" "1") (funcall result "1" "ok\nFAIL\tgithub.com/x/y\n")))))
    (should (eq 'error (harness-pet-turn-reason
                        (list (funcall call "bash" "1") (funcall result "1" "Traceback (most recent call last):")))))
    (should (eq 'error (harness-pet-turn-reason
                        (list (funcall call "read_file" "1") (funcall result "1" "No such file" t)))))
    ;; What a file or a search says is not a failure.
    (should (null (harness-pet-turn-reason
                   (list (funcall call "grep" "1") (funcall result "1" "src/a.py:3: raise Exception(\"x\")\n3 failed")))))
    (should (null (harness-pet-turn-reason
                   (list (funcall call "bash" "1") (funcall result "1" "0 failed, 12 passed")))))
    (should (eq 'large-diff (harness-pet-turn-reason
                             (list (funcall call "write_file" "1"
                                            (list :path "a.el" :content (mapconcat #'number-to-string (number-sequence 1 90) "\n")))
                                   (funcall result "1" "Wrote a.el")))))
    (should (eq 'large-diff (harness-pet-turn-reason
                             (list (funcall call "bash" "1")
                                   (funcall result "1" (concat "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n"
                                                               (mapconcat (lambda (i) (format "+line %d" i))
                                                                          (number-sequence 1 81) "\n")))))))
    (should (null (harness-pet-turn-reason
                   (list (funcall call "edit_file" "1" (list :path "a.el" :old_string "a" :new_string "b"))
                         (funcall result "1" "Edited a.el")))))))

(ert-deftest harness-pet-remarks-on-a-failed-turn ()
  "A turn of the user's whose tests failed draws a remark; a turn the harness started does not."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (harness-pet-test-watch)
    (let ((sid (harness-pet-test-session))
          (said (harness-pet-test-said))
          (harness-pet-chance 0))
      (harness-call 'session/append sid (list :kind 'user :content "run the tests"))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "c1" :title "make test"))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "c1" :output "40 passed, 2 failed"))
      (harness-call 'session/append sid (list :kind 'assistant :content "Two tests fail."))
      (harness-emit 'agent/turn-ended sid 'end-turn)
      (harness-test-wait (lambda () (funcall said)) 5 "a remark")
      (should (equal "test-fail" (plist-get (car (funcall said)) :reason)))
      (should (string-match-p "assertion has feelings" (plist-get (car (funcall said)) :text)))
      ;; 2 for the message, 1 for the turn.
      (should (= 3 (plist-get (harness-call 'pet/get) :xp))))
    (let ((sid (harness-pet-test-session)))
      (harness-pet-test-counting-requests requests
        (setq harness-pet--last-unasked 0 harness-pet--last-spoke 0)
        (harness-call 'session/append sid (list :kind 'user :content "Work on the task"
                                                :meta (list :from (list :kind 'system :source "tasks"))))
        (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "c1" :title "make test"))
        (harness-call 'session/append sid (list :kind 'tool-result :call-id "c1" :output "2 failed"))
        (harness-emit 'agent/turn-ended sid 'end-turn)
        (sleep-for 0.1)
        (should (null requests))
        (should (= 3 (plist-get (harness-call 'pet/get) :xp)))))))

;;;; Growing, renaming, letting go

(ert-deftest harness-pet-grows-a-level ()
  "Experience adds up to levels; growing one is announced, and remarked on when watched."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (let ((sid (harness-pet-test-session))
          (changes nil))
      (harness-on 'pet/changed (lambda (view) (push view changes)))
      (let ((harness-pet-chance 0))
        (dotimes (_ 4) (harness-call 'session/append sid (list :kind 'user :content "more"))))
      (should (= 8 (plist-get (harness-call 'pet/get) :xp)))
      (should (= 1 (plist-get (harness-call 'pet/get) :level)))
      (should (null changes))
      (harness-pet-test-watch)
      (let ((said (harness-pet-test-said))
            (harness-pet-chance 0))
        (harness-call 'session/append sid (list :kind 'user :content "more"))
        (should (= 2 (plist-get (car changes) :level)))
        (harness-test-wait (lambda () (funcall said)) 5 "a remark on growing")
        (should (equal "level-up" (plist-get (car (funcall said)) :reason))))
      ;; Saved soon, not at once.
      (should harness-pet--dirty)
      (harness-pet-flush)
      (should-not harness-pet--dirty)
      (should (= 10 (plist-get (harness-call 'store/load "pet.json") :xp))))))

(ert-deftest harness-pet-petting-grows-it-once-a-minute ()
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (harness-call 'pet/pet)
    (harness-call 'pet/pet)
    (let ((view (harness-call 'pet/pet)))
      (should (= 3 (plist-get view :pets)))
      (should (= 1 (plist-get view :xp))))
    (setq harness-pet--last-pet (- (float-time) 61))
    (should (= 2 (plist-get (harness-call 'pet/pet) :xp)))))

(ert-deftest harness-pet-rename-mute-release ()
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (should (equal "Sprocket" (plist-get (harness-call 'pet/rename "  Sprocket ") :name)))
    (should-error (harness-call 'pet/rename "   ") :type 'harness-error)
    (should-error (harness-call 'pet/rename "two\nlines") :type 'harness-error)
    (should-error (harness-call 'pet/rename (make-string 21 ?a)) :type 'harness-error)
    (should (equal "Sprocket" (plist-get (harness-call 'store/load "pet.json") :name)))
    (should (eq t (plist-get (harness-call 'pet/set-muted t) :muted)))
    (should (eq :false (plist-get (harness-call 'pet/set-muted :false) :muted)))
    (let ((seed (plist-get harness-pet--pet :seed)))
      (should (eq :false (plist-get (harness-call 'pet/release) :hatched)))
      (should-not (file-exists-p (expand-file-name "pet.json" harness-state-directory)))
      ;; The next egg is another pet.
      (should-not (equal seed (plist-get (harness-pet-test-hatch) :seed))))))

(ert-deftest harness-pet-model-follows-the-session ()
  "`auto' asks the provider of the session for its cheap model."
  (harness-pet-test-with
    (let ((harness-pet-model 'auto)
          (asked nil))
      (cl-letf (((symbol-function 'harness-method/provider/tier-model)
                 (lambda (model &optional tier) (push (list model tier) asked) "demo:cheap")))
        (should (equal "demo:cheap" (plist-get (harness-call 'pet/get) :model)))
        (should (equal '(("demo:scripted" cheap)) asked)))
      (cl-letf (((symbol-function 'harness-method/provider/tier-model) (lambda (&rest _) nil)))
        (should (equal "demo:scripted" (plist-get (harness-call 'pet/get) :model)))))
    (let ((harness-pet-model nil))
      (should (equal "demo:scripted" (plist-get (harness-call 'pet/get) :model))))
    (let ((harness-pet-model "other:model"))
      (should (equal "other:model" (plist-get (harness-call 'pet/get) :model))))))

(ert-deftest harness-pet-grows-with-done-tasks ()
  "Every task that gets done gives the pet experience; with no pet, nothing happens."
  (harness-pet-test-with
    (harness-emit 'task/done (list :id "t0" :session "s0") 'merged)
    (should-not harness-pet--pet)
    (harness-pet-test-hatch)
    (let ((xp (plist-get (harness-call 'pet/get) :xp)))
      (harness-emit 'task/done (list :id "t1" :session "s1") 'merged)
      (harness-emit 'task/done (list :id "t2") 'completed)
      (should (= (+ xp 6) (plist-get (harness-call 'pet/get) :xp))))))

;;;; Where it is seen

(ert-deftest harness-pet-speaks-only-where-seen ()
  "A UI showing what the pet says beside some sessions lets it speak about those only;
showing the pet itself lets it speak about anything."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (let ((s1 (harness-pet-test-session))
          (s2 (harness-pet-test-session))
          (said (harness-pet-test-said)))
      (should-error (harness-call 'pet/watch "test-ui" t "s1") :type 'harness-error)
      (should-error (harness-call 'pet/watch "test-ui" t 7) :type 'harness-error)
      (should-error (harness-call 'pet/watch "test-ui" t (list 1 2)) :type 'harness-error)
      ;; As a JSON array may come.
      (harness-call 'pet/watch "test-ui" t (vector s1))
      (should (equal (list s1) (gethash "test-ui" harness-pet--watchers)))
      (should (eq t (plist-get (harness-call 'pet/watch "test-ui" t (list s1)) :watching)))
      (harness-pet-test-counting-requests requests
        ;; Another session, whose chat is not on screen: nothing.
        (harness-call 'session/append s2 (list :kind 'user :content "rewrite the tokenizer"))
        ;; Nor petting, about no session: only the pet itself on screen hears of that.
        (harness-call 'pet/pet)
        (sleep-for 0.1)
        (should (null requests))
        ;; The session on screen: it speaks about that.
        (harness-call 'session/append s1 (list :kind 'user :content "rewrite the tokenizer"))
        (harness-test-wait (lambda () (funcall said)) 5 "a comment on the session on screen")
        (should (equal s1 (plist-get (car (funcall said)) :session)))
        (should (= 1 (length requests)))
        (harness-test-wait (lambda () (eq :false (plist-get (harness-call 'pet/get) :thinking))) 5 "quiet")
        ;; The pet itself on screen: anything.
        (harness-call 'pet/watch "test-ui" t)
        (setq harness-pet--last-unasked 0 harness-pet--last-spoke 0)
        (harness-call 'session/append s2 (list :kind 'user :content "and the parser"))
        (harness-test-wait (lambda () (= 2 (length (funcall said)))) 5 "a comment on another session")
        (should (equal s2 (plist-get (cadr (funcall said)) :session)))
        ;; Gone from the screen.
        (harness-call 'pet/watch "test-ui" :false)
        (should (eq :false (plist-get (harness-call 'pet/get) :watching)))))))

;;;; Turned off

(ert-deftest harness-pet-turned-off-does-nothing ()
  "Turned off, the pet reacts to nothing, grows no more, asks no model and
refuses all but `pet/get'; turned on again, it is as it was."
  (harness-pet-test-with
    (should (eq t (plist-get (harness-call 'pet/get) :enabled)))
    (let ((harness-pet-enabled nil))
      (should (eq :false (plist-get (harness-call 'pet/get) :enabled)))
      (should-error (harness-call 'pet/hatch) :type 'harness-error)
      (should-not harness-pet--pet))
    (harness-pet-test-hatch)
    (harness-pet-test-watch)
    (let* ((sid (harness-pet-test-session))
           (name (plist-get harness-pet--pet :name))
           (said (harness-pet-test-said))
           (before (harness-call 'pet/get)))
      (harness-pet-test-counting-requests requests
        (let ((harness-pet-enabled nil))
          (let ((view (harness-call 'pet/get)))
            (should (eq :false (plist-get view :enabled)))
            ;; Its record stays, for when it is turned on again.
            (should (equal name (plist-get view :name))))
          (dolist (call '((pet/pet) (pet/rename "Other") (pet/set-muted t) (pet/release) (pet/hatch)))
            (should-error (apply #'harness-call call) :type 'harness-error))
          (harness-call 'session/append sid (list :kind 'user :content (format "hey %s, look" name)))
          (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "c1" :title "make test"))
          (harness-call 'session/append sid (list :kind 'tool-result :call-id "c1" :output "40 passed, 2 failed"))
          (harness-emit 'agent/turn-ended sid 'end-turn)
          (harness-emit 'task/done (list :id "t1" :session sid) 'merged)
          (sleep-for 0.1))
        (should (null requests))
        (should (null (funcall said)))
        (let ((after (harness-call 'pet/get)))
          (should (eq t (plist-get after :enabled)))
          (should (equal name (plist-get after :name)))
          (should (equal (plist-get before :xp) (plist-get after :xp)))
          (should (equal (plist-get before :pets) (plist-get after :pets))))))))

(ert-deftest harness-pet-turned-off-mid-saying-drops-it ()
  "What the pet was asked to say before it was turned off is dropped when it comes."
  (harness-pet-test-with
    (harness-pet-test-hatch)
    (harness-pet-test-watch)
    (let ((said (harness-pet-test-said))
          (harness-provider-demo--delay 0.2))
      (harness-call 'pet/pet)
      (harness-test-wait (lambda () (eq t (plist-get (harness-call 'pet/get) :thinking))) 5 "the question")
      (let ((harness-pet-enabled nil))
        (harness-test-wait (lambda () (eq :false (plist-get (harness-call 'pet/get) :thinking))) 10 "the answer"))
      (should (null (funcall said)))
      (should (null (plist-get harness-pet--pet :said))))))

;;;; Over ACP

(ert-deftest harness-pet-over-acp ()
  "The UI reaches the pet as `_harness/pet/...' and hears of it as events."
  (harness-pet-test-with
    (let ((conn (harness-acp-connect nil))
          (events nil))
      (unwind-protect
          (progn
            (harness-acp-set-handler conn (lambda (method params _respond)
                                            (when (equal method "_harness/event") (push params events))))
            (let ((view (harness-test-await (harness-acp-request conn "_harness/pet/watch"
                                                                 (list :client "ui-1" :on t)))))
              (should (eq :false (plist-get view :hatched)))
              (should (eq t (plist-get view :watching))))
            (let ((view (harness-test-await (harness-acp-request conn "_harness/pet/hatch" nil))))
              (should (eq t (plist-get view :hatched)))
              (should (stringp (plist-get view :species)))
              (should (numberp (plist-get (plist-get view :stats) :debugging))))
            (harness-test-wait (lambda () (cl-some (lambda (e) (equal (plist-get e :event) "pet/said")) events))
                               5 "a pet/said event")
            (should (cl-some (lambda (e) (and (equal (plist-get e :event) "pet/changed")
                                              (eq t (plist-get (car (plist-get e :args)) :hatched))))
                             events))
            (should (equal 1 (plist-get (harness-test-await (harness-acp-request conn "_harness/pet/pet" nil)) :pets))))
        (harness-acp-close conn)))))

(provide 'harness-pet-test)
;;; harness-pet-test.el ends here
