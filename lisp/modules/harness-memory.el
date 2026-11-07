;;; harness-memory.el --- Lasting preferences, conventions and facts  -*- lexical-binding: t; -*-

;;; Commentary:

;; A memory is a lasting thing an agent should know in a later session:
;; how the user wants work done ("Don't import inside function bodies"),
;; a convention of this codebase, a durable fact about the project, or
;; where something lives.  It is not a notebook of task state, and it is
;; not a transcript search: what the user or the agent decided once, and
;; would otherwise have to say again, is what belongs here.  The model
;; is Claude Code's (CLAUDE.md and auto memory): four kinds of note, a
;; user scope that holds for every project and a project scope shared by
;; every worktree of a checkout, loaded into every session, and edited by
;; people as well as by the agent.
;;
;; The memories are the data, and `memory.db', in the state directory,
;; is where they live: a row each in the `memories' table, a plist in
;;
;;   (:id "m-1a2b3c4d" :scope "user"|"project" :project DIR
;;    :kind "preference"|"convention"|"fact"|"reference"
;;    :text "..." :created FLOAT :updated FLOAT :source SESSION-ID)
;;
;; once read out of it.  The database is the only copy of them: a change
;; is one SQLite transaction over the row, its full-text entry and its
;; vectors, so a crash cannot leave two stores disagreeing and nothing
;; has to be rebuilt to learn what the memories are.  A preference is how
;; the user wants their work done and is theirs across projects; a
;; convention is a rule of this codebase; a fact is durable project
;; knowledge; a reference says where to find something.  user scope
;; holds for every project, project scope for the project it was saved
;; in, resolved to the checkout a worktree was made from (`project/root'
;; and `harness-project-main'), so a task's worktree shares the memory of
;; its main checkout.
;;
;; What reaches the prompt.  A filter on `agent/system-prompt' adds a
;; `## Memory' section, built from the memories alone:
;;
;; - project instructions, then user instructions (preferences and
;;   conventions), in full: they are the point, and they are short;
;; - project notes, then user notes (facts and references), in full while
;;   `harness-memory-prompt-budget' allows, and otherwise as a compact
;;   index of id and first line that `memory_get' reads.
;;
;; Its text is stable between steps and between turns until a memory
;; changes.  That is deliberate: the system prompt is the start of the
;; provider's prompt cache, and a section rebuilt from the latest
;; request would make every turn a cache miss.  A memory that is saved
;; changes it once, which is the moment the conversation learns
;; something new.
;;
;; The agent reaches memory with `memory_save', `memory_search',
;; `memory_get', `memory_forget' and `memory_consolidate'.  `memory_save'
;; takes `replaces', a list of ids the new memory absorbs, which is how
;; the agent folds two notes into one; saving the same text again edits
;; the memory that holds it instead of making a second.  Consolidation
;; with a cheap model is `memory/consolidate': it asks the simple tier of
;; the session's model to merge and drop notes of one scope, and applies
;; the answer only when every id it names exists and every kind it gives
;; is one of the four -- a bad answer changes nothing.
;;
;; Searching is the same shape as the session search (harness-session-search.el),
;; on a much smaller corpus: the memories table is the truth, and an FTS5
;; external-content table over its text is kept in step by triggers, so
;; a search reads what is there and nothing can go stale.  Optional int8
;; vectors in the same file rank by meaning.  Without FTS5, the memories
;; are filtered in Elisp; without SQLite there is no memory to keep, and
;; a write says so.  With `harness-memory-embedding-model' set, `mode
;; semantic' embeds the memories that have no current vector, in the
;; background of the one request, and ranks them by meaning; the model's
;; provider is the same one the session search uses (`provider/embed').
;;
;; Secrets.  A memory is text, and text can hold a secret.  A redaction
;; (`secrets/redact', harness-redact.el) reaches memory too:
;; `memory/redact' replaces the secret's value in every memory it covers,
;; rebuilds the full-text index from the changed rows, then VACUUMs the
;; database and empties its log, so the old text is not left in its pages.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'harness-core)
(require 'harness-util)
(require 'harness-project)
(require 'harness-tools)
(require 'harness-prompts)
(require 'harness-redaction)

(defvar harness-state-directory)

(declare-function harness-project-main "harness-project" (root &optional seen))
(declare-function harness-judge-ask "harness-judge" (&rest args))
(declare-function harness-judge-model "harness-judge" (session &optional model))

;;;; Customisation

(defcustom harness-memory-prompt-budget 6000
  "Most characters the Memory section of a system prompt may take.
Instructions (preferences and conventions) come first and are never
cut while they fit; notes (facts and references) fill the rest, and the
ones that do not fit are listed by id for `memory_get'.  A memory the
model needs that is not in the section is found with `memory_search'."
  :type 'integer
  :group 'harness)

(defcustom harness-memory-in-prompt t
  "Non-nil adds the lasting memories to the system prompt of a session.
Nil keeps them out of the prompt; the tools and the memory page still
see them."
  :type 'boolean
  :group 'harness)

(defcustom harness-memory-max-chars 2000
  "Most characters one memory may hold.
A memory is a concise statement, not a document: put the detail in a
skill or a file and let the memory say where it is."
  :type 'integer
  :group 'harness)

(defcustom harness-memory-embedding-model nil
  "Model that embeds memories for `semantic' search, or nil for none.
A model of a provider that embeds (`provider/embed'): an
OpenAI-compatible endpoint (OpenAI, OpenRouter, or a local Ollama,
LM Studio, llama.cpp or vLLM server), for example
\"openai:text-embedding-3-small\".  With it set, a semantic search
embeds the memories that have no current vector, in batches, the first
time it needs them.  The text goes to the model's provider, which is
why it is the user's choice; `harness-allowed-models' holds for it, and
in corporate mode only a server on this machine embeds."
  :type '(choice (const :tag "Off: full-text search only" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-memory-embedding-dimensions nil
  "Length of the vectors to ask the embedding model for, or nil for its own.
Models that can shorten their vectors (OpenAI's text-embedding-3) take
it; shorter vectors take less space and compare faster."
  :type '(choice (const :tag "The model's own" nil) integer)
  :group 'harness)

(defconst harness-memory-kinds '(preference convention fact reference)
  "The kinds of memory, in the order the page lists them.
A preference is how the user wants their work done; a convention is a
rule of one codebase; a fact is durable knowledge of a project; a
reference says where to find something.")

(defconst harness-memory-kind-labels
  '((preference . "Preference") (convention . "Convention")
    (fact . "Fact") (reference . "Reference"))
  "How each kind of memory reads among people, in the page and its menus.")

(defconst harness-memory-scopes '(project user)
  "The scopes of memory, the narrower first.
Project memories hold for the project they were saved in and every
worktree of its checkout; user memories hold in every project.")

(defconst harness-memory-scope-labels
  '((project . "Project") (user . "User"))
  "How each scope of memory reads among people.")

(defconst harness-memory--db-name "memory"
  "Name of the database in the state directory, without .db.")

(defconst harness-memory--embed-batch 32
  "Most memories one embedding request carries.")

(defconst harness-memory--query-cache-limit 32
  "Most query embeddings kept for the next search.")

(defconst harness-memory--prompt-index-chars 160
  "Most characters of a memory quoted in the prompt's index line.")

(defvar harness-memory--entries nil
  "The memories as last read from the database, newest first.
Each is a plist (see the Commentary).  It is a cache for reading; every
change is written to the database first, and this is read back from it.")

(defvar harness-memory--loaded nil
  "Non-nil once `harness-memory--load' read the database.")

(defvar harness-memory--db nil
  "The open memory database of `harness-memory--db-dir', or nil.")

(defvar harness-memory--db-dir nil
  "The state directory the open database belongs to.")

(defvar harness-memory--db-failed nil
  "Non-nil when SQLite is not usable here; there is no memory to keep.")

(defvar harness-memory--fts-ok nil
  "Non-nil when the open database has its full-text tables.
When it is nil but the database works, search filters the memories in
Elisp: SQLite can be built without FTS5.")

(defvar harness-memory--query-vectors nil
  "Recent query embeddings: ((KEY . VECTOR) ...), newest first.
KEY is (MODEL-AND-DIMENSIONS . QUERY).")

;;;; Helpers

(defun harness-memory--kind (value &optional default)
  "Return VALUE as one of `harness-memory-kinds', or DEFAULT.
An unknown kind signals a `harness-error' when DEFAULT is nil."
  (let* ((name (cond ((symbolp value) (symbol-name value))
                     ((stringp value) value)
                     (t "")))
         (kind (and (not (string-empty-p name)) (intern name))))
    (cond ((memq kind harness-memory-kinds) kind)
          (default (or (and (memq default harness-memory-kinds) default)
                       (car harness-memory-kinds)))
          (t (signal 'harness-error
                     (list (format "Memory kind must be one of %s, not %S"
                                   (string-join (mapcar #'symbol-name harness-memory-kinds) ", ")
                                   value)))))))

(defun harness-memory--scope (value &optional default)
  "Return VALUE as one of `harness-memory-scopes', or DEFAULT.
An unknown scope signals a `harness-error' when DEFAULT is nil."
  (let* ((name (cond ((symbolp value) (symbol-name value))
                     ((stringp value) value)
                     (t "")))
         (scope (and (not (string-empty-p name)) (intern name))))
    (cond ((memq scope harness-memory-scopes) scope)
          (default (or (and (memq default harness-memory-scopes) default)
                       'project))
          (t (signal 'harness-error
                     (list (format "Memory scope must be user or project, not %S" value)))))))

(defun harness-memory--kind-label (kind)
  "Return the label of KIND."
  (or (cdr (assq kind harness-memory-kind-labels)) (format "%s" kind)))

(defun harness-memory--scope-label (scope)
  "Return the label of SCOPE."
  (or (cdr (assq scope harness-memory-scope-labels)) (format "%s" scope)))

(defun harness-memory--project (dir)
  "Return DIR as the project a project memory is filed under, or nil.
The checkout a linked worktree was made from stands for the worktree,
so every worktree of a project shares its memories.  A remote name is
kept as it is: it is for the harness on that host to resolve."
  (when (and (stringp dir) (not (harness-string-blank-p dir)))
    (if (file-remote-p dir)
        (file-name-as-directory dir)
      (let* ((full (file-name-as-directory (expand-file-name dir)))
             (root (if (harness-method-exists-p 'project/root)
                       (condition-case nil (harness-call 'project/root full) (error full))
                     full))
             (main (ignore-errors (harness-project-main root))))
        (file-name-as-directory (or main root))))))

(defun harness-memory--session-project (session)
  "Return the project of SESSION, a session plist, or nil."
  (and session
       (harness-memory--project (or (plist-get session :project)
                                    (plist-get session :cwd)))))

(defun harness-memory--text (text)
  "Return TEXT trimmed as a memory, signalling when it is no memory.
A memory needs some text of its own and is at most
`harness-memory-max-chars' long."
  (let ((text (and (stringp text) (string-trim text))))
    (cond
     ((or (null text) (string-empty-p text))
      (signal 'harness-error (list "A memory needs some text")))
     ((> (length text) harness-memory-max-chars)
      (signal 'harness-error
              (list (format "A memory is at most %d characters; this one is %d. Put the detail in a file or a skill and let the memory say where it is"
                            harness-memory-max-chars (length text)))))
     (t text))))

(defun harness-memory--normalise (entry)
  "Return ENTRY as a memory, or nil when it is not one.
What the database gives back is checked here: a corrupt or half-written
row costs its own memory, not the others."
  (when (and (plistp entry)
             (stringp (plist-get entry :id)) (not (string-empty-p (plist-get entry :id)))
             (stringp (plist-get entry :text)) (not (string-empty-p (plist-get entry :text))))
    (let* ((scope (condition-case nil (harness-memory--scope (plist-get entry :scope) 'user) (error nil)))
           (kind (condition-case nil (harness-memory--kind (plist-get entry :kind) 'fact) (error nil)))
           (project (and (eq scope 'project) (harness-memory--project (plist-get entry :project)))))
      (when (and scope kind (or (eq scope 'user) project))
        (list :id (plist-get entry :id)
              :scope (symbol-name scope)
              :project project
              :kind (symbol-name kind)
              :text (plist-get entry :text)
              :created (or (plist-get entry :created) 0)
              :updated (or (plist-get entry :updated) (plist-get entry :created) 0)
              :source (plist-get entry :source))))))

(defun harness-memory--new-id ()
  "Return an id no memory has."
  (let (id)
    (while (or (null id) (harness-memory--find id))
      (setq id (concat "m-" (harness-short-id 8))))
    id))

(defun harness-memory--find (id)
  "Return the memory ID, or nil."
  (and (stringp id)
       (cl-find id harness-memory--entries :key (lambda (m) (plist-get m :id)) :test #'equal)))

(defun harness-memory--sort (entries)
  "Return ENTRIES newest first, the id breaking ties."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((ta (or (plist-get a :updated) 0))
                (tb (or (plist-get b :updated) 0)))
            (if (/= ta tb) (> ta tb)
              (string< (plist-get a :id) (plist-get b :id)))))))

(defun harness-memory--visible-p (entry &optional opts)
  "Non-nil when ENTRY is among the memories OPTS asks for.
OPTS `:scope' limits to one scope; `:kind' to one kind.  `:project',
when given, limits project memories to that project and leaves user
memories in, which is what a session sees.  Without either, every
memory is visible."
  (let ((scope (plist-get opts :scope))
        (kind (and (plist-get opts :kind)
                   (harness-memory--kind (plist-get opts :kind) nil)))
        (project (plist-get opts :project)))
    (and (or (null kind) (equal (plist-get entry :kind) (symbol-name kind)))
         (cond
          ((eq scope 'user) (equal (plist-get entry :scope) "user"))
          ((eq scope 'project)
           (and (equal (plist-get entry :scope) "project")
                (equal (plist-get entry :project) project)))
          ((equal (plist-get entry :scope) "user") t)
          (project (equal (plist-get entry :project) project))
          (t t)))))

(defun harness-memory--matching (&optional opts)
  "Return the memories OPTS asks for, newest first.
See `harness-memory--visible-p' for what OPTS selects."
  (harness-memory--sort
   (cl-remove-if-not (lambda (entry) (harness-memory--visible-p entry opts))
                     harness-memory--entries)))

(defun harness-memory--view (entry)
  "Return ENTRY with the symbols the page and the tools read as strings.
The database keeps scope and kind as strings; a caller that has been
handed one of ours may hold them as symbols."
  (when entry
    (append (list :scope (harness-memory--scope (plist-get entry :scope) 'user)
                  :kind (harness-memory--kind (plist-get entry :kind) 'fact))
            (harness-plist-remove entry :scope :kind))))

;;;; Keeping them

(defun harness-memory--load ()
  "Read the memories out of the database, once."
  (unless harness-memory--loaded
    (let ((db (harness-memory--db)))
      (when db
        (setq harness-memory--entries (harness-memory--rows db)
              harness-memory--loaded t)))))

(defun harness-memory--reset ()
  "Forget what is loaded, for a state directory that changed."
  (setq harness-memory--entries nil
        harness-memory--loaded nil
        harness-memory--query-vectors nil))

(defun harness-memory--remember (entry &optional action)
  "Put ENTRY into the database in place of the memory with its id.
ACTION, `added' or `updated', is announced as `memory/changed'; return
ENTRY as a view.  A database that cannot be written signals an error and
leaves no memory behind."
  (harness-memory--load)
  (let ((db (harness-memory--db-required)))
    (harness-memory--transaction
     db
     (lambda () (harness-memory--insert db entry)))
    (setq harness-memory--entries (harness-memory--rows db))
    (let ((view (harness-memory--view (harness-memory--find (plist-get entry :id)))))
      (harness-emit 'memory/changed view (or action 'updated))
      view)))

;;;; Making, changing and forgetting

(defun harness-memory--duplicate (text scope project)
  "Return the memory that already holds TEXT in SCOPE and PROJECT, or nil."
  (cl-find-if (lambda (entry)
                (and (equal (plist-get entry :scope) (symbol-name scope))
                     (equal (plist-get entry :project) (and (eq scope 'project) project))
                     (equal (string-trim (plist-get entry :text)) text)))
              harness-memory--entries))

(harness-defmethod memory/add (text &optional opts)
  "Save TEXT as a lasting memory; return its plist.
OPTS: `:kind' one of `harness-memory-kinds' (`preference' by default);
`:scope' `user' or `project' (`project' when a project is known, else
`user'); `:project' the project a project memory belongs to (the
session's own is the tool's default); `:source' the session it came
from; `:id' to edit that memory instead of making one; `:replaces' a
list of ids the new memory absorbs, which are forgotten with it.

Saving the same text again in the same scope and project edits the
memory that holds it.  A `project' memory needs a project.  The memory
is written at once and `memory/changed' is announced.  A replacement id
that names no memory signals a `harness-error' and changes nothing."
  (harness-memory--load)
  (let* ((opts (or opts nil))
         (text (harness-memory--text text))
         (project (harness-memory--project (plist-get opts :project)))
         (scope (harness-memory--scope (plist-get opts :scope)
                                       (if project 'project 'user)))
         (kind (harness-memory--kind (plist-get opts :kind) 'preference))
         (replaces (delete-dups (delq nil (mapcar #'identity
                                                 (if (stringp (plist-get opts :replaces))
                                                     (list (plist-get opts :replaces))
                                                   (plist-get opts :replaces))))))
         (wanted (plist-get opts :id))
         (existing (or (and wanted (harness-memory--find wanted))
                       (and (null wanted) (harness-memory--duplicate text scope project))))
         (now (float-time)))
    (when (and wanted (null (harness-memory--find wanted)))
      (signal 'harness-error (list (format "No memory %s to edit" wanted))))
    (when (and (eq scope 'project) (null project))
      (signal 'harness-error (list "A project memory needs a project")))
    (dolist (id replaces)
      (unless (harness-memory--find id)
        (signal 'harness-error (list (format "No memory %s to replace" id)))))
    (when (memq (plist-get existing :id) replaces)
      (signal 'harness-error (list "A memory cannot replace itself")))
    (let* ((entry (list :id (or (plist-get existing :id) (harness-memory--new-id))
                        :scope (symbol-name scope)
                        :project (and (eq scope 'project) project)
                        :kind (symbol-name kind)
                        :text text
                        :created (or (plist-get existing :created) now)
                        :updated now
                        :source (or (plist-get opts :source)
                                    (plist-get existing :source))))
           (db (harness-memory--db-required))
           (view (harness-memory--view entry)))
      ;; The new memory and what it absorbs are one change: either both
      ;; are written or neither is.
      (harness-memory--transaction
       db
       (lambda ()
         (dolist (id replaces)
           (unless (equal id (plist-get entry :id))
             (sqlite-execute db "DELETE FROM memories WHERE id = ?" (list id))))
         (harness-memory--insert db entry)))
      (setq harness-memory--entries (harness-memory--rows db))
      (harness-emit 'memory/changed view (if existing 'updated 'added))
      (dolist (id replaces)
        (unless (equal id (plist-get entry :id))
          (harness-emit 'memory/changed (list :id id) 'deleted)))
      view)))

(harness-defmethod memory/update (id &rest changes)
  "Change memory ID as CHANGES says; return it.
CHANGES: `:text', `:kind', `:scope', `:project'.  The id, its created
time and its source stay.  `memory/changed' is announced.  Signal a
`harness-error' when there is no memory ID or the changes are not
valid."
  (harness-memory--load)
  (let ((entry (harness-memory--find id)))
    (unless entry (signal 'harness-error (list (format "No memory %s" id))))
    (let* ((scope (if (plist-member changes :scope)
                      (harness-memory--scope (plist-get changes :scope))
                    (harness-memory--scope (plist-get entry :scope) 'project)))
           (project (harness-memory--project
                     (if (plist-member changes :project)
                         (plist-get changes :project)
                       (plist-get entry :project))))
           (kind (if (plist-member changes :kind)
                     (harness-memory--kind (plist-get changes :kind))
                   (harness-memory--kind (plist-get entry :kind) 'fact)))
           (text (if (plist-member changes :text)
                     (harness-memory--text (plist-get changes :text))
                   (plist-get entry :text))))
      (when (and (eq scope 'project) (null project))
        (signal 'harness-error (list "A project memory needs a project")))
      (harness-memory--remember
       (list :id id
             :scope (symbol-name scope)
             :project (and (eq scope 'project) project)
             :kind (symbol-name kind)
             :text text
             :created (or (plist-get entry :created) (float-time))
             :updated (float-time)
             :source (plist-get entry :source))
       'updated))))

(harness-defmethod memory/delete (id)
  "Forget memory ID; return its plist, or nil when there is none.
`memory/changed' is announced with the action `deleted'."
  (harness-memory--load)
  (when-let* ((entry (harness-memory--find id)))
    (let ((db (harness-memory--db-required)))
      (harness-memory--transaction
       db
       (lambda () (sqlite-execute db "DELETE FROM memories WHERE id = ?" (list id))))
      (setq harness-memory--entries (harness-memory--rows db))
      (let ((view (harness-memory--view entry)))
        (harness-emit 'memory/changed view 'deleted)
        view))))

(harness-defmethod memory/get (id)
  "Return memory ID as a plist, or nil."
  (harness-memory--load)
  (harness-memory--view (harness-memory--find id)))

(harness-defmethod memory/list (&optional opts)
  "Return the memories OPTS asks for, newest first.
OPTS: `:scope' `user' or `project'; `:project' the project whose
project memories are wanted, with the user memories beside them unless
`:scope' says otherwise; `:kind' one kind; `:limit' at most that many."
  (harness-memory--load)
  (let* ((opts (or opts nil))
         (project (harness-memory--project (plist-get opts :project)))
         (scope (and (plist-get opts :scope)
                     (harness-memory--scope (plist-get opts :scope) 'user)))
         (kind (and (plist-get opts :kind)
                    (harness-memory--kind (plist-get opts :kind) 'fact)))
         (limit (plist-get opts :limit))
         (found (harness-memory--matching
                 (list :scope scope :project project :kind kind))))
    (mapcar #'harness-memory--view
            (if (and (natnump limit) (> (length found) limit))
                (seq-take found limit)
              found))))

;;;; Full-text search

(defun harness-memory--parse-query (query)
  "Return the terms of text QUERY: a list of plists and the symbol `or'.
A term has `:text', and `:neg' for -word, `:prefix' for word*, `:phrase'
for \"quoted words\".  A term without a letter or digit, which no word
of the index can match, is dropped.  The syntax is the session search's
\(harness-session-search.el): every word, phrases, prefixes, OR and
-word; a plain word is matched in its forms by `harness-memory--prefixes'."
  (let ((pos 0) items)
    (while (string-match "\\(-\\)?\\(?:\"\\([^\"]*\\)\"?\\|\\([^ \t\n\r\"]+\\)\\)" query pos)
      (setq pos (max (1+ pos) (match-end 0)))
      (let* ((neg (and (match-beginning 1) t))
             (phrase (match-string 2 query))
             (word (match-string 3 query))
             (text (or phrase word))
             (prefix nil))
        ;; "--flag" is a word with dashes, not the exclusion of "-flag".
        (when (and neg word (string-prefix-p "-" word))
          (setq neg nil text (concat "-" word)))
        (if (and word (not neg) (equal word "OR"))
            (push 'or items)
          (when (and word (string-suffix-p "*" text))
            (setq prefix t text (string-trim-right text "\\*+")))
          (when (string-match-p "[[:alnum:]]" text)
            (push (list :text text :neg neg :prefix prefix :phrase (and phrase t)) items)))))
    (nreverse items)))

(defun harness-memory--prefixes (text)
  "Return the word prefixes that find TEXT in any of its forms.
TEXT itself comes first, then it with a common ending taken off, so
\"imports\" also matches \"import\", \"deploy\" matches \"deployment\",
and \"parsing\" and \"parse\" meet at \"pars\".  A stem shorter than
three letters is not used: it would match too much."
  (let ((word (downcase text))
        (prefixes nil))
    (dolist (suffix '("ments" "ment" "ings" "ing" "ers" "er" "ed" "es" "s" "ly" "e"))
      (when (and (string-suffix-p suffix word)
                 (>= (- (length word) (length suffix)) 3))
        (push (substring word 0 (- (length word) (length suffix))) prefixes)))
    (delete-dups (cons word (nreverse prefixes)))))

(defun harness-memory--fts-term (term)
  "Return TERM as an FTS5 string: quoted, a phrase as it is, a word as prefixes.
A plain word matches as any of the prefixes `harness-memory--prefixes'
gives, ORed, so it finds the word in any form; an explicit prefix
\(WORD*) stays the one prefix; a phrase must appear as it was typed."
  (let* ((text (plist-get term :text))
         (words (cond ((plist-get term :phrase) (list text))
                      ((plist-get term :prefix) (list text))
                      (t (harness-memory--prefixes text))))
         (parts (mapcar (lambda (word)
                          (concat "\"" (string-replace "\"" "\"\"" word) "\""
                                  (if (plist-get term :phrase) "" "*")))
                        words)))
    (if (cdr parts)
        (concat "(" (mapconcat #'identity parts " OR ") ")")
      (car parts))))

(defun harness-memory--fts-expression (items &optional loose)
  "Return the FTS5 MATCH expression of query ITEMS, or nil when none is positive.
Words are ANDed, or ORed when LOOSE; OR joins its neighbours; the
negated ones are excluded.  With no word but negated ones, those are
looked for instead."
  (let (groups negs or-next)
    (dolist (item items)
      (cond ((eq item 'or) (setq or-next (and groups t)))
            ((plist-get item :neg) (push item negs))
            ((and or-next groups) (push item (car groups)) (setq or-next nil))
            (t (push (list item) groups) (setq or-next nil))))
    (when (and (null groups) negs)
      (setq groups (mapcar #'list negs) negs nil))
    (when groups
      (let* ((group-text (lambda (g)
                           (if (cdr g)
                               (concat "(" (mapconcat #'harness-memory--fts-term (reverse g) " OR ") ")")
                             (harness-memory--fts-term (car g)))))
             (positive (mapconcat group-text (reverse groups) (if loose " OR " " AND "))))
        (if negs
            (concat "(" positive ") NOT (" (mapconcat #'harness-memory--fts-term (reverse negs) " OR ") ")")
          positive)))))

(defun harness-memory--loose-p (items)
  "Non-nil when query ITEMS are several plain words: a loose search may help."
  (and (cl-every (lambda (i) (and (consp i) (not (plist-get i :neg)) (not (plist-get i :phrase)))) items)
       (cdr items)))

(defun harness-memory--term-match-p (term text)
  "Non-nil when TERM matches TEXT, for a search without an FTS index.
A phrase must appear as typed; a word matches where one of its prefixes
\(`harness-memory--prefixes') begins a word of TEXT, so \"imports\"
finds \"import\" and \"deploy\" finds \"deployment\"."
  (let ((needle (downcase (plist-get term :text)))
        (haystack (downcase text)))
    (if (plist-get term :phrase)
        (string-search needle haystack)
      (let ((prefixes (harness-memory--prefixes needle)))
        (cl-some (lambda (word)
                   (cl-some (lambda (prefix) (string-prefix-p prefix word)) prefixes))
                 (split-string haystack "[^[:alnum:]]+" t))))))

(defun harness-memory--plain-match-p (items text)
  "Non-nil when TEXT matches the parsed query ITEMS without an index."
  (let (groups negs or-next)
    (dolist (item items)
      (cond ((eq item 'or) (setq or-next (and groups t)))
            ((plist-get item :neg) (push item negs))
            ((and or-next groups) (push item (car groups)) (setq or-next nil))
            (t (push (list item) groups) (setq or-next nil))))
    (when (and (null groups) negs)
      (setq groups (mapcar #'list negs) negs nil))
    (and groups
         (cl-every (lambda (group)
                     (cl-some (lambda (term) (harness-memory--term-match-p term text)) group))
                   groups)
         (cl-every (lambda (term) (not (harness-memory--term-match-p term text))) negs))))

(defun harness-memory--db-reset ()
  "Forget the open database, so the next call opens this state directory's."
  (when (and harness-memory--db
             (harness-method-exists-p 'store/sqlite-close))
    ;; Close it through the store, which caches the handle: closing it
    ;; here would leave the store handing out a closed one.
    (ignore-errors (harness-call 'store/sqlite-close harness-memory--db-name)))
  (setq harness-memory--db nil harness-memory--db-dir nil
        harness-memory--db-failed nil harness-memory--fts-ok nil))

(defun harness-memory--db-current-p ()
  "Non-nil when the open database belongs to this state directory."
  (and harness-memory--db
       (equal harness-memory--db-dir (expand-file-name (or harness-state-directory "")))))

(defun harness-memory--ensure-schema (db)
  "Make DB hold the memories and their search tables, building them when needed.
The memories table is the only copy of them, and nothing here drops it.
The full-text table and the vectors are built from it, and are made
again when they are missing."
  (dolist (sql '("CREATE TABLE IF NOT EXISTS memories (id TEXT PRIMARY KEY, scope TEXT NOT NULL, project TEXT, kind TEXT NOT NULL, text TEXT NOT NULL, created REAL NOT NULL DEFAULT 0, updated REAL NOT NULL DEFAULT 0, source TEXT)"
                 "CREATE INDEX IF NOT EXISTS memories_scope ON memories (scope, project)"
                 "CREATE TABLE IF NOT EXISTS vectors (id TEXT PRIMARY KEY, hash TEXT NOT NULL, scale REAL NOT NULL, vec BLOB NOT NULL)"
                 ;; A vector is of the text of its memory: gone with it.
                 "CREATE TRIGGER IF NOT EXISTS memories_vectors_ad AFTER DELETE ON memories BEGIN DELETE FROM vectors WHERE id = old.id; END"))
    (sqlite-execute db sql))
  ;; FTS5 is an extension some SQLite builds leave out.  Without it the
  ;; memories are searched in Elisp, and everything else still works.
  (let ((had (ignore-errors
               (caar (sqlite-select db "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'memories_fts'")))))
    (setq harness-memory--fts-ok
          (condition-case err
              (progn
                (dolist (sql '("CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(text, content='memories', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')"
                               "CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN INSERT INTO memories_fts (rowid, text) VALUES (new.rowid, new.text); END"
                               "CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN INSERT INTO memories_fts (memories_fts, rowid, text) VALUES ('delete', old.rowid, old.text); END"
                               "CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE OF text ON memories BEGIN INSERT INTO memories_fts (memories_fts, rowid, text) VALUES ('delete', old.rowid, old.text); INSERT INTO memories_fts (rowid, text) VALUES (new.rowid, new.text); END"))
                  (sqlite-execute db sql))
                t)
            (error (harness-log 'warn "memory: no full-text index, searching without one: %s"
                                (harness-error-message err))
                   nil)))
    ;; A full-text table made for an empty database starts on the
    ;; memories already in it; one added beside rows has to catch up.
    (when (and harness-memory--fts-ok (not (and had (> had 0))))
      (ignore-errors (sqlite-execute db "INSERT INTO memories_fts (memories_fts) VALUES ('rebuild')")))))

(defun harness-memory--db ()
  "Return this state directory's memory database, opening it, or nil.
Nil means SQLite is not usable here, and there is no memory to read or
keep: `harness-memory--db-required' says so to a caller that writes."
  (unless (harness-memory--db-current-p)
    (harness-memory--db-reset))
  (unless (or harness-memory--db harness-memory--db-failed)
    (condition-case err
        (let ((db (and (harness-method-exists-p 'store/sqlite)
                       (harness-call 'store/sqlite harness-memory--db-name))))
          (if (null db)
              (setq harness-memory--db-failed t)
            (let ((setup (condition-case err
                             (progn (harness-memory--ensure-schema db) t)
                           (error (harness-log 'warn "memory: cannot set up memory.db: %s"
                                               (harness-error-message err))
                                  nil))))
              (if (not setup)
                  (progn
                    (setq harness-memory--db-failed t)
                    (when (harness-method-exists-p 'store/sqlite-close)
                      (ignore-errors (harness-call 'store/sqlite-close harness-memory--db-name))))
                (ignore-errors (sqlite-pragma db "journal_mode=WAL"))
                (setq harness-memory--db db
                      harness-memory--db-dir (expand-file-name (or harness-state-directory "")))))))
      (error (setq harness-memory--db-failed t)
             (harness-log 'debug "memory: no database: %s" (harness-error-message err)))))
  harness-memory--db)

(defun harness-memory--db-required ()
  "Return the memory database, or signal that this Emacs cannot keep memories."
  (or (harness-memory--db)
      (signal 'harness-error
              (list "Memories are kept in SQLite, which is not usable in this Emacs"))))

(defun harness-memory--transaction (db fn)
  "Run FN inside a transaction on DB, committing or rolling back."
  (sqlite-transaction db)
  (condition-case err
      (prog1 (funcall fn)
        (sqlite-commit db))
    (error (ignore-errors (sqlite-rollback db))
           (signal (car err) (cdr err)))))

(defun harness-memory--insert (db entry)
  "Write ENTRY to DB, replacing the memory that has its id.
The row and its full-text entry move in the same statement, and every
caller runs its writes in a transaction of its own."
  (sqlite-execute
   db
   (concat "INSERT INTO memories (id, scope, project, kind, text, created, updated, source) "
           "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
           "ON CONFLICT(id) DO UPDATE SET scope = excluded.scope, project = excluded.project, "
           "kind = excluded.kind, text = excluded.text, updated = excluded.updated, "
           "source = excluded.source")
   (list (plist-get entry :id)
         (plist-get entry :scope)
         (and (equal (plist-get entry :scope) "project") (plist-get entry :project))
         (plist-get entry :kind)
         (plist-get entry :text)
         (or (plist-get entry :created) 0)
         (or (plist-get entry :updated) 0)
         (plist-get entry :source))))

(defun harness-memory--rows (db)
  "Return every memory DB holds, newest first."
  (delq nil
        (mapcar
         (lambda (row)
           (pcase-let ((`(,id ,scope ,project ,kind ,text ,created ,updated ,source) row))
             (harness-memory--normalise
              (list :id id :scope scope :project project :kind kind :text text
                    :created created :updated updated :source source))))
         (sqlite-select db "SELECT id, scope, project, kind, text, created, updated, source FROM memories ORDER BY updated DESC, id"))))

(defun harness-memory--fts-search (db query limit)
  "Return the memories DB matches for QUERY, best first, at most LIMIT."
  (let* ((items (harness-memory--parse-query query))
         (expr (and items (harness-memory--fts-expression items)))
         (loose nil)
         (sql (concat "WITH m AS MATERIALIZED (SELECT rowid AS rid, bm25(memories_fts) AS score "
                      "FROM memories_fts WHERE memories_fts MATCH ?) "
                      "SELECT mem.id FROM m JOIN memories mem ON mem.rowid = m.rid "
                      "ORDER BY m.score, mem.rowid DESC LIMIT ?")))
    (when expr
      (let* ((rows (sqlite-select db sql (list expr limit)))
             (found (delq nil (mapcar (lambda (row) (harness-memory--find (car row))) rows))))
        (when (and (null found) (harness-memory--loose-p items))
          (setq loose (harness-memory--fts-expression items t))
          (when loose
            (setq rows (sqlite-select db sql (list loose limit))
                  found (delq nil (mapcar (lambda (row) (harness-memory--find (car row))) rows)))))
        (list :found found :loose (and loose t) :items items)))))

;;;; Embeddings

(defun harness-memory--embedding-key ()
  "Return what the vectors are of: the model and dimensions asked for."
  (format "%s|%s" harness-memory-embedding-model
          (or harness-memory-embedding-dimensions "")))

(defun harness-memory--quantize (vector)
  "Return (SCALE . BYTES) for VECTOR, a list of numbers: int8 values offset by 128.
The dot product of a unit vector with the values of BYTES (each byte
less 128), times SCALE, is its cosine with VECTOR."
  (let* ((v (vconcat vector))
         (norm (sqrt (cl-loop for x across v sum (* (float x) x))))
         (peak (cl-loop for x across v maximize (abs x))))
    (if (or (zerop (length v)) (<= peak 0) (<= norm 0))
        (cons 0.0 (apply #'unibyte-string (make-list (length v) 128)))
      (let ((k (/ 127.0 peak)))
        (cons (/ peak (* 127.0 norm))
              (apply #'unibyte-string (cl-loop for x across v collect (+ 128 (round (* x k))))))))))

(defun harness-memory--query-ints (vector)
  "Return VECTOR made a unit vector of integers, times 1024."
  (let* ((v (vconcat vector))
         (norm (sqrt (cl-loop for x across v sum (* (float x) x)))))
    (if (<= norm 0)
        (make-vector (length v) 0)
      (cl-map 'vector (lambda (x) (round (* 1024.0 (/ x norm)))) v))))

(defun harness-memory--record-usage (usage)
  "Record what an embedding request took, USAGE, under no session."
  (when (and usage (harness-method-exists-p 'usage/record))
    (condition-case err
        (let* ((model harness-memory-embedding-model)
               (tokens (list :input (or (plist-get usage :input) 0) :output 0))
               (cost (or (and (harness-method-exists-p 'usage/price)
                              (ignore-errors (harness-call 'usage/price model tokens)))
                         0)))
          (when (> (plist-get tokens :input) 0)
            (harness-call 'usage/record (append (list :session nil :project nil :model model :cost cost) tokens))))
      (error (harness-log 'warn "memory: recording usage failed: %s" (harness-error-message err))))))

(defun harness-memory--embed (texts)
  "Return a promise of the vectors of TEXTS by the embedding model."
  (harness-then
   (harness-call 'provider/embed harness-memory-embedding-model texts
                 (and harness-memory-embedding-dimensions
                      (list :dimensions harness-memory-embedding-dimensions)))
   (lambda (result)
     (harness-memory--record-usage (plist-get result :usage))
     (plist-get result :vectors))))

(defun harness-memory--embed-batches (texts)
  "Return a promise of the vectors of TEXTS, a request per batch."
  (if (null texts)
      (harness-resolved nil)
    (let ((batch (seq-take texts harness-memory--embed-batch))
          (rest (seq-drop texts harness-memory--embed-batch)))
      (harness-then
       (harness-memory--embed batch)
       (lambda (vectors)
         (if (/= (length vectors) (length batch))
             (harness-rejected
              (list 'error (format "The embedding model answered %d vectors for %d memories"
                                   (length vectors) (length batch))))
           (harness-then (harness-memory--embed-batches rest)
                         (lambda (more) (append vectors more)))))))))

(defun harness-memory--embedding-ready-p ()
  "Non-nil when semantic search can ask for vectors."
  (and (stringp harness-memory-embedding-model)
       (not (string-empty-p harness-memory-embedding-model))
       (harness-method-exists-p 'provider/embed)))

(defun harness-memory--pending-vectors (db entries)
  "Return the ENTRIES of DB whose stored vector is not of their text."
  (cl-remove-if
   (lambda (entry)
     (let* ((id (plist-get entry :id))
            (hash (secure-hash 'sha1 (plist-get entry :text)))
            (row (car (sqlite-select db "SELECT hash FROM vectors WHERE id = ?" (list id)))))
       (and row (equal (car row) hash))))
   entries))

(defun harness-memory--embed-entries (db entries)
  "Embed ENTRIES into DB's vectors; return a promise of nil.
Only the entries without a current vector are embedded."
  (let ((pending (harness-memory--pending-vectors db entries)))
    (if (null pending)
        (harness-resolved nil)
      (harness-then
       (harness-memory--embed-batches (mapcar (lambda (e) (plist-get e :text)) pending))
       (lambda (vectors)
         (harness-memory--transaction
          db
          (lambda ()
            (cl-loop for entry in pending
                     for vector in vectors
                     for hash = (secure-hash 'sha1 (plist-get entry :text))
                     for (scale . bytes) = (harness-memory--quantize vector)
                     do (sqlite-execute db
                                        "INSERT OR REPLACE INTO vectors (id, hash, scale, vec) VALUES (?, ?, ?, ?)"
                                        (list (plist-get entry :id) hash scale
                                              (propertize bytes 'coding-system 'binary))))
            nil)))))))

(defun harness-memory--query-vector (query)
  "Return a promise of the vector of QUERY, kept for a while."
  (let* ((key (cons (harness-memory--embedding-key) query))
         (cached (assoc key harness-memory--query-vectors)))
    (if cached
        (progn (setq harness-memory--query-vectors
                     (cons cached (delete cached harness-memory--query-vectors)))
               (harness-resolved (cdr cached)))
      (harness-then
       (harness-memory--embed (list query))
       (lambda (vectors)
         (let ((vector (car vectors)))
           (unless vector
             (signal 'harness-error (list "The embedding model gave no vector for the query")))
           (push (cons key vector) harness-memory--query-vectors)
           (when (> (length harness-memory--query-vectors) harness-memory--query-cache-limit)
             (setq harness-memory--query-vectors
                   (seq-take harness-memory--query-vectors harness-memory--query-cache-limit)))
           vector))))))

(defun harness-memory--cosine (query-ints scale bytes)
  "Return the cosine of QUERY-INTS, a unit vector times 1024, with BYTES.
BYTES are int8 values offset by 128, SCALE as `harness-memory--quantize'
gives them."
  (let ((n (min (length query-ints) (length bytes)))
        (sum 0))
    (dotimes (i n)
      (cl-incf sum (* (aref query-ints i) (- (aref bytes i) 128))))
    (* sum scale 1.0 (/ 1024.0))))

(defun harness-memory--semantic-search (db entries query limit)
  "Return a promise of the ENTRIES nearest QUERY in meaning, at most LIMIT.
DB is the index, where the vectors of the entries that have none yet are
written first."
  (if (not (harness-memory--embedding-ready-p))
      (harness-rejected
       (list 'harness-error
             "Semantic memory search needs an embedding model: set harness-memory-embedding-model"))
    (harness-then
     (harness-memory--embed-entries db entries)
     (lambda (_)
       (harness-then
        (harness-memory--query-vector query)
        (lambda (vector)
          (let* ((query-ints (harness-memory--query-ints vector))
                 (scored nil))
            (dolist (entry entries)
              (when-let* ((row (car (sqlite-select db "SELECT scale, vec FROM vectors WHERE id = ?"
                                                   (list (plist-get entry :id)))))
                          (scale (nth 0 row))
                          (bytes (nth 1 row)))
                (push (cons entry (harness-memory--cosine query-ints scale
                                                          (if (multibyte-string-p bytes)
                                                              (string-to-unibyte bytes)
                                                            bytes)))
                      scored)))
            (mapcar #'car (seq-take (sort scored (lambda (a b) (> (cdr a) (cdr b)))) limit)))))))))

;;;; Search

(harness-defmethod memory/search (query &optional opts)
  "Search the memories for QUERY and return those that match, best first.
With no query, list the memories OPTS asks for, newest first.  The text
mode takes the session search's syntax (harness-session-search.el):
every word, \"quoted words\", word* prefixes, OR between words and
-word to exclude.  A word finds the forms of itself, by its prefixes
and their common endings, so \"import\" finds \"imports\" and \"deploy\"
finds \"deployment\".  A search that finds no memory with every word
returns those with some.
OPTS: `:mode' `text' (the default) or `semantic' (nearest in meaning,
by `harness-memory-embedding-model', a promise); `:scope'; `:project'
\(user memories are kept, as a session sees them); `:kind'; `:limit'
\(20 by default)."
  (harness-memory--load)
  (let* ((opts (or opts nil))
         (project (harness-memory--project (plist-get opts :project)))
         (scope (and (plist-get opts :scope)
                     (harness-memory--scope (plist-get opts :scope) 'user)))
         (kind (and (plist-get opts :kind)
                    (harness-memory--kind (plist-get opts :kind) 'fact)))
         (limit (or (plist-get opts :limit) 20))
         (mode (or (plist-get opts :mode) "text"))
         (mode (if (stringp mode) (intern mode) mode))
         (entries (harness-memory--matching
                   (list :scope scope :project project :kind kind))))
    (cond
     ((and (stringp query) (not (harness-string-blank-p query))
           (eq mode 'semantic))
      (let ((db (harness-memory--db)))
        (if db
            (harness-then
             (harness-memory--semantic-search db entries query limit)
             (lambda (found) (mapcar #'harness-memory--view found)))
          (harness-rejected
           (list 'harness-error "Semantic memory search needs SQLite in this Emacs")))))
     ((or (null query) (harness-string-blank-p query))
      (mapcar #'harness-memory--view (seq-take entries limit)))
     (t
      (let* ((items (harness-memory--parse-query query))
             (db (harness-memory--db))
             (found nil))
        (cond
         ((null items) nil)
         ((and db harness-memory--fts-ok)
          (let ((result (harness-memory--fts-search db query limit)))
            (setq found (plist-get result :found))
            ;; The full-text match ignores the scope, project and kind
            ;; limits: keep the order, but only what OPTS allows.
            (setq found (seq-take (cl-remove-if-not
                                   (lambda (entry) (harness-memory--visible-p entry
                                                                           (list :scope scope :project project :kind kind)))
                                   found)
                                  limit))))
         (t
          (setq found (seq-take (cl-remove-if
                                 (lambda (entry)
                                   (not (harness-memory--plain-match-p items (plist-get entry :text))))
                                 entries)
                                limit))
          (when (and (null found) (harness-memory--loose-p items))
            (let ((expr-items items))
              (setq found (seq-take (cl-remove-if
                                     (lambda (entry)
                                       (let ((text (plist-get entry :text)))
                                         (not (cl-some (lambda (i)
                                                         (and (consp i) (not (plist-get i :neg))
                                                              (harness-memory--term-match-p i text)))
                                                       expr-items))))
                                     entries)
                                    limit))))))
        (mapcar #'harness-memory--view found))))))

;;;; The prompt

(defun harness-memory--one-line (text)
  "Return TEXT with its whitespace runs made one space, and trimmed."
  (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim (or text ""))))

(defun harness-memory--line (entry)
  "Return ENTRY as a bullet for the prompt."
  (format "- %s" (harness-memory--one-line (plist-get entry :text))))

(defun harness-memory--index-line (entry)
  "Return one compact line naming ENTRY, with its id for `memory_get'."
  (format "- %s: %s (%s)"
          (plist-get entry :id)
          (harness-truncate-end (harness-memory--one-line (plist-get entry :text))
                                harness-memory--prompt-index-chars)
          (plist-get entry :kind)))

(defun harness-memory--section (title entries)
  "Return TITLE and ENTRIES as a Markdown section of bullets, or nil."
  (when entries
    (concat "### " title "\n"
            (mapconcat #'harness-memory--line entries "\n")
            "\n")))

(defun harness-memory--group (entries scope kind)
  "Return the ENTRIES of SCOPE and KINDS, newest first, as the database keeps them."
  (cl-remove-if-not (lambda (entry)
                      (and (equal (plist-get entry :scope) scope)
                           (member (plist-get entry :kind) kind)))
                    entries))

(harness-defmethod memory/prompt (session)
  "Return the Memory section of SESSION's system prompt, or nil.
The section holds, in this order: the project's instructions and the
user's, in full; then the project's notes and the user's, in full while
`harness-memory-prompt-budget' allows and otherwise as an index of ids
for `memory_get'.  Its text does not depend on the request, so a
conversation's prompt cache survives from step to step."
  (harness-memory--load)
  (when harness-memory-in-prompt
    (let* ((project (harness-memory--session-project session))
           (entries (harness-memory--matching (list :project project)))
           (project-instructions (harness-memory--group entries "project" '("preference" "convention")))
           (user-instructions (harness-memory--group entries "user" '("preference" "convention")))
           (project-notes (harness-memory--group entries "project" '("fact" "reference")))
           (user-notes (harness-memory--group entries "user" '("fact" "reference")))
           (head (concat "## Memory\n\n"
                         "Lasting things saved with memory_save. Treat them as the user's standing "
                         "instructions and as facts of this project; follow them. Save a new one when "
                         "the user states a preference, corrects your approach or confirms one, or "
                         "when you learn something durable that will matter in a later session. "
                         "Do not save task details, transient state or secrets.\n\n"))
           (budget (max 800 harness-memory-prompt-budget))
           (out head)
           (left (max 0 (- budget (length head)))))
      (when entries
        (cl-labels ((spend (text)
                      "Add TEXT while it fits; return non-nil when it did."
                      (if (<= (length text) left)
                          (progn (setq out (concat out text) left (- left (length text))) t)
                        nil))
                    (section (title entries index)
                      "Add ENTRIES under TITLE while they fit; return those left out.
With INDEX, each is a line naming an id for `memory_get'; otherwise
its whole text.  Return nil when every one was shown, or the entries
that were not (the title alone is shown when it fits)."
                      (when entries
                        (let* ((heading (format "### %s\n" title))
                               (lines (mapcar (lambda (entry)
                                                (concat (if index
                                                            (harness-memory--index-line entry)
                                                          (harness-memory--line entry))
                                                        "\n"))
                                              entries))
                               (full (concat heading (apply #'concat lines))))
                          (if (spend full)
                              nil
                            (let ((rest entries) (rest-lines lines))
                              (when (spend heading)
                                (while (and rest (spend (car rest-lines)))
                                  (setq rest (cdr rest)
                                        rest-lines (cdr rest-lines)))
                                rest)))))))
          ;; Instructions first: they are what the section is for.
          (let ((left-out 0))
            (dolist (pair (list (cons "Project instructions" project-instructions)
                                (cons "User instructions" user-instructions)))
              (let ((rest (section (car pair) (cdr pair) nil)))
                (when rest (cl-incf left-out (length rest)))))
            (when (> left-out 0)
              (spend (format "(%d more instruction%s; memory_search finds them)\n"
                             left-out (if (= left-out 1) "" "s")))))
          ;; Notes: all in full when they fit, else the compact index.
          (let* ((sections (list (cons "Project notes" project-notes)
                                 (cons "User notes" user-notes)))
                 (full (mapconcat (lambda (pair)
                                    (or (harness-memory--section (car pair) (cdr pair)) ""))
                                  sections "")))
            (if (and (not (string-empty-p full)) (<= (length full) left))
                (spend full)
              (let ((left-out 0))
                (dolist (pair sections)
                  (let ((rest (section (format "%s (index)" (car pair)) (cdr pair) t)))
                    (when rest (cl-incf left-out (length rest)))))
                (when (> left-out 0)
                  (spend (format "(%d more memor%s; memory_search finds them)\n"
                                 left-out (if (= left-out 1) "y" "ies"))))))))
        (string-trim-right out)))))

(defun harness-memory--system-prompt-filter (prompt session)
  "Add the Memory section to PROMPT for SESSION (`agent/system-prompt')."
  (let ((section (condition-case err
                     (harness-call 'memory/prompt session)
                   (error (harness-log 'warn "memory: the prompt section failed: %s"
                                       (harness-error-message err))
                          nil))))
    (if (or (null section) (harness-string-blank-p section))
        prompt
      (concat (or prompt "")
              (if (harness-string-blank-p prompt) "" "\n\n")
              section "\n"))))

;;;; Tools

(defun harness-memory--tool-project (ctx)
  "Return the project of the session in CTX, or its directory's."
  (let ((session (and (plist-get ctx :session-id)
                      (harness-method-exists-p 'session/get)
                      (ignore-errors (harness-call 'session/get (plist-get ctx :session-id))))))
    (or (harness-memory--session-project session)
        (harness-memory--project (plist-get ctx :cwd)))))

(defun harness-memory--format-one (entry)
  "Return ENTRY as the tools list it."
  (format "%s [%s] %s: %s"
          (plist-get entry :id)
          (if (eq (harness-memory--scope (plist-get entry :scope) 'user) 'project)
              "project" "user")
          (harness-memory--kind (plist-get entry :kind) 'fact)
          (string-trim (plist-get entry :text))))

(defun harness-memory--format-list (entries)
  "Return ENTRIES as a list the model reads, with their ids."
  (if (null entries)
      "No memories."
    (concat (format "%d memor%s:\n" (length entries) (if (= (length entries) 1) "y" "ies"))
            (mapconcat #'harness-memory--format-one entries "\n"))))

(defun harness-memory--tool-save (input ctx)
  "Handler of the memory_save tool with INPUT and CTX."
  (let* ((scope (plist-get input :scope))
         (project (harness-memory--tool-project ctx))
         (opts (list :kind (plist-get input :kind)
                     :scope scope
                     :project project
                     :source (plist-get ctx :session-id)
                     :replaces (plist-get input :replaces))))
    (condition-case err
        (let* ((entry (harness-call 'memory/add (plist-get input :text) opts))
               (replaces (plist-get input :replaces))
               (replaced (if (listp replaces) (length replaces) 0)))
          (harness-tool-ok
           (concat (format "Saved %s." (harness-memory--format-one entry))
                   (if (> replaced 0)
                       (format " Replaced %d older memor%s." replaced
                               (if (= replaced 1) "y" "ies"))
                     ""))))
      (harness-error (harness-tool-error (harness-error-message err)))
      (error (harness-tool-error (format "The memory was not saved: %s"
                                         (harness-error-message err)))))))

(defun harness-memory--search-result (input entries)
  "Return the tool result of a memory search for INPUT that found ENTRIES."
  (harness-tool-ok
   (if (null entries)
       (if (and (stringp (plist-get input :query))
                (not (harness-string-blank-p (plist-get input :query))))
           (format "No memory matches %S." (plist-get input :query))
         "No memories.")
     (harness-memory--format-list entries))))

(defun harness-memory--tool-search (input ctx)
  "Handler of the memory_search tool with INPUT and CTX."
  (let* ((project (harness-memory--tool-project ctx))
         (mode (or (plist-get input :mode) "text"))
         (opts (list :mode mode
                     :project project
                     :kind (plist-get input :kind)
                     :scope (plist-get input :scope)
                     :limit (or (plist-get input :limit) 20))))
    (condition-case err
        (let ((result (harness-call 'memory/search (or (plist-get input :query) "") opts)))
          (if (harness-promise-p result)
              (harness-then result
                            (lambda (entries) (harness-memory--search-result input entries))
                            (lambda (failure)
                              (harness-tool-error
                               (format "The memory search failed: %s"
                                       (harness-error-message failure))))))
            (harness-memory--search-result input result))
      (harness-error (harness-tool-error (harness-error-message err)))
      (error (harness-tool-error (format "The memory search failed: %s"
                                         (harness-error-message err)))))))

(defun harness-memory--tool-get (input _ctx)
  "Handler of the memory_get tool with INPUT."
  (let ((entry (and (plist-get input :id) (harness-call 'memory/get (plist-get input :id)))))
    (if entry
        (harness-tool-ok (harness-memory--format-one entry))
      (let ((close (harness-call 'memory/search (or (plist-get input :id) "") nil)))
        (harness-tool-error
         (concat (format "No memory %S." (plist-get input :id))
                 (if close
                     (format " The nearest: %s"
                             (mapconcat (lambda (e) (plist-get e :id)) (seq-take close 5) ", "))
                   " Use memory_search to find one.")))))))

(defun harness-memory--tool-forget (input _ctx)
  "Handler of the memory_forget tool with INPUT."
  (let ((deleted (and (plist-get input :id) (harness-call 'memory/delete (plist-get input :id)))))
    (if deleted
        (harness-tool-ok (format "Forgot %s: %s" (plist-get deleted :id)
                                 (string-trim (plist-get deleted :text))))
      (harness-tool-error (format "No memory %S." (plist-get input :id))))))

(defun harness-memory--tool-consolidate (input ctx)
  "Handler of the memory_consolidate tool with INPUT and CTX."
  (let ((opts (list :scope (or (plist-get input :scope) "project")
                    :project (harness-memory--tool-project ctx)
                    :session (plist-get ctx :session-id)
                    :cwd (plist-get ctx :cwd))))
    (condition-case err
        (harness-then
         (harness-call 'memory/consolidate opts)
         (lambda (result)
           (if (> (or (plist-get result :changed) 0) 0)
               (harness-tool-ok
                (format "%d memor%s consolidated: %d added, %d removed."
                        (plist-get result :changed)
                        (if (= (plist-get result :changed) 1) "y" "ies")
                        (or (plist-get result :added-count) 0)
                        (or (plist-get result :removed-count) 0)))
             (harness-tool-ok
              (format "Consolidation made no change%s."
                      (let ((why (plist-get result :reason)))
                        (if (and (stringp why) (not (string-empty-p why)))
                            (format ": %s" why) "")))))))
      (harness-error (harness-tool-error (harness-error-message err)))
      (error (harness-tool-error (format "Consolidation failed: %s"
                                         (harness-error-message err)))))))

(harness-define-tool "memory_save"
  :label "Save memory"
  :description "Save a lasting memory about the user or this project. Use it when the user states a preference, corrects your approach or confirms one, or when you learn a durable fact that will matter in a later session: a build command, a workflow, where something lives. Do not save task details, transient state, secrets, or anything the code or another memory already says. Write one concise, self-contained statement. kind: preference (how the user wants work done, in every project), convention (a rule for this codebase), fact (durable project knowledge), reference (where to find something). scope: user (every project) or project (this project). To fold older memories into this one, pass their ids in replaces."
  :schema '(:type "object"
            :properties (:text (:type "string" :description "The memory: one concise, self-contained statement.")
                         :kind (:type "string" :enum ("preference" "convention" "fact" "reference")
                                :description "What sort of memory it is.")
                         :scope (:type "string" :enum ("project" "user")
                                 :description "Project for this codebase, user for every project.")
                         :replaces (:type "array" :items (:type "string")
                                    :description "Ids of memories this one replaces or merges."))
            :required ("text" "kind" "scope"))
  :kind 'meta
  :subject (lambda (input) (plist-get input :text))
  :handler #'harness-memory--tool-save)

(harness-define-tool "memory_search"
  :label "Search memories"
  :description "Search lasting memories by words: words in any form, every word, \"quoted phrases\", word* prefixes, OR and -word. Empty lists them all. Returns ids, kinds and texts; read one by id with memory_get. Use it before asking the user about a convention, or when the Memory section names a note you need."
  :schema '(:type "object"
            :properties (:query (:type "string" :description "Words to find; empty lists the memories.")
                         :kind (:type "string" :enum ("preference" "convention" "fact" "reference"))
                         :scope (:type "string" :enum ("project" "user"))
                         :mode (:type "string" :enum ("text" "semantic")
                                :description "Text (the default) or nearest in meaning.")
                         :limit (:type "integer" :description "At most this many; 20 by default."))
            :required ("query"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :query))
  :handler #'harness-memory--tool-search)

(harness-define-tool "memory_get"
  :label "Read memory"
  :description "Read one memory by id, such as an id listed in the Memory section's index."
  :schema '(:type "object"
            :properties (:id (:type "string" :description "The memory id, m-…."))
            :required ("id"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :id))
  :handler #'harness-memory--tool-get)

(harness-define-tool "memory_forget"
  :label "Forget memory"
  :description "Delete a memory by id: one the user asked to forget, or one that is wrong or out of date."
  :schema '(:type "object"
            :properties (:id (:type "string" :description "The memory id to forget."))
            :required ("id"))
  :kind 'meta
  :subject (lambda (input) (plist-get input :id))
  :handler #'harness-memory--tool-forget)

(harness-define-tool "memory_consolidate"
  :label "Consolidate memories"
  :description "Merge overlapping memories and drop stale ones with a cheap model, for one scope. Nothing changes when the model gives no answer or an answer that does not validate. Use it when memories repeat themselves or the Memory section has grown crowded."
  :schema '(:type "object"
            :properties (:scope (:type "string" :enum ("project" "user")
                                 :description "Project (the default) or user."))
            :required ())
  :kind 'meta
  :subject (lambda (input) (plist-get input :scope))
  :handler #'harness-memory--tool-consolidate)

;;;; Consolidation

(defun harness-memory--consolidation-scope (value &optional default)
  "Return VALUE as `user' or `project', or DEFAULT."
  (harness-memory--scope value (or default 'project)))

(defun harness-memory--consolidation-prompt (entries)
  "Return the request that asks a model to consolidate ENTRIES."
  (format "Memories of one scope, each as [id] kind: text:\n\n%s\n\nConsolidate them now."
          (mapconcat (lambda (entry)
                       (format "[%s] %s: %s"
                               (plist-get entry :id)
                               (plist-get entry :kind)
                               (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim (plist-get entry :text)))))
                     entries "\n")))

(defun harness-memory--parse-consolidation (text)
  "Return the JSON object TEXT holds, or nil.
A model may wrap its answer in a code fence or a sentence; the first
object between a { and the last } is read."
  (let* ((text (and (stringp text) (string-trim text)))
         (start (and text (string-match "{" text)))
         (end (and start (string-match "}[^}]*\\'" text))))
    (when (and start end)
      (condition-case nil
          (let ((value (harness-json-parse (substring text start (1+ end)))))
            (and (plistp value) value))
        (error nil)))))

(defun harness-memory--consolidation-plan (value entries)
  "Return the changes VALUE, a model's answer, asks for among ENTRIES.
The answer is (:memories ((:text :kind :replaces) ...) :drop (ID ...)).
Every replacement id must name one of ENTRIES, no id may be replaced
twice, and a kind must be one of the four; anything else makes the
whole answer nil, so a malformed answer changes nothing.  Return
\(:add ((:text :kind :replaces ...) ...) :remove (ID ...))."
  (let* ((known (make-hash-table :test 'equal))
         (used (make-hash-table :test 'equal))
         (add nil) (remove nil) (ok t))
    (dolist (entry entries) (puthash (plist-get entry :id) entry known))
    (dolist (item (plist-get value :memories))
      (let* ((text (and (plistp item) (plist-get item :text)))
             (kind (and (plistp item) (plist-get item :kind)))
             (replaces (and (plistp item) (plist-get item :replaces)))
             (kind (condition-case nil (harness-memory--kind kind nil) (error nil)))
             (replaces (cond ((null replaces) nil)
                             ((stringp replaces) (list replaces))
                             ((listp replaces) replaces))))
        (cond
         ((or (not (stringp text)) (harness-string-blank-p text)
              (> (length (string-trim text)) harness-memory-max-chars)
              (null kind))
          (setq ok nil))
         (t
          (dolist (id replaces)
            (unless (and (stringp id) (gethash id known))
              (setq ok nil))
            (when (gethash id used)
              (setq ok nil))
            (puthash id t used))
          (push (list :text (string-trim text) :kind kind :replaces replaces) add)))))
    (dolist (id (plist-get value :drop))
      (if (and (stringp id) (gethash id known) (not (gethash id used)))
          (progn (puthash id t used) (push id remove))
        (setq ok nil)))
    (when ok
      ;; A replacement that is not named by a new memory is dropped only
      ;; when the answer drops it: nothing is deleted by accident.
      (list :add (nreverse add)
            :remove (nreverse (delete-dups (append remove
                                                   (mapcan (lambda (a) (copy-sequence (plist-get a :replaces))) add))))))))

(defun harness-memory--apply-consolidation (plan scope project)
  "Apply PLAN, made of the memories of SCOPE and PROJECT; return the result.
A new memory with no replacements and no change is not made: the plan
must add or remove something to count."
  (let* ((add (plist-get plan :add))
         (remove (plist-get plan :remove))
         (now (float-time))
         (new-entries nil))
    (dolist (item add)
      (push (list :id (harness-memory--new-id)
                  :scope (symbol-name scope)
                  :project (and (eq scope 'project) project)
                  :kind (symbol-name (plist-get item :kind))
                  :text (plist-get item :text)
                  :created now :updated now :source "consolidation")
            new-entries))
    (when (or new-entries remove)
      ;; The new memories and the ones they absorb are one change.
      (let ((db (harness-memory--db-required)))
        (harness-memory--transaction
         db
         (lambda ()
           (dolist (id remove)
             (sqlite-execute db "DELETE FROM memories WHERE id = ?" (list id)))
           (dolist (entry new-entries)
             (harness-memory--insert db entry))))
        (setq harness-memory--entries (harness-memory--rows db)))
      (dolist (entry new-entries)
        (harness-emit 'memory/changed (harness-memory--view entry) 'added))
      (dolist (id remove)
        (harness-emit 'memory/changed (list :id id) 'deleted)))
    (list :changed (+ (length new-entries) (length remove))
          :added-count (length new-entries)
          :removed-count (length remove)
          :added (mapcar #'harness-memory--view new-entries)
          :removed remove)))

(harness-defmethod memory/consolidate (&optional opts)
  "Consolidate the memories of one scope with a cheap model.
OPTS: `:scope' `project' (the default) or `user'; `:project' the
project whose memories are consolidated; `:session' or `:cwd' the place
whose model is asked; `:model' a model to ask instead of the simple
tier (see `harness-judge-ask').

The memories of the scope are given to the judge, which is asked to
merge the overlapping ones and drop stale ones.  An answer that names a
memory that does not exist, a kind that does not exist, or an id twice
changes nothing.  A change is written at once and announced.  Return a
plist (:changed N :added-count A :removed-count R :added ADDED :removed
IDS :reason WHY); N is zero when there was nothing to do or the judge
gave no usable answer, and WHY says which.  Return a promise, since a
judge answers asynchronously."
  (harness-memory--load)
  (let* ((opts (or opts nil))
         (scope (harness-memory--consolidation-scope (plist-get opts :scope) 'project))
         (project (harness-memory--project (plist-get opts :project)))
         (entries (harness-memory--matching (list :scope scope :project project)))
         (session (or (plist-get opts :session)
                      (and (plist-get opts :cwd)
                           (list :cwd (plist-get opts :cwd))))))
    (cond
     ((< (length entries) 2)
      (harness-resolved (list :changed 0 :added-count 0 :removed-count 0
                              :reason "fewer than two memories")))
     ((and (eq scope 'project) (null project))
      (harness-rejected (list 'harness-error "A project consolidation needs a project")))
     ((not (require 'harness-judge nil t))
      (harness-resolved (list :changed 0 :added-count 0 :removed-count 0
                              :reason "the judge module is not available")))
     (t
      (let* ((model (or (plist-get opts :model)
                        (ignore-errors (harness-judge-model session))))
             (system (harness-prompt 'memory-consolidate-system nil model))
             (prompt (harness-prompt 'memory-consolidate-request
                                     (list :memories (harness-memory--consolidation-prompt entries))
                                     model)))
        (harness-then
         (harness-judge-ask
          :session session
          :model model
          :system system
          :prompt prompt
          :max-tokens 1600
          :retry-max-tokens 3200
          :timeout 60
          :label "memory consolidation"
          :job "Memory consolidation"
          :parse #'harness-memory--parse-consolidation
          :prompts '(memory-consolidate-system memory-consolidate-request))
         (lambda (answer)
           (let* ((value (plist-get answer :value))
                  (plan (and value (harness-memory--consolidation-plan value entries))))
             (cond
              ((null plan)
               (list :changed 0 :added-count 0 :removed-count 0
                     :reason (or (plist-get answer :reason)
                                 "the answer did not validate")))
              (t (harness-memory--apply-consolidation plan scope project)))))))))))

;;;; Redaction

(defun harness-memory--memories-in (project sessions)
  "Return the memories of PROJECT, or those SESSIONS saved, for a redaction.
PROJECT nil means every project; SESSIONS, when non-nil, limits to the
memories whose source is one of them."
  (cl-remove-if-not
   (lambda (entry)
     (and (or (null project)
              (and (equal (plist-get entry :scope) "project")
                   (equal (plist-get entry :project) project)))
          (or (null sessions)
              (member (plist-get entry :source) sessions))))
   harness-memory--entries))

(harness-defmethod memory/redact (secrets &optional project dry-run sessions)
  "Take SECRETS out of the memories of PROJECT, or of SESSIONS.
SECRETS are plists with a `:value' string, as `secrets/redact' has them,
held in memory only: nothing here logs, emits or returns a value, and an
error says nothing of one.  PROJECT, a directory taken as `memory/list'
takes it, limits the project memories; nil is every project.  SESSIONS,
a list of session ids, limits the memories whose source is one of them.
With DRY-RUN nothing changes and only counts are returned.

Unless DRY-RUN the changed memories are written in one transaction, the
full-text index is rebuilt from them and merged, and the database is
VACUUMmed and its log emptied, so the old text is not left in its
pages.  Return (:count N :memories ((:id ID :count N)...) :available t)."
  (unless (and (proper-list-p secrets)
               (cl-every (lambda (secret)
                           (and (proper-list-p secret) (stringp (plist-get secret :value))))
                         secrets))
    (signal 'harness-error (list "SECRETS must be a list of secrets, each a plist with a :value string")))
  (harness-memory--load)
  (let* ((project (harness-memory--project project))
         (dry-run (harness-json-true-p dry-run))
         (candidates (harness-memory--memories-in
                      project (and sessions (append sessions nil))))
         (changed nil) (count 0) (updated nil))
    (dolist (entry harness-memory--entries)
      (if (not (memq entry candidates))
          (push entry updated)
        (let* ((text (plist-get entry :text))
               (replaced (harness-redaction-string text secrets))
               (new (car replaced))
               (n (cdr replaced)))
          (if (<= n 0)
              (push entry updated)
            (cl-incf count n)
            (push (list :id (plist-get entry :id) :count n) changed)
            (push (if dry-run entry
                    (plist-put (plist-put (copy-sequence entry) :text new)
                               :updated (float-time)))
                  updated)))))
    (setq changed (nreverse changed))
    (unless dry-run
      (when changed
        (let* ((db (harness-memory--db-required))
               (ids (mapcar (lambda (item) (plist-get item :id)) changed)))
          (harness-memory--transaction
           db
           (lambda ()
             (dolist (entry updated)
               (when (member (plist-get entry :id) ids)
                 (harness-memory--insert db entry)))))
          (setq harness-memory--entries (harness-memory--rows db))
          ;; The full-text index keeps the words of the old text in its
          ;; segments until they are merged, and the database keeps the
          ;; pages that held it until they are written again.
          (condition-case err
              (progn
                (when harness-memory--fts-ok
                  (ignore-errors (sqlite-execute db "INSERT INTO memories_fts (memories_fts) VALUES ('rebuild')"))
                  (ignore-errors (sqlite-execute db "INSERT INTO memories_fts (memories_fts) VALUES ('optimize')")))
                (ignore-errors (sqlite-execute db "VACUUM"))
                (ignore-errors (sqlite-pragma db "wal_checkpoint(TRUNCATE)")))
            (error (harness-log 'warn "memory: could not purge the database after a redaction: %s"
                                (harness-error-message err)))))
        (harness-log 'info "memory: took a secret out of %d memor%s"
                     (length changed) (if (= (length changed) 1) "y" "ies"))))
    (list :count count :memories changed :available t)))

;;;; Module

(defun harness-memory--init ()
  "Load the memories and add the Memory section to system prompts."
  (harness-memory--reset)
  (harness-memory--load)
  (harness-add-filter 'agent/system-prompt #'harness-memory--system-prompt-filter 55))

(defun harness-memory--shutdown ()
  "Remove the prompt filter and close the database."
  (harness-remove-filter 'agent/system-prompt #'harness-memory--system-prompt-filter)
  (harness-memory--db-reset))

(harness-declare-event 'memory/changed
                       "(VIEW ACTION) when a memory is added, updated or deleted: VIEW as the tools return it, ACTION `added', `updated' or `deleted'.")

(harness-define-module 'memory
  :doc "Lasting memories: user preferences, project conventions and facts, saved by the agent or the user, injected into every session, searched (full text and meaning), consolidated and redacted."
  :requires '(project store tools)
  :init #'harness-memory--init
  :shutdown #'harness-memory--shutdown)

(provide 'harness-memory)
;;; harness-memory.el ends here
