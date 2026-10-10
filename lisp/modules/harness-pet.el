;;; harness-pet.el --- A companion pet that hatches, grows and comments  -*- lexical-binding: t; -*-

;;; Commentary:

;; A small creature that keeps the user company, in the manner of the
;; companions Claude Code hatched for April Fools' Day 2026: an egg
;; hatches into one of 18 species, of a rarity drawn by chance, with
;; five stats, a hat for the luckier ones and, once in a hundred, a
;; shiny coat.  A cheap model names it and gives it a personality, and
;; later lends it a voice: now and then it says a line about the
;; message the user just sent, about a failing test, or about being
;; petted.  The UI shows it in a buffer of its own (harness-ui-pet),
;; and, quietly, in a few places besides: its face in the header line of
;; a chat and of the task board, what it last said about a session above
;; that session's compose box.
;;
;; It can be turned off altogether: with `harness-pet-enabled' nil it
;; reacts to nothing, grows no more, asks no model anything and refuses
;; to be hatched, petted, renamed or released; `pet/get' still answers,
;; with `:enabled' false, so a UI can show it nowhere.  Its record stays,
;; and it comes back as it was when it is turned on again.
;;
;; The bones -- species, rarity, eyes, hat, shininess and stats -- are
;; rolled from a seed with Mulberry32, seeded by FNV-1a of the seed and
;; a salt, as the original rolled them from the account id.  Only the
;; seed is stored, with the soul (name, personality, the time it
;; hatched) and what it has grown since (experience, sayings, whether it
;; is muted), in pet.json under the state directory; the bones are
;; rolled again every time, so they cannot drift.  Releasing a pet
;; forgets it, and the next egg brings a new seed.
;;
;; Some of what a pet is made of may be set by hand, in
;; `harness-pet-overrides': its name, personality, species, rarity,
;; eyes, hat, shininess and stats.  They are laid over the pet each
;; time it is shown, speaks or hatches, and never stored: the record
;; keeps what it hatched with, which comes back as soon as an override
;; goes.  Set on the settings page, they show at once (`config/changed'
;; announces the pet again).
;;
;; It is cheap.  Nothing here runs unless something happens: no timer
;; but the one of a model call in flight and the one that saves the
;; record a few seconds after it grew.  It only ever speaks where what
;; it says would be seen: about a session while a UI shows it beside
;; that session, or shows the pet itself (`pet/watch'); while it is not
;; muted and while `harness-pet-reactions' is on; and then through the
;; cheapest model of the provider in use, for a line of at most a
;; couple of hundred tokens: unasked, at most once every
;; `harness-pet-cooldown' seconds and only by chance
;; (`harness-pet-chance'); asked -- named in a message, or petted --
;; every time, but never twice within a few seconds.  Every call is a
;; one-off question without extended thinking, under a session id of
;; its own, in a directory of its own (pet/ under the state directory),
;; closed when it ends; its cost goes to the usage records.
;;
;; It grows: every message the user writes, every turn of theirs that
;; ends well and every task that gets done gives it experience, and
;; petting it does too, at most once a minute.  Its level follows from
;; its experience; growing a level is something it may remark upon.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)
(defvar harness-model)

;;;; Settings

(defcustom harness-pet-enabled t
  "Whether there is a companion pet at all.
nil turns it off everywhere: no UI shows it, not its face in header
lines nor what it said above a compose box, it grows no more and asks
no model anything, and it cannot be hatched, petted, renamed or
released.  Its record stays, so turning it on again brings it back as
it was.  Its buffer (`harness-pet') says it is off and turns it on."
  :type 'boolean :group 'harness)

(defcustom harness-pet-reactions t
  "Whether the companion pet comments on what happens.
Its comments come from a cheap model (see `harness-pet-model'), only
where they would be seen -- while its buffer is on screen, or about a
session whose chat is -- and the pet is not muted, and unasked at most
once every `harness-pet-cooldown' seconds.  nil keeps it quiet: no
model is asked anything but the name and personality it hatches with."
  :type 'boolean :group 'harness)

(defcustom harness-pet-model 'auto
  "Model the companion pet speaks with, as PROVIDER:NAME, or `auto'.
`auto' (the default) asks the provider of the session the pet comments
on -- of `harness-model' when it hatches or is petted -- for its
`cheap' tier (see `harness-provider-tier-model'): the pet says one
short line, which the cheapest model does well.  nil uses that model
itself, and a PROVIDER:NAME forces one."
  :type '(choice (const :tag "The provider's cheap model" auto)
                 (const :tag "The session's model" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-pet-chance 0.3
  "Chance, from 0 to 1, that the pet comments on a message the user sends.
It comments unasked only once `harness-pet-cooldown' seconds have passed
since it last did; a message that names it always gets an answer."
  :type 'number :group 'harness)

(defcustom harness-pet-cooldown 60
  "Seconds the pet stays quiet after it said something unasked."
  :type 'number :group 'harness)

;;;; Constants

(defconst harness-pet--store "pet.json"
  "Where the pet lives, under the state directory.")

(defconst harness-pet--salt "harness-pet-2026"
  "Mixed into a pet's seed before its bones are rolled.")

(defconst harness-pet--timeout 30
  "Seconds one model call of the pet may take before it is given up.")

(defconst harness-pet--hatch-max-tokens 400
  "Output budget of the call that names a pet: a line of JSON.")

(defconst harness-pet--say-max-tokens 200
  "Output budget of the call that has the pet say something: one line.")

(defconst harness-pet--max-saying 220
  "Most characters a saying keeps.")

(defconst harness-pet--memory 5
  "Sayings a pet remembers.
The last three go with every request, so it does not repeat itself.")

(defconst harness-pet--min-gap 4
  "Seconds at least between the start of two sayings, asked or not.")

(defconst harness-pet--save-delay 5
  "Seconds after it grew that a pet's record is saved.")

(defconst harness-pet--pet-xp-gap 60
  "Seconds at least between two pettings that give experience.")

(defconst harness-pet--task-xp 3
  "Experience a task that gets done gives.")

(defconst harness-pet--max-name 20
  "Most characters a pet's name may have.")

;;;; What a pet is made of

(defconst harness-pet-rarities
  '((common :weight 60 :floor 5 :stars 1)
    (uncommon :weight 25 :floor 15 :stars 2)
    (rare :weight 10 :floor 25 :stars 3)
    (epic :weight 4 :floor 35 :stars 4)
    (legendary :weight 1 :floor 50 :stars 5))
  "Rarities, commonest first: (NAME :weight W :floor F :stars N).
A pet is of a rarity with chance W in 100; its stats start from F.")

(defconst harness-pet-species
  '(duck goose blob cat dragon octopus owl penguin turtle snail ghost axolotl
    capybara cactus robot rabbit mushroom chonk)
  "Species a pet may be, each as likely as the others.")

(defconst harness-pet-eyes '("·" "✦" "×" "◉" "@" "°")
  "Eyes a pet may have.")

(defconst harness-pet-hats '(none crown tophat propeller halo wizard beanie tinyduck)
  "Hats a pet may wear.  A common pet wears none.")

(defconst harness-pet-stats '(debugging patience chaos wisdom snark)
  "A pet's stats, in the order they are rolled and shown.")

(defconst harness-pet--words
  '("acorn" "anchor" "anvil" "apricot" "attic" "badger" "bagel" "banjo" "barnacle" "beacon"
    "bellows" "biscuit" "blizzard" "bobbin" "bramble" "brass" "bucket" "cabbage" "candle"
    "caramel" "cardigan" "cashew" "cinder" "clover" "cobble" "comet" "compass" "cork"
    "crayon" "cricket" "crumpet" "cymbal" "dandelion" "denim" "dewdrop" "doodle" "dumpling"
    "ember" "fennel" "fiddle" "flannel" "flint" "fog" "fudge" "garnet" "gherkin" "ginger"
    "glimmer" "goblet" "gravel" "griddle" "grommet" "harbor" "hazel" "hiccup" "hornet"
    "inkwell" "jasper" "jelly" "juniper" "kettle" "kiln" "lantern" "lichen" "linen"
    "locket" "maple" "marble" "meadow" "mitten" "moth" "mustard" "nectar" "nimbus" "noodle"
    "nutmeg" "oatmeal" "onyx" "orbit" "paddle" "parsnip" "pebble" "pepper" "pickle"
    "pinecone" "plum" "pocket" "pretzel" "puddle" "quartz" "quill" "radish" "raisin"
    "ripple" "rivet" "saffron" "sardine" "sequin" "shingle" "sprout" "static" "sorrel"
    "spindle" "tadpole" "teacup" "thimble" "thistle" "tinsel" "toffee" "truffle" "tumble"
    "turnip" "velvet" "walnut" "whisker" "widget" "willow" "wombat" "yarn" "zephyr" "zinc")
  "Words a pet's name may take after, four of them drawn for each pet.")

(defconst harness-pet--fallback-names
  '("Biscuit" "Noodle" "Pebble" "Mochi" "Tater" "Widget" "Crouton" "Pip")
  "Names a pet gets when no model names it.")

;;;; Overrides

;; A setting, but not with the others: its type is made of the tables
;; above, which must be there when it is defined.

(defcustom harness-pet-overrides nil
  "Attributes of the companion pet set by hand, over those it hatched with.
A plist of what to force; what it leaves out stays as the pet hatched:
rolled from its seed, or given by the model.  Keys:

  :name         its name, a string of at most 20 characters
  :personality  one short sentence
  :species      one of `harness-pet-species' (duck, cat, dragon ...)
  :rarity       common, uncommon, rare, epic or legendary
  :eye          its eyes, one character, such as \"✦\"
  :hat          one of `harness-pet-hats' (none, crown, tophat ...)
  :shiny        t or nil
  :debugging, :patience, :chaos, :wisdom, :snark   a stat, 1 to 100

A symbol may be given as a string too.  A rarity set here reshapes
what is rolled for it, unless that is set here as well: its hat (a
common pet wears none) and its stats, which start from the rarity's
floor; the rest stays as it was rolled.  Set on the settings page, the
pet changes at once, in every place it shows, and its voice follows:
the model is told what it is.  Set before the egg hatches, it shapes
the name and personality the model gives the pet too.  A value that
fits nothing (a species there is no art for, say) is ignored.  While
:name is set here, the pet cannot be renamed.  Its level and
experience are what it grew, not attributes: nothing here changes
them."
  ;; Each value type starts from something that fits (`:value'): the
  ;; settings page shows a key not set with that, greyed out.
  :type `(plist :key-type symbol :value-type sexp
                :options ((:name (string :tag "Name"))
                          (:personality (string :tag "Personality"))
                          (:species (choice :tag "Species" :value ,(car harness-pet-species)
                                            ,@(mapcar (lambda (s) (list 'const s)) harness-pet-species)))
                          (:rarity (choice :tag "Rarity" :value ,(caar harness-pet-rarities)
                                           ,@(mapcar (lambda (r) (list 'const (car r))) harness-pet-rarities)))
                          (:eye (string :tag "Eyes" :value ,(car harness-pet-eyes)))
                          (:hat (choice :tag "Hat" :value ,(car harness-pet-hats)
                                        ,@(mapcar (lambda (h) (list 'const h)) harness-pet-hats)))
                          (:shiny (boolean :tag "Shiny"))
                          ,@(mapcar (lambda (s)
                                      (list (intern (format ":%s" s))
                                            (list 'integer :tag (capitalize (symbol-name s)) :value 50)))
                                    harness-pet-stats)))
  :group 'harness)

(defconst harness-pet--override-keys
  (append '(:name :personality :species :rarity :eye :hat :shiny)
          (mapcar (lambda (s) (intern (format ":%s" s))) harness-pet-stats))
  "The keys `harness-pet-overrides' may set, in the order they are told.")

(defun harness-pet--override-symbol (value choices)
  "VALUE, one of the symbols CHOICES or its name, as that symbol; else nil."
  (when (or (stringp value) (symbolp value))
    ;; `intern-soft': a name that is no symbol yet is none of CHOICES.
    (car (memq (intern-soft (downcase (string-trim (format "%s" value)))) choices))))

(defun harness-pet--override-eye (value)
  "VALUE, a string or a character, as the eye of a pet: one character; else nil.
A string gives its first character; a blank or a control character is
no eye."
  (let ((text (cond ((stringp value) (string-trim value))
                    ((characterp value) (string value)))))
    (when (and text (string-match-p "\\`[[:graph:]]" text))
      (substring text 0 1))))

(defun harness-pet--override (key value)
  "VALUE given for KEY in `harness-pet-overrides', made to fit, as a list (FIT).
Nil when it fits nothing.  The list tells a shininess forced off, (nil),
from none."
  (pcase key
    (:name
     (when (and (stringp value) (not (harness-string-blank-p value)))
       (let ((name (harness-pet--squash value (length value))))
         (list (string-trim-right (substring name 0 (min (length name) harness-pet--max-name)))))))
    (:personality
     (when (and (stringp value) (not (harness-string-blank-p value)))
       (list (harness-pet--squash value 240))))
    (:species (when-let* ((s (harness-pet--override-symbol value harness-pet-species))) (list s)))
    (:rarity (when-let* ((r (harness-pet--override-symbol value (mapcar #'car harness-pet-rarities))))
               (list r)))
    (:hat (when-let* ((h (harness-pet--override-symbol value harness-pet-hats))) (list h)))
    (:eye (when-let* ((e (harness-pet--override-eye value))) (list e)))
    (:shiny (list (and (harness-json-true-p value) t)))
    ;; A stat.  A NaN is not even equal to itself.
    (_ (when (and (numberp value) (= value value))
         (list (round (max 1 (min 100 value))))))))

(defun harness-pet-overrides ()
  "Return the attributes `harness-pet-overrides' sets that fit, as a plist.
In the order of `harness-pet--override-keys', each made to fit: the
name squashed to one line of at most `harness-pet--max-name'
characters, the personality to one line, the species, rarity and hat
symbols of their tables, the eye a string of one character, :shiny t
or nil, a stat a whole number from 1 to 100.  What fits nothing is
left out, and so is everything when the option is no plist: nil then."
  (let ((given harness-pet-overrides))
    (when (and (proper-list-p given) (keywordp (car given)))
      (cl-loop for key in harness-pet--override-keys
               for cell = (plist-member given key)
               ;; A key at the end, with no value, sets nothing.
               for fit = (and (consp (cdr cell)) (harness-pet--override key (cadr cell)))
               when fit append (list key (car fit))))))

(defun harness-pet--overridden (overrides)
  "The keys OVERRIDES sets, as the view names them: (\"name\" \"species\" ...)."
  (cl-loop for (key _value) on overrides by #'cddr
           collect (substring (symbol-name key) 1)))

;;;; Rolling the bones

(defconst harness-pet--mask #xFFFFFFFF "The 32 bits the hash and the generator keep.")

(defun harness-pet--imul (a b)
  "Multiply A and B as 32-bit integers, keeping the low 32 bits."
  (logand (* a b) harness-pet--mask))

(defun harness-pet--hash (string)
  "Return the 32-bit FNV-1a hash of STRING, by character."
  (let ((h 2166136261))
    (dotimes (i (length string))
      (setq h (harness-pet--imul (logxor h (aref string i)) 16777619)))
    h))

(defun harness-pet--rng (seed)
  "Return a Mulberry32 generator seeded with the 32-bit integer SEED.
Each call of it returns the next number, from 0 up to, not including, 1."
  (let ((a (logand seed harness-pet--mask)))
    (lambda ()
      (setq a (logand (+ a #x6D2B79F5) harness-pet--mask))
      (let* ((x (harness-pet--imul (logxor a (ash a -15)) (logior a 1)))
             (x (logxor (logand (+ x (harness-pet--imul (logxor x (ash x -7)) (logior x 61)))
                                harness-pet--mask)
                        x)))
        (/ (float (logxor x (ash x -14))) 4294967296.0)))))

(defun harness-pet--pick (rng items)
  "Pick one of ITEMS with the generator RNG."
  (nth (floor (* (funcall rng) (length items))) items))

(defun harness-pet--roll-rarity (rng)
  "Draw a rarity with the generator RNG, by the weights of `harness-pet-rarities'."
  (let ((roll (* (funcall rng) (apply #'+ (mapcar (lambda (r) (plist-get (cdr r) :weight))
                                                  harness-pet-rarities)))))
    (or (cl-loop for (name . props) in harness-pet-rarities
                 do (setq roll (- roll (plist-get props :weight)))
                 when (< roll 0) return name)
        'common)))

(defun harness-pet--floor (rarity)
  "The lowest a stat of a RARITY pet starts from."
  (plist-get (cdr (assq rarity harness-pet-rarities)) :floor))

(defun harness-pet--roll-stats (rng rarity)
  "Roll the stats of a RARITY pet with the generator RNG.
One stat peaks, another one sags, the rest fall in between; all
start from the rarity's floor.  Return (:debugging N :patience N ...)."
  (let* ((base (harness-pet--floor rarity))
         (peak (harness-pet--pick rng harness-pet-stats))
         (dump (harness-pet--pick rng harness-pet-stats)))
    (while (eq dump peak)
      (setq dump (harness-pet--pick rng harness-pet-stats)))
    (cl-loop for name in harness-pet-stats
             append (list (intern (format ":%s" name))
                          (cond ((eq name peak) (min 100 (+ base 50 (floor (* (funcall rng) 30)))))
                                ((eq name dump) (max 1 (+ base -10 (floor (* (funcall rng) 15)))))
                                (t (+ base (floor (* (funcall rng) 40)))))))))

(defun harness-pet-roll (seed &optional rarity)
  "Return the bones of the pet SEED, a string, makes.
That is (:rarity R :species S :eye E :hat H :shiny BOOL :stats STATS
:inspiration N), R, S and H symbols of `harness-pet-rarities',
`harness-pet-species' and `harness-pet-hats', E one of
`harness-pet-eyes', STATS as `harness-pet--roll-stats' returns them and
N the number the words its name may take after are drawn from.  The
same SEED always makes the same pet: they are drawn in a fixed order
from a Mulberry32 generator seeded with the FNV-1a hash of SEED and
`harness-pet--salt'.

With RARITY, a symbol of `harness-pet-rarities', the pet is of that
rarity rather than the one drawn: its hat (a common pet wears none)
and its stats are drawn as for it.  Its rarity is drawn all the same,
and the numbers after it as for the rarity drawn, so that it keeps its
species, eyes, shininess, inspiration and the shape of its stats, which
only start from another floor."
  (let* ((rng (harness-pet--rng (harness-pet--hash (concat seed harness-pet--salt))))
         (drawn (harness-pet--roll-rarity rng))
         (rarity (if (assq rarity harness-pet-rarities) rarity drawn))
         (species (harness-pet--pick rng harness-pet-species))
         (eye (harness-pet--pick rng harness-pet-eyes))
         ;; A common pet draws no hat at all, so the draws after it shift.
         ;; One of another rarity than drawn draws as the one drawn would
         ;; (and throws a hat away), or, drawn common, draws its hat from
         ;; a generator of its own, so that the draws after it stay put.
         (hat (cond ((not (eq drawn 'common))
                     (let ((hat (harness-pet--pick rng harness-pet-hats)))
                       (if (eq rarity 'common) 'none hat)))
                    ((eq rarity 'common) 'none)
                    (t (harness-pet--pick (harness-pet--rng (harness-pet--hash (concat seed harness-pet--salt "hat")))
                                          harness-pet-hats))))
         (shiny (< (funcall rng) 0.01))
         (stats (harness-pet--roll-stats rng rarity))
         (inspiration (floor (* (funcall rng) 1e9))))
    (list :rarity rarity :species species :eye eye :hat hat :shiny shiny
          :stats stats :inspiration inspiration)))

(defun harness-pet--inspiration (seed &optional count)
  "Return COUNT (default 4) different words of `harness-pet--words'.
They are drawn from the number SEED, the same ones for the same SEED."
  (let ((s (logand seed harness-pet--mask))
        (n (length harness-pet--words))
        words)
    (while (< (length words) (min n (or count 4)))
      (setq s (logand (+ (harness-pet--imul s 1664525) 1013904223) harness-pet--mask))
      (cl-pushnew (nth (mod s n) harness-pet--words) words :test #'equal))
    (nreverse words)))

(defun harness-pet-bones (seed)
  "The bones of the pet SEED makes, with `harness-pet-overrides' applied.
See `harness-pet-roll'.  A rarity set there is rolled for; species,
eyes, hat, shininess and stats set there replace those rolled."
  (let* ((overrides (harness-pet-overrides))
         (bones (copy-sequence (harness-pet-roll seed (plist-get overrides :rarity))))
         (stats (copy-sequence (plist-get bones :stats))))
    (dolist (key '(:species :eye :hat :shiny))
      (when (plist-member overrides key)
        (setq bones (plist-put bones key (plist-get overrides key)))))
    (dolist (stat harness-pet-stats)
      (let ((key (intern (format ":%s" stat))))
        (when (plist-member overrides key)
          (setq stats (plist-put stats key (plist-get overrides key))))))
    (plist-put bones :stats stats)))

;;;; Growing

(defun harness-pet-level (xp)
  "Return the level of a pet with XP experience.
Level N takes 5 N (N - 1) experience: 10 for level 2, 30 for level 3,
60 for level 4, and so on."
  (max 1 (floor (/ (+ 1 (sqrt (+ 1 (* 0.8 (max 0 (or xp 0)))))) 2))))

(defun harness-pet-level-xp (level)
  "Return the experience LEVEL starts at."
  (* 5 level (1- level)))

;;;; The record

(defvar harness-pet--pet nil
  "The pet's record as stored, or nil when there is none (yet).
\(:seed SEED :name NAME :personality TEXT :hatched TIME :xp N :pets N
:muted BOOL :said SAYINGS), SAYINGS oldest first, each (:text TEXT :ts
TIME :reason REASON :session ID :session-name NAME).")

(defvar harness-pet--loaded nil "Non-nil once the record was read from the state directory.")
(defvar harness-pet--dirty nil "Non-nil while the record has changes not saved yet.")

(defvar harness-pet--watchers (make-hash-table :test 'equal)
  "Client id -> where that UI shows the pet now, for each UI that does.
t when it shows the pet itself, its buffer, where anything it says is
seen; else the ids of the sessions beside which it shows what the pet
says about them, their chats.")

(defvar harness-pet--hatching nil "The promise of the hatching in flight, or nil.")
(defvar harness-pet--speaking nil "Non-nil while a saying is being asked for.")
(defvar harness-pet--last-unasked 0 "When the pet last started to speak unasked.")
(defvar harness-pet--last-spoke 0 "When the pet last started to speak.")
(defvar harness-pet--last-pet 0 "When the pet was last petted for experience.")

(defun harness-pet--load ()
  "Read the pet's record, once."
  (unless harness-pet--loaded
    (setq harness-pet--loaded t
          harness-pet--pet (let ((record (ignore-errors (harness-call 'store/load harness-pet--store))))
                             (and (harness-pet--valid-p record) record)))))

(defun harness-pet--valid-p (record)
  "Non-nil when RECORD is a pet's record: it has a seed and a name."
  (and (keywordp (car-safe record))
       (stringp (plist-get record :seed)) (not (string-empty-p (plist-get record :seed)))
       (stringp (plist-get record :name)) (not (string-empty-p (plist-get record :name)))))

(defun harness-pet--save ()
  "Write the pet's record, or delete it when there is no pet."
  (setq harness-pet--dirty nil)
  (condition-case err
      (if harness-pet--pet
          (harness-call 'store/save harness-pet--store harness-pet--pet)
        (harness-call 'store/delete harness-pet--store))
    (error (harness-log 'warn "pet: saving failed: %s" (harness-error-message err)))))

(defvar harness-pet--save-timer nil "The timer that saves the record soon, or nil.")

(defun harness-pet--save-soon ()
  "Save the pet's record in a few seconds, with the changes made until then."
  (setq harness-pet--dirty t)
  (unless (timerp harness-pet--save-timer)
    (setq harness-pet--save-timer (run-at-time harness-pet--save-delay nil #'harness-pet-flush))))

(defun harness-pet-flush ()
  "Save the pet's record now if it has changes not saved yet."
  (when (timerp harness-pet--save-timer) (cancel-timer harness-pet--save-timer))
  (setq harness-pet--save-timer nil)
  (when harness-pet--dirty (harness-pet--save)))

(defun harness-pet--set (key value)
  "Set KEY of the pet's record to VALUE."
  (setq harness-pet--pet (plist-put (copy-sequence harness-pet--pet) key value)))

(defun harness-pet--watched-p ()
  "Non-nil while a UI shows the pet, anywhere."
  (> (hash-table-count harness-pet--watchers) 0))

(defun harness-pet--seen-p (&optional session-id)
  "Non-nil while what the pet says about SESSION-ID would be seen.
That is while a UI shows the pet itself, or, for a SESSION-ID, shows
what it says beside that session.  What is about no session is seen
only where the pet itself is."
  (catch 'seen
    (maphash (lambda (_client where)
               (when (or (eq where t) (and session-id (member session-id where)))
                 (throw 'seen t)))
             harness-pet--watchers)
    nil))

(defun harness-pet--enabled-p ()
  "Non-nil unless the pet is turned off (`harness-pet-enabled')."
  harness-pet-enabled)

(defun harness-pet--muted-p ()
  "Non-nil when the pet is muted."
  (harness-json-true-p (plist-get harness-pet--pet :muted)))

(defun harness-pet--bool (value)
  "VALUE as JSON: t, or false."
  (if value t :false))

(defun harness-pet--name ()
  "The pet's name: the one `harness-pet-overrides' sets, else its own."
  (or (plist-get (harness-pet-overrides) :name) (plist-get harness-pet--pet :name)))

(defun harness-pet--personality ()
  "The pet's personality: the one `harness-pet-overrides' sets, else its own."
  (or (plist-get (harness-pet-overrides) :personality) (plist-get harness-pet--pet :personality)))

(defun harness-pet-view ()
  "Return the pet as the UI shows it.
Before it hatched: (:hatched false :enabled BOOL :hatching BOOL
:reactions BOOL :watching BOOL :model MODEL :overrides KEYS), MODEL the
one it hatches and speaks with, :enabled false when it is turned off
\(`harness-pet-enabled'), KEYS the attributes `harness-pet-overrides'
sets, as names without the colon (\"name\" \"species\" ...), or nil.
After: also :seed, :name, :personality, :hatched-at, the bones
\(:rarity :species :eye :hat :shiny :stats, see `harness-pet-roll';
names as strings), :stars, :level, :xp, :level-xp (the experience its
level starts at), :next-xp (the next level's), :pets, :muted, :thinking
\(a saying is being asked for) and :said (its last sayings, oldest
first).  Name, personality and bones are those the overrides make, see
`harness-pet-bones'."
  (harness-pet--load)
  (let ((pet harness-pet--pet)
        (common (list :enabled (harness-pet--bool (harness-pet--enabled-p))
                      :hatching (harness-pet--bool harness-pet--hatching)
                      :reactions (harness-pet--bool harness-pet-reactions)
                      :watching (harness-pet--bool (harness-pet--watched-p))
                      :model (harness-pet--model)
                      :overrides (harness-pet--overridden (harness-pet-overrides)))))
    (if (not pet)
        (append (list :hatched :false) common)
      (let* ((bones (harness-pet-bones (plist-get pet :seed)))
             (rarity (plist-get bones :rarity))
             (xp (or (plist-get pet :xp) 0))
             (level (harness-pet-level xp)))
        (append (list :hatched t
                      :seed (plist-get pet :seed)
                      :name (harness-pet--name)
                      :personality (harness-pet--personality)
                      :hatched-at (plist-get pet :hatched)
                      :rarity (symbol-name rarity)
                      :stars (plist-get (cdr (assq rarity harness-pet-rarities)) :stars)
                      :species (symbol-name (plist-get bones :species))
                      :eye (plist-get bones :eye)
                      :hat (symbol-name (plist-get bones :hat))
                      :shiny (harness-pet--bool (plist-get bones :shiny))
                      :stats (plist-get bones :stats)
                      :level level :xp xp
                      :level-xp (harness-pet-level-xp level)
                      :next-xp (harness-pet-level-xp (1+ level))
                      :pets (or (plist-get pet :pets) 0)
                      :muted (harness-pet--bool (harness-pet--muted-p))
                      :thinking (harness-pet--bool harness-pet--speaking)
                      :said (plist-get pet :said))
                common)))))

(defun harness-pet--changed ()
  "Announce the pet as it is now."
  (harness-emit 'pet/changed (harness-pet-view)))

;;;; Models

(defun harness-pet--model (&optional session-id)
  "Return the model the pet speaks with about SESSION-ID, or nil.
See `harness-pet-model'."
  (let* ((session (and session-id (harness-method-exists-p 'session/get)
                       (ignore-errors (harness-call 'session/get session-id))))
         (base (or (plist-get session :model)
                   (and (boundp 'harness-model) harness-model)))
         (choice harness-pet-model))
    (cond ((or (eq choice 'auto) (equal choice "auto"))
           (or (and base (harness-method-exists-p 'provider/tier-model)
                    (ignore-errors (harness-call 'provider/tier-model base 'cheap)))
               base))
          ((and (stringp choice) (not (string-empty-p choice))) choice)
          (t base))))

(defun harness-pet--directory ()
  "The directory the pet's model calls run in: one of their own."
  (harness-ensure-directory (expand-file-name "pet/" harness-state-directory)))

(defun harness-pet--record-usage (model project event)
  "Record the usage EVENT of a call of MODEL, under PROJECT (or none)."
  (when (harness-method-exists-p 'usage/record)
    (condition-case err
        (let* ((cost (plist-get event :cost))
               (cost (if (numberp cost) cost
                       (or (and (harness-method-exists-p 'usage/price)
                                (ignore-errors (harness-call 'usage/price model event)))
                           0)))
               (list-cost (plist-get event :list-cost))
               (billing (harness-billing-of event)))
          (when (cl-some (lambda (k) (numberp (plist-get event k))) '(:input :output :cache-read :cache-write))
            (harness-call 'usage/record
                          (list :session nil :project project :model model
                                :input (plist-get event :input) :output (plist-get event :output)
                                :cache-read (plist-get event :cache-read)
                                :cache-write (plist-get event :cache-write)
                                :cost cost
                                :list-cost (cond ((numberp list-cost) list-cost)
                                                 ((eq billing 'subscription)
                                                  (or (ignore-errors (harness-call 'usage/price model event)) cost))
                                                 (t cost))
                                :billing billing))))
      (error (harness-log 'warn "pet: recording usage failed: %S" err)))))

(defun harness-pet--ask (model system text max-tokens &optional project)
  "Ask MODEL, told SYSTEM, the user message TEXT; return a promise of the reply.
The reply holds at most MAX-TOKENS tokens.  The call is a one-off
\(`:ephemeral'), without extended thinking (`:no-thinking'), under a
session id of its own that is closed when it ends; its cost is recorded
under PROJECT.  It fails after `harness-pet--timeout' seconds, and when
the provider ends it with an error."
  (if (null model)
      (harness-rejected (list 'error "No model for the pet to speak with"))
    (let* ((sid (format "pet-%s" (harness-short-id 10)))
           (promise
            (harness-with-promise (resolve reject)
              (let* ((reply "") (settled nil) (timer nil) (handle nil)
                     (finish (lambda (ok value)
                               (unless settled
                                 (setq settled t)
                                 (when timer (cancel-timer timer))
                                 (funcall (if ok resolve reject) value)))))
                (setq timer (run-at-time harness-pet--timeout nil
                                         (lambda ()
                                           (funcall finish nil (list 'error "The model took too long"))
                                           (when handle (ignore-errors (funcall (plist-get handle :cancel)))))))
                (setq handle
                      (harness-call
                       'provider/complete
                       (list :model model
                             :session (list :id sid :cwd (file-name-as-directory (harness-pet--directory)))
                             ;; A one-off question: no earlier calls, no
                             ;; project instructions or memory, a process
                             ;; of its own where the provider keeps them.
                             :ephemeral t
                             :system system
                             :messages (list (list :role 'user :content (list (list :type "text" :text text))))
                             :tools nil
                             ;; One line wants no extended thinking, which a
                             ;; cheap model would spend its time on first.
                             :no-thinking t
                             :max-tokens max-tokens
                             :on-event
                             (lambda (ev)
                               (pcase (plist-get ev :type)
                                 ('text (setq reply (concat reply (or (plist-get ev :delta) ""))))
                                 ('usage (harness-pet--record-usage model project ev))
                                 ('done
                                  (let ((reason (plist-get ev :stop-reason)))
                                    (if (memq reason '(error cancelled))
                                        (funcall finish nil (list 'error (format "The model failed: %s"
                                                                                 (or (plist-get ev :error) reason))))
                                      (funcall finish t reply))))))))))))
           (close (lambda () (ignore-errors (harness-call 'provider/close model sid)))))
      (harness-then promise
                    (lambda (reply) (funcall close) reply)
                    (lambda (err) (funcall close) (harness-rejected err))))))

(defun harness-pet--squash (text max)
  "TEXT on one line, its whitespace collapsed, at most MAX characters."
  (harness-truncate-end (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))) max))

(defun harness-pet--json (text)
  "Return the JSON object TEXT holds, as a plist, or nil."
  (when (stringp text)
    (let ((start (string-search "{" text))
          (end (cl-position ?} text :from-end t)))
      (when (and start end (< start end))
        (let ((obj (ignore-errors (harness-json-parse (substring text start (1+ end))))))
          (and (keywordp (car-safe obj)) obj))))))

;;;; Hatching

(defconst harness-pet--hatch-system
  "You name newly hatched coding companions: small creatures that live in a programmer's editor and now and then comment on their work. Given a creature's rarity, species, stats and a few inspiration words, invent
- a name: ONE word of at most 12 letters, memorable and slightly absurd. A pet's name, not a title: no \"the X\", no epithets. Lean on the inspiration words loosely: riff on one, blend two, or borrow their mood. The register: Fennel, Grommet, Tuck, Mothball, Quillon.
- a personality: ONE short sentence, at most 20 words, giving it a specific, funny quirk that shapes how it comments on code, in keeping with its stats.
The rarer the creature, the stranger and more specific; a legendary one is genuinely odd. No two companions are alike.
Answer with one line of JSON and nothing else: {\"name\":\"...\",\"personality\":\"...\"}"
  "System prompt of the call that names a pet.")

(defun harness-pet--stats-text (stats)
  "STATS as the model reads them: \"DEBUGGING 62, PATIENCE 30, ...\"."
  (mapconcat (lambda (name) (format "%s %s" (upcase (symbol-name name))
                                    (plist-get stats (intern (format ":%s" name)))))
             harness-pet-stats ", "))

(defun harness-pet--hatch-text (bones)
  "The message that asks for the name and personality of a pet with BONES."
  (concat "Hatch a companion.\n"
          (format "Rarity: %s\n" (upcase (symbol-name (plist-get bones :rarity))))
          (format "Species: %s\n" (plist-get bones :species))
          (format "Stats: %s\n" (harness-pet--stats-text (plist-get bones :stats)))
          (format "Inspiration words: %s\n"
                  (string-join (harness-pet--inspiration (plist-get bones :inspiration)) ", "))
          (if (plist-get bones :shiny) "This one is SHINY: make it extra special.\n" "")
          "Make it memorable and unlike any other."))

(defun harness-pet--a (word)
  "\"a WORD\", or \"an WORD\" before a vowel."
  (let ((word (format "%s" word)))
    (concat (if (string-match-p "\\`[aeiouAEIOU]" word) "an " "a ") word)))

(defun harness-pet--clean-name (name)
  "Return NAME as a pet's name, or nil when it holds none.
That is its first word, capitalised, of at most 14 letters."
  (when (stringp name)
    (let ((word (car (split-string (replace-regexp-in-string "[^[:alnum:]' -]" "" name) "[ -]+" t))))
      (when (and word (string-match-p "[[:alpha:]]" word))
        (let ((word (truncate-string-to-width word 14)))
          (concat (upcase (substring word 0 1)) (substring word 1)))))))

(defun harness-pet--soul (reply bones)
  "Return (NAME . PERSONALITY) from the model's REPLY, else made up from BONES."
  (let* ((answer (harness-pet--json reply))
         (name (harness-pet--clean-name (plist-get answer :name)))
         (personality (let ((p (plist-get answer :personality)))
                        (and (stringp p) (not (harness-string-blank-p p))
                             (harness-pet--squash p 240)))))
    (cons (or name (nth (mod (plist-get bones :inspiration) (length harness-pet--fallback-names))
                        harness-pet--fallback-names))
          (or personality
              (let ((a (harness-pet--a (plist-get bones :rarity))))
                (format "%s%s %s that says little and notices everything."
                        (upcase (substring a 0 1)) (substring a 1) (plist-get bones :species)))))))

(harness-defmethod pet/hatch ()
  "Hatch the pet: roll its bones from a new seed and have a cheap model name it.
Return a promise of the pet (`pet/get'), resolved once it has hatched;
when one has hatched already, that one.  A hatching in flight is shared.
When no model answers, the pet still hatches, with a name and a
personality of its own.  Events `pet/changed' as it starts and as it
ends.  Signals when the pet is turned off (`harness-pet-enabled')."
  (harness-pet--require-enabled)
  (harness-pet--load)
  (cond
   (harness-pet--pet (harness-resolved (harness-pet-view)))
   (harness-pet--hatching harness-pet--hatching)
   (t
    (let* ((seed (harness-uuid))
           ;; As it will show: the model names the pet the overrides make.
           (bones (harness-pet-bones seed))
           (model (harness-pet--model))
           (start (float-time))
           (hatch (lambda (reply)
                    (let ((soul (harness-pet--soul reply bones)))
                      ;; Its own name and personality, under any the
                      ;; overrides set: they come back when those go.
                      (setq harness-pet--pet (list :seed seed :name (car soul) :personality (cdr soul)
                                                   :hatched (float-time) :xp 0 :pets 0 :muted :false
                                                   :said nil)
                            harness-pet--hatching nil)
                      (harness-pet--save)
                      (harness-log 'info "pet: %s hatched, %s %s (%s, %.1fs)" (harness-pet--name)
                                   (harness-pet--a (plist-get bones :rarity)) (plist-get bones :species) model
                                   (- (float-time) start))
                      (harness-pet--changed)
                      ;; Its first words.
                      (harness-pet--maybe-speak 'hatch nil t)
                      (harness-pet-view)))))
      (setq harness-pet--hatching
            (harness-then
             (condition-case err
                 (harness-pet--ask model harness-pet--hatch-system (harness-pet--hatch-text bones)
                                   harness-pet--hatch-max-tokens)
               (error (harness-rejected err)))
             hatch
             (lambda (err)
               (harness-log 'warn "pet: no model named it (%s); it hatches all the same"
                            (harness-error-message err))
               (funcall hatch nil))))
      (harness-pet--changed)
      harness-pet--hatching))))

;;;; Speaking

(defconst harness-pet--say-system
  "You are a coding companion: %s, a tiny %s %s that lives in a programmer's editor and watches them work with an AI coding agent. %s
Your stats, out of 100, colour your voice: %s.
Now and then you say one short line about what is happening: in character, playful, about what you actually see, at most 140 characters. You may start with a brief action between asterisks, like *tilts head*. Plain text only: no markdown, no emoji, no quotation marks, no advice longer than a line, never the agent's words. When the user speaks to you by name, answer them directly. When nothing is worth saying, answer just: ..."
  "System prompt of the call that has the pet say something.
Filled with its name, rarity, species, personality and stats.")

(defconst harness-pet--reasons
  '((prompt . "The user just sent their agent a message.")
    (addressed . "The user just spoke to you by name.")
    (error . "Something the agent ran just failed.")
    (test-fail . "Tests just failed.")
    (large-diff . "The agent just made a big change.")
    (pet . "The user just petted you.")
    (hatch . "You just hatched: these are the first words you ever say.")
    (level-up . "You just grew a level."))
  "What happened, for each reason the pet may speak for.")

(defun harness-pet--say-system ()
  "The system prompt that gives the pet its voice."
  (let ((bones (harness-pet-bones (plist-get harness-pet--pet :seed))))
    (format harness-pet--say-system
            (harness-pet--name)
            (plist-get bones :rarity) (plist-get bones :species)
            (let ((p (harness-pet--personality)))
              (if (harness-string-blank-p p) "" (concat "Your personality: " p)))
            (harness-pet--stats-text (plist-get bones :stats)))))

(defun harness-pet--say-text (reason context)
  "The message that asks the pet for a line about CONTEXT, for REASON."
  (let ((recent (last (plist-get harness-pet--pet :said) 3)))
    (concat (or (cdr (assq reason harness-pet--reasons)) "Something happened.")
            (if (harness-string-blank-p context) "" (concat "\n\n" context))
            (if recent
                (concat "\n\nYour last words, do not repeat them:\n"
                        (mapconcat (lambda (s) (concat "- " (harness-pet--squash (plist-get s :text) 200)))
                                   recent "\n"))
              "")
            "\n\nSay your line now.")))

(defun harness-pet-sanitise (text &optional name)
  "Turn the model's TEXT into a saying of the pet NAME, or nil for silence.
The first two lines are kept, on one line, without a leading \"NAME:\"
or quotation marks around them; three dots, or nothing, are silence."
  (let* ((lines (split-string (or text "") "\n" t "[ \t\r]+"))
         (line (string-join (seq-take lines 2) " ")))
    (when (and name (not (string-empty-p name)))
      (let ((case-fold-search t))
        (when (string-match (concat "\\`\\*?\\*?" (regexp-quote name) "\\*?\\*?[ \t]*:[ \t]*") line)
          (setq line (substring line (match-end 0))))))
    (setq line (string-trim line "[\"“”‘ \t]+" "[\"“”’ \t]+"))
    (setq line (replace-regexp-in-string "[ \t]+" " " line))
    (unless (or (string-empty-p line) (string-match-p "\\`[.…]+\\'" line))
      (harness-truncate-end line harness-pet--max-saying))))

(defun harness-pet--may-speak-p (&optional session-id)
  "Non-nil when the pet may speak now, about SESSION-ID if given.
It is turned on and has hatched, is not muted, reactions are on, what
it would say would be seen (`harness-pet--seen-p'), and it is not in
the middle of saying something."
  (and (harness-pet--enabled-p)
       harness-pet--pet
       harness-pet-reactions
       (not (harness-pet--muted-p))
       (harness-pet--seen-p session-id)
       (not harness-pet--speaking)))

(defun harness-pet--maybe-speak (reason context asked &optional session-id)
  "Have the pet say something about CONTEXT, for REASON, when it may.
ASKED non-nil means the user asked for it (named it, petted it): then
no cooldown applies, only `harness-pet--min-gap'.  SESSION-ID is the
session it is about, if any.  Return non-nil when it started."
  (let ((now (float-time)))
    (when (and (harness-pet--may-speak-p session-id)
               (>= (- now harness-pet--last-spoke) harness-pet--min-gap)
               (or asked (>= (- now harness-pet--last-unasked) (or harness-pet-cooldown 0))))
      (unless asked (setq harness-pet--last-unasked now))
      (setq harness-pet--last-spoke now)
      (harness-pet--speak reason context session-id)
      t)))

(defun harness-pet--session-facts (session-id)
  "Return (NAME PROJECT-NAME PROJECT-ROOT) of SESSION-ID; nils when unknown."
  (let* ((session (and session-id (harness-method-exists-p 'session/get)
                       (ignore-errors (harness-call 'session/get session-id))))
         (root (or (plist-get session :project) (plist-get session :cwd)))
         (project (and root (if (harness-method-exists-p 'project/name)
                                (ignore-errors (harness-call 'project/name root))
                              (file-name-nondirectory (directory-file-name root))))))
    (list (plist-get session :name) project root)))

(defun harness-pet--speak (reason context &optional session-id)
  "Ask the model for the pet's line about CONTEXT, for REASON; say it.
The saying is remembered and announced with `pet/said', then
`pet/changed'.  SESSION-ID is the session it is about, if any."
  (pcase-let* ((`(,session-name ,_project ,root) (harness-pet--session-facts session-id))
               (model (harness-pet--model session-id)))
    (setq harness-pet--speaking t)
    (harness-pet--changed)
    (harness-then
     (condition-case err
         (harness-pet--ask model (harness-pet--say-system) (harness-pet--say-text reason context)
                           harness-pet--say-max-tokens root)
       (error (harness-rejected err)))
     (lambda (reply)
       (setq harness-pet--speaking nil)
       ;; Released, or turned off, while it thought: it says nothing.
       (let ((text (and harness-pet--pet (harness-pet--enabled-p)
                        (harness-pet-sanitise reply (harness-pet--name)))))
         (when text
           (let ((saying (list :text text :ts (float-time) :reason (symbol-name reason)
                               :session session-id :session-name session-name)))
             (harness-pet--set :said (last (append (plist-get harness-pet--pet :said) (list saying))
                                           harness-pet--memory))
             (harness-pet--save-soon)
             (harness-emit 'pet/said saying))))
       (harness-pet--changed))
     (lambda (err)
       (setq harness-pet--speaking nil)
       (harness-log 'warn "pet: it could not speak: %s" (harness-error-message err))
       (harness-pet--changed)))))

;;;; What it reacts to

(defun harness-pet--str (value)
  "VALUE as a string: symbols and strings alike, nil as nil."
  (and value (format "%s" value)))

(defun harness-pet--own-message-p (node)
  "Non-nil when NODE is a message the user wrote."
  (and (equal (harness-pet--str (plist-get node :kind)) "user")
       (not (harness-node-sender node))))

(defun harness-pet--addressed-p (text)
  "Non-nil when TEXT names the pet, by the name it goes by now."
  (let ((name (harness-pet--name)))
    (and (stringp text) (stringp name) (not (string-empty-p name))
         (let ((case-fold-search t))
           (string-match-p (concat "\\b" (regexp-quote name) "\\b") text)))))

(defun harness-pet--chance-p ()
  "Non-nil with the chance `harness-pet-chance'."
  (< (/ (random 1000000) 1000000.0) (or harness-pet-chance 0)))

(defun harness-pet--node-line (node &optional outputs)
  "NODE as a line of the transcript the pet reads, or nil.
With OUTPUTS, the tail of a tool result's output too."
  (pcase (harness-pet--str (plist-get node :kind))
    ("user" (unless (harness-node-sender node)
              (concat "user: " (harness-pet--squash (plist-get node :content) 300))))
    ("assistant" (let ((text (plist-get node :content)))
                   (unless (harness-string-blank-p text)
                     (concat "agent: " (harness-pet--squash text 300)))))
    ("tool-call" (format "[the agent ran %s]"
                         (harness-pet--squash (or (plist-get node :title) (plist-get node :tool) "a tool") 120)))
    ("tool-result" (when (and outputs (not (harness-string-blank-p (plist-get node :output))))
                     (let ((out (string-trim (plist-get node :output))))
                       (format "[%s]\n%s" (if (harness-json-true-p (plist-get node :is-error)) "it failed" "output")
                               (if (> (length out) 600) (concat "…" (substring out -600)) out)))))))

(defun harness-pet--context (session-id nodes &optional outputs)
  "The transcript the pet reads: SESSION-ID's name and project, then NODES.
With OUTPUTS, tool results show the tail of their output.  At most about
3000 characters, the end kept."
  (pcase-let* ((`(,name ,project ,_root) (harness-pet--session-facts session-id))
               (lines (delq nil (mapcar (lambda (n) (harness-pet--node-line n outputs)) nodes)))
               (text (string-join lines "\n")))
    (concat (cond ((and name project) (format "Session \"%s\", in project %s.\n" name project))
                  (project (format "A session in project %s.\n" project))
                  (name (format "Session \"%s\".\n" name))
                  (t ""))
            (if (> (length text) 3000) (concat "…" (substring text -3000)) text))))

(defun harness-pet--recent (session-id &optional limit)
  "The last LIMIT (default 12) nodes of SESSION-ID's transcript."
  (and (harness-method-exists-p 'session/nodes)
       (ignore-errors (harness-call 'session/nodes session-id (list :limit (or limit 12))))))

(defun harness-pet--speak-about-message (session-id node-id addressed)
  "Have the pet speak about the message NODE-ID the user just sent SESSION-ID.
ADDRESSED non-nil means the message names it."
  (when harness-pet--pet
    (let* ((nodes (harness-pet--recent session-id 12))
           ;; Up to the message, which other nodes may follow by now.
           (upto (let ((pos (cl-position node-id nodes :key (lambda (n) (plist-get n :id)) :test #'equal)))
                   (if pos (seq-take nodes (1+ pos)) nodes))))
      (harness-pet--maybe-speak (if addressed 'addressed 'prompt)
                                (harness-pet--context session-id upto)
                                addressed session-id))))

(defun harness-pet--on-node-added (session-id node)
  "Grow when NODE, added to SESSION-ID, is a message the user wrote.
The pet may say something about it too.  Turned off, it does nothing."
  (when (and (harness-pet--enabled-p) (harness-pet--own-message-p node))
    (harness-pet--load)
    (when harness-pet--pet
      (harness-pet--gain 2 session-id)
      (let ((text (plist-get node :content)))
        (when (and (not (harness-string-blank-p text)) (harness-pet--may-speak-p session-id))
          (let ((addressed (harness-pet--addressed-p text)))
            (when (or addressed
                      (and (>= (- (float-time) harness-pet--last-unasked) (or harness-pet-cooldown 0))
                           (harness-pet--chance-p)))
              ;; Out of the append that announced the message.
              (harness-run-soon #'harness-pet--speak-about-message session-id (plist-get node :id)
                                addressed))))))))

(defconst harness-pet--test-fail-regexp
  "\\b[1-9][0-9]* \\(?:failed\\|failing\\|unexpected\\)\\b\\|\\b[Tt]ests? failed\\b\\|^\\(?:--- \\)?FAIL\\(?:ED\\)?\\b\\| ✗ \\| ✘ "
  "Output of a command saying tests failed; case matters.")

(defconst harness-pet--error-regexp
  "\\berror:\\|\\bexception\\b\\|\\btraceback\\b\\|\\bpanicked at\\b\\|\\bfatal:\\|exit \\(?:code\\|status\\) [1-9]"
  "Output of a command saying something went wrong; case does not matter.")

(defconst harness-pet--command-tool-regexp
  "\\(?:\\`\\|_\\)\\(?:bash\\|shell\\|sh\\|command\\|exec\\|run\\|terminal\\)\\'"
  "Names of the tools that run commands, whose output the pet reads for failures.
Other tools' output, a file read or a search say, may well mention
errors without anything having failed.")

(defconst harness-pet--write-tool-regexp
  "\\(?:\\`\\|__\\)\\(?:write_file\\|edit_file\\|Write\\|Edit\\|MultiEdit\\)\\'"
  "Names of the tools that write files, whose input the pet counts lines of.")

(defconst harness-pet--large-diff 80
  "Changed lines that make a change large.")

(defun harness-pet--tool-name (node)
  "The name of tool call NODE's tool, as a string, or \"\"."
  (or (harness-pet--str (plist-get node :tool)) ""))

(defun harness-pet--changed-lines (node)
  "The lines tool NODE changed: diff lines of a result, or lines written by a call."
  (pcase (harness-pet--str (plist-get node :kind))
    ("tool-result"
     (let ((out (plist-get node :output)) (n 0))
       (when (and (stringp out) (string-match-p "^\\(?:@@ \\|diff \\)" out))
         (dolist (line (split-string out "\n"))
           (when (and (string-match-p "\\`[-+]" line)
                      (not (string-match-p "\\`\\(?:\\+\\+\\+\\|---\\)" line)))
             (cl-incf n))))
       n))
    ("tool-call"
     (let ((input (plist-get node :input)))
       (if (and (keywordp (car-safe input))
                (let ((case-fold-search nil))
                  (string-match-p harness-pet--write-tool-regexp (harness-pet--tool-name node))))
           (cl-loop for key in '(:content :new_string :new-string)
                    for text = (plist-get input key)
                    when (stringp text) sum (1+ (cl-count ?\n text)))
         0)))
    (_ 0)))

(defun harness-pet--command-outputs (nodes)
  "The outputs of the results among NODES of tools that run commands."
  (let ((commands (make-hash-table :test 'equal)))
    (dolist (n nodes)
      (when (and (equal (harness-pet--str (plist-get n :kind)) "tool-call")
                 (let ((case-fold-search t))
                   (string-match-p harness-pet--command-tool-regexp (harness-pet--tool-name n))))
        (puthash (plist-get n :call-id) t commands)))
    (delq nil (mapcar (lambda (n)
                        (and (equal (harness-pet--str (plist-get n :kind)) "tool-result")
                             (gethash (plist-get n :call-id) commands)
                             (stringp (plist-get n :output))
                             (plist-get n :output)))
                      nodes))))

(defun harness-pet-turn-reason (nodes)
  "Return why the turn of NODES is worth a remark, or nil.
`test-fail' when a command's output says tests failed, `error' when a
tool failed or a command's output says something went wrong,
`large-diff' when the turn changed more than `harness-pet--large-diff'
lines."
  (let ((outputs (harness-pet--command-outputs nodes)))
    (cond
     ((cl-some (lambda (out) (let ((case-fold-search nil)) (string-match-p harness-pet--test-fail-regexp out)))
               outputs)
      'test-fail)
     ((or (cl-some (lambda (n) (and (equal (harness-pet--str (plist-get n :kind)) "tool-result")
                                    (harness-json-true-p (plist-get n :is-error))))
                   nodes)
          (cl-some (lambda (out) (let ((case-fold-search t)) (string-match-p harness-pet--error-regexp out)))
                   outputs))
      'error)
     ((> (apply #'+ 0 (mapcar #'harness-pet--changed-lines nodes)) harness-pet--large-diff)
      'large-diff))))

(defun harness-pet--turn-nodes (session-id)
  "The nodes of SESSION-ID's last turn: from the last message to the end.
Nil unless the user wrote that message: turns the harness or another
agent started are not the user's."
  (let* ((nodes (harness-pet--recent session-id 60))
         (pos (cl-position-if (lambda (n) (equal (harness-pet--str (plist-get n :kind)) "user"))
                              nodes :from-end t)))
    (when (and pos (harness-pet--own-message-p (nth pos nodes)))
      (nthcdr pos nodes))))

(defun harness-pet--on-turn-ended (session-id reason)
  "Grow when the user's turn in SESSION-ID ended well, REASON `end-turn'.
The pet may remark on a turn that went badly.  Turned off, it does
nothing."
  (when (harness-pet--enabled-p)
    (harness-pet--load)
    (when harness-pet--pet
      (when-let* ((nodes (harness-pet--turn-nodes session-id)))
        (when (eq reason 'end-turn)
          (harness-pet--gain 1 session-id))
        (when (and (harness-pet--may-speak-p session-id)
                   (>= (- (float-time) harness-pet--last-unasked) (or harness-pet-cooldown 0)))
          (when-let* ((why (harness-pet-turn-reason nodes)))
            (harness-run-soon #'harness-pet--maybe-speak why
                              (harness-pet--context session-id (last nodes 12) t)
                              nil session-id)))))))

(defun harness-pet--on-task-done (task _how)
  "Grow when TASK got done, however it did: the board feeds the pet too.
Turned off, it does nothing."
  (when (harness-pet--enabled-p)
    (harness-pet--load)
    (when harness-pet--pet
      (harness-pet--gain harness-pet--task-xp (plist-get task :session)))))

(defun harness-pet--gain (xp &optional session-id)
  "Give the pet XP experience; it may remark on growing a level.
SESSION-ID is the session it grew by, which a remark is about."
  (let* ((before (or (plist-get harness-pet--pet :xp) 0))
         (after (+ before xp)))
    (harness-pet--set :xp after)
    (harness-pet--save-soon)
    (if (> (harness-pet-level after) (harness-pet-level before))
        (progn
          (harness-pet--changed)
          (harness-run-soon #'harness-pet--maybe-speak 'level-up
                            (format "You are level %d now." (harness-pet-level after)) t session-id))
      (when (harness-pet--watched-p)
        (harness-pet--changed)))))

;;;; Methods

(harness-defmethod pet/get ()
  "Return the companion pet as the UI shows it; see `harness-pet-view'."
  (harness-pet-view))

(defun harness-pet--require-enabled ()
  "Signal when the pet is turned off."
  (unless (harness-pet--enabled-p)
    (signal 'harness-error (list "The companion pet is turned off (harness-pet-enabled)"))))

(defun harness-pet--require ()
  "Signal unless there is a pet, turned on."
  (harness-pet--require-enabled)
  (harness-pet--load)
  (unless harness-pet--pet
    (signal 'harness-error (list "There is no pet yet: hatch one first"))))

(harness-defmethod pet/pet ()
  "Pet the companion.  Return the pet (`pet/get').
It counts the petting, grows a little (once a minute at most) and,
when it may speak, says something about it.  Event `pet/changed'."
  (harness-pet--require)
  (let ((now (float-time)))
    (harness-pet--set :pets (1+ (or (plist-get harness-pet--pet :pets) 0)))
    (if (>= (- now harness-pet--last-pet) harness-pet--pet-xp-gap)
        (progn (setq harness-pet--last-pet now)
               (harness-pet--gain 1))
      (harness-pet--save-soon)
      (harness-pet--changed))
    (harness-pet--maybe-speak 'pet
                              (format "(you were just petted; that makes %d pets so far, and it is %s)"
                                      (plist-get harness-pet--pet :pets)
                                      (format-time-string "%A %H:%M"))
                              t)
    (harness-pet-view)))

(harness-defmethod pet/rename (name)
  "Rename the companion NAME.  Return the pet (`pet/get').
NAME is trimmed; it must not be empty, span lines, or have more than
`harness-pet--max-name' characters.  Signals while `harness-pet-overrides'
sets the name: it would not show.  Event `pet/changed'."
  (harness-pet--require)
  (when (plist-get (harness-pet-overrides) :name)
    (signal 'harness-error (list "Its name is set by hand in harness-pet-overrides: change it there")))
  (let ((name (string-trim (or name ""))))
    (cond ((string-empty-p name) (signal 'harness-error (list "A pet needs a name")))
          ((string-match-p "\n" name) (signal 'harness-error (list "A name fits on one line")))
          ((> (length name) harness-pet--max-name)
           (signal 'harness-error (list (format "A name has at most %d characters" harness-pet--max-name)))))
    (harness-pet--set :name name)
    (harness-pet--save)
    (harness-pet--changed)
    (harness-pet-view)))

(harness-defmethod pet/set-muted (muted)
  "Mute the companion when MUTED is true, else let it speak again.
A muted pet never asks a model anything.  Return the pet (`pet/get').
Event `pet/changed'."
  (harness-pet--require)
  (harness-pet--set :muted (harness-pet--bool (harness-json-true-p muted)))
  (harness-pet--save)
  (harness-pet--changed)
  (harness-pet-view))

(harness-defmethod pet/release ()
  "Let the companion go: forget it for good.  Return the pet: an egg.
The next one hatches from a new seed.  Event `pet/changed'.  Signals
when the pet is turned off: turning it off keeps it, for later."
  (harness-pet--require-enabled)
  (harness-pet--load)
  (setq harness-pet--pet nil harness-pet--speaking nil)
  (harness-pet--save)
  (harness-pet--changed)
  (harness-pet-view))

(harness-defmethod pet/watch (client on &optional sessions)
  "Say whether the UI CLIENT shows the pet now: ON true or false.
CLIENT is an id the UI makes up for itself.  With SESSIONS, a list of
session ids, it shows the pet only beside those sessions -- what it
says about them above their chats, say -- and not the pet itself.  The
pet only speaks where it would be seen: about anything while some UI
shows the pet itself, about a session while some UI shows it beside
that session.  Return the pet (`pet/get')."
  (unless (and (stringp client) (not (string-empty-p client)))
    (signal 'harness-error (list "pet/watch needs a client id")))
  (let ((sessions (if (vectorp sessions) (append sessions nil) sessions)))
    (unless (and (proper-list-p sessions) (cl-every #'stringp sessions))
      (signal 'harness-error (list "pet/watch takes a list of session ids")))
    (setq sessions (copy-sequence sessions))
    (if (harness-json-true-p on)
        (puthash client (or sessions t) harness-pet--watchers)
      (remhash client harness-pet--watchers)))
  (harness-pet-view))

;;;; Module

(defun harness-pet--on-config-changed (key &rest _)
  "Announce the pet again when KEY, the option that changed, overrides it.
That is `harness-pet-overrides': every place it shows, shows it anew."
  (when (equal (format "%s" key) "harness-pet-overrides")
    (harness-pet--changed)))

(defun harness-pet--init ()
  "Read the pet and listen for what it reacts to."
  (harness-pet--load)
  (harness-on 'session/node-added #'harness-pet--on-node-added 70)
  (harness-on 'agent/turn-ended #'harness-pet--on-turn-ended 70)
  (harness-on 'task/done #'harness-pet--on-task-done 70)
  (harness-on 'config/changed #'harness-pet--on-config-changed 70)
  (add-hook 'kill-emacs-hook #'harness-pet-flush))

(defun harness-pet--shutdown ()
  "Save what the pet gained, and stop listening."
  (harness-pet-flush)
  (remove-hook 'kill-emacs-hook #'harness-pet-flush)
  (harness-off (cons 'session/node-added #'harness-pet--on-node-added))
  (harness-off (cons 'agent/turn-ended #'harness-pet--on-turn-ended))
  (harness-off (cons 'task/done #'harness-pet--on-task-done))
  (harness-off (cons 'config/changed #'harness-pet--on-config-changed)))

(harness-declare-event 'pet/changed "(PET) after the companion pet changed; PET as `pet/get' returns it.")
(harness-declare-event 'pet/said "(SAYING) after the companion pet said something: (:text :ts :reason :session :session-name).")

(harness-define-module 'pet
  :doc "A companion pet: hatched with random bones, named and voiced by a cheap model, growing with use."
  :requires '(store provider)
  :init #'harness-pet--init
  :shutdown #'harness-pet--shutdown)

(provide 'harness-pet)
;;; harness-pet.el ends here
