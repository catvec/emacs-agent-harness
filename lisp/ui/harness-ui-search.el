;;; harness-ui-search.el --- Search the sessions' transcripts  -*- lexical-binding: t; -*-

;;; Commentary:

;; C-c h g (`harness-search-sessions') reads a query and shows the
;; sessions whose transcripts or names match it, best first, each with
;; its best matches: a snippet of the message, the words found in it
;; highlighted.  RET on a match opens its session there, with point on
;; what was found; on a session's line it opens at its best match.
;;
;; The search is the harness's own (`session/search', see
;; harness-session-search.el), in one of four modes:
;;
;;   text      words, in any form: the full-text index, ranked; a
;;             "phrase", word*, OR and -word are understood
;;   literal   the text exactly as typed
;;   regexp    an extended regular expression
;;   meaning   what is near in meaning, by the embedding model
;;             (`harness-session-search-embedding-model')
;;
;; m cycles the mode, a widens the search to every project or narrows
;; it to the one it was started from, s asks another query, g searches
;; again, + shows more sessions, and n and p go from match to match.
;;
;; Opening a session at a hit is a function of its own
;; (`harness-ui-search-visit', with `harness-ui-search-hit-regexp' for
;; the words to put point on), which the quick search's [Open] uses too
;; (harness-ui-quick-search.el).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-ui)

(declare-function harness-ui-chat-goto-node "harness-ui-chat")
(declare-function harness-session-search-emacs-regexp "harness-session-search")

(defgroup harness-ui-search nil
  "Searching the sessions' transcripts." :group 'harness-ui :prefix "harness-ui-search-")

(defcustom harness-ui-search-default-mode "text"
  "How `harness-search-sessions' searches unless told otherwise.
\"text\" finds words in any form, ranked by the full-text index;
\"literal\" the text as typed; \"regexp\" an extended regular
expression; \"semantic\" what is near in meaning, which needs an
embedding model (`harness-session-search-embedding-model')."
  :type '(choice (const :tag "Words (full text)" "text")
                 (const :tag "The text as typed" "literal")
                 (const :tag "Regular expression" "regexp")
                 (const :tag "Meaning (embeddings)" "semantic")))

(defcustom harness-ui-search-default-scope 'all
  "Which sessions `harness-search-sessions' searches at first.
`all' searches the sessions of every project; `project' those of the
project it is started from, when there is one.  a switches."
  :type '(choice (const :tag "Every project" all)
                 (const :tag "The current project" project)))

(defcustom harness-ui-search-max-sessions 20
  "How many sessions a search shows at first; + shows more."
  :type 'natnum)

(defcustom harness-ui-search-max-matches 3
  "How many matches a search shows of each session."
  :type 'natnum)

(defface harness-ui-search-match-face '((t :inherit match))
  "What a search found, in the snippets of its results.")

(defface harness-ui-search-session-face '((t :inherit bold))
  "The name of a session a search found.")

(defface harness-ui-search-query-face '((t :inherit (bold font-lock-string-face)))
  "The query, above a search's results.")

(defconst harness-ui-search--buffer-name "*harness search*"
  "Name of the buffer of the search's results.")

(defconst harness-ui-search--modes
  '(("text" "Words" "Words in any form, ranked by the full-text index")
    ("literal" "Literal" "The text exactly as typed")
    ("regexp" "Regexp" "An extended regular expression")
    ("semantic" "Meaning" "Near in meaning, by the embedding model"))
  "The modes of a search: (MODE LABEL HELP), in the order m cycles.")

(defvar harness-ui-search-history nil
  "Queries searched, for the minibuffer's history.")

(defvar-local harness-ui-search--query nil "The query searched.")
(defvar-local harness-ui-search--mode "text" "The mode of the search, a string.")
(defvar-local harness-ui-search--project nil
  "The project the search is narrowed to, a directory, or nil for every project.")
(defvar-local harness-ui-search--here nil
  "The project the search was started from, a directory, or nil.")
(defvar-local harness-ui-search--max-sessions nil "How many sessions to show.")
(defvar-local harness-ui-search--result nil "The search's last result, a plist.")
(defvar-local harness-ui-search--error nil "Why the last search failed, or nil.")
(defvar-local harness-ui-search--loading nil "Non-nil while a search is on its way.")
(defvar-local harness-ui-search--seq 0
  "The number of the latest search.  Answers to earlier ones are dropped.")

;;;; Words

(defun harness-ui-search--mode-label (mode)
  "The label of MODE, a string."
  (or (nth 1 (assoc mode harness-ui-search--modes)) mode))

(defun harness-ui-search--project-name (dir)
  "The name of the project at DIR, its directory's."
  (file-name-nondirectory (directory-file-name dir)))

(defun harness-ui-search--engine-text (engine)
  "Say what searched, ENGINE as `session/search' names it."
  (pcase engine
    ("fts" "full-text index")
    ("hybrid" "full-text index, ranked by meaning")
    ("vectors" "by meaning")
    ("grep" "the logs, as typed")
    (_ nil)))

(defun harness-ui-search--role (hit)
  "Who wrote HIT's message, or what it is, in a word or two."
  (let ((kind (plist-get hit :kind))
        (tool (plist-get hit :tool))
        (from (plist-get hit :from-text)))
    (pcase kind
      ("user" (if (stringp from) (harness-truncate-end from 14) "you"))
      ("assistant" "agent")
      ("thinking" "thinking")
      ("tool-call" (if (stringp tool) tool "tool"))
      ("tool-result" (if (stringp tool) (concat tool " →") "result"))
      ("plan" "plan")
      ("compaction" "summary")
      ((pred stringp) kind)
      (_ "?"))))

(defun harness-ui-search--snippet (hit)
  "HIT's snippet on one line, what was found in it highlighted."
  (let ((text (copy-sequence (or (plist-get hit :snippet) ""))))
    (dolist (range (plist-get hit :ranges))
      (let ((from (car range)) (to (cadr range)))
        (when (and (integerp from) (integerp to) (<= 0 from to (length text)))
          (add-face-text-property from to 'harness-ui-search-match-face nil text))))
    ;; One line, keeping the faces: a newline in a match becomes a space.
    (dotimes (i (length text))
      (when (memq (aref text i) '(?\n ?\r ?\t))
        (aset text i ?\s)))
    text))

(defun harness-ui-search-hit-regexp (hit &optional query mode)
  "An Emacs regexp of what a search found in HIT, or nil.
HIT is a plist with the `:snippet' a search found, a passage of a
message, and the `:ranges' in it of what matched, each (START END): a
hit of `session/search', or a session `search/ask' found.  The chat
puts point on the regexp when a session opens at the hit
\(`harness-ui-search-visit').  It matches the very text the snippet
marks, in whatever form the words took there, any run of spaces in it
as any other.

With nothing marked it is QUERY, as a search in MODE, \"literal\" or
\"regexp\", took it; in any other mode, or with no QUERY, there is none."
  (let* ((snippet (or (plist-get hit :snippet) ""))
         (found (delete-dups
                 (cl-loop for range in (plist-get hit :ranges)
                          for from = (car range) for to = (cadr range)
                          when (and (integerp from) (integerp to) (<= 0 from to (length snippet)))
                          collect (downcase (string-trim (substring-no-properties snippet from to))))))
         (found (delete "" found))
         (query (and (stringp query) (not (string-empty-p query)) query)))
    (cond
     (found
      (mapconcat (lambda (text)
                   (mapconcat #'regexp-quote (split-string text "[ \t\n\r]+" t) "[[:space:]]+"))
                 (sort found (lambda (a b) (> (length a) (length b))))
                 "\\|"))
     ((null query) nil)
     ((equal mode "literal") (regexp-quote query))
     ((equal mode "regexp")
      (ignore-errors (harness-session-search-emacs-regexp query))))))

;;;; Rendering

(defun harness-ui-search--header (&optional width)
  "The header line: the modes, the scope and the keys, fitted to WIDTH."
  (harness-ui-fit-header
   (append
    (list (propertize " Search " 'face 'harness-usage-heading-face))
    (mapcar (lambda (m)
              (let ((chosen (equal (car m) harness-ui-search--mode)))
                (list (harness-ui-search--segment (nth 1 m) (harness-ui-search--mode-command (car m))
                                                  chosen (nth 2 m))
                      (if chosen 90 50))))
            harness-ui-search--modes)
    (list (list (propertize "  ·" 'face 'harness-dim-face) 45)
          (list (harness-ui-search--segment "All projects" (harness-ui-search--scope-command nil)
                                            (null harness-ui-search--project) "Search every project's sessions")
                (if harness-ui-search--project 48 85))
          (when-let* ((dir (or harness-ui-search--project harness-ui-search--here)))
            (list (harness-ui-search--segment (harness-ui-search--project-name dir)
                                              (harness-ui-search--scope-command dir)
                                              (and harness-ui-search--project t)
                                              (format "Only the sessions of %s, with its worktrees"
                                                      (abbreviate-file-name dir)))
                  (if harness-ui-search--project 85 47)))
          (when harness-ui-search--loading
            (list (propertize "  searching…" 'face 'harness-dim-face) 95))
          (list (concat "  " (harness-ui-search--segment "s" #'harness-ui-search-new nil "Search for something else")) 55)
          (list (harness-ui-search--segment "g" #'harness-ui-search-again nil "Search again") 58)
          (list (harness-ui-search--segment "q" #'quit-window nil "Quit") 60)))
   width))

(defun harness-ui-search--segment (label command selected help)
  "A header-line segment LABEL running COMMAND, highlighted when SELECTED.
HELP is its tooltip."
  (propertize (format " %s " label)
              'face (if selected '(bold highlight) 'harness-label-face)
              'mouse-face 'mode-line-highlight
              'help-echo help
              'local-map (harness-ui-mouse-keymap command)))

(defun harness-ui-search--mode-command (mode)
  "A command searching in MODE."
  (lambda () (interactive) (harness-ui-search-set-mode mode)))

(defun harness-ui-search--scope-command (dir)
  "A command searching the sessions of the project at DIR, or of every one."
  (lambda () (interactive) (harness-ui-search--set-project dir)))

(defun harness-ui-search--summary (result)
  "The line saying what RESULT, a search's result, found."
  (let* ((total (or (plist-get result :total) 0))
         (shown (length (plist-get result :sessions)))
         (engine (harness-ui-search--engine-text (plist-get result :engine)))
         (where (if harness-ui-search--project
                    (format " in %s" (harness-ui-search--project-name harness-ui-search--project))
                  "")))
    (concat " "
            (cond ((zerop total) (format "No session%s matches " where))
                  ((= total 1) (format "1 session%s matches " where))
                  (t (format "%d sessions%s match " total where)))
            (propertize (format "“%s”" harness-ui-search--query) 'face 'harness-ui-search-query-face)
            (if (and engine (> total 0)) (propertize (format "  ·  %s" engine) 'face 'harness-dim-face) "")
            (if (< shown total) (propertize (format "  ·  the best %d shown" shown) 'face 'harness-dim-face) "")
            "\n")))

(defun harness-ui-search--insert-session (session)
  "Insert SESSION, a session the search found, and its matches."
  (let* ((sid (plist-get session :id))
         (name (let ((n (plist-get session :name))) (if (and (stringp n) (not (string-empty-p n))) n "Untitled")))
         (project (let ((p (or (plist-get session :project) (plist-get session :cwd))))
                    (and (stringp p) (not (string-empty-p p)) (harness-ui-search--project-name p))))
         (kind (plist-get session :kind))
         (updated (plist-get session :updated))
         (hits (plist-get session :hits))
         (matches (or (plist-get session :matches) (length hits)))
         (start (point)))
    (insert "\n " (harness-ui-status-icon (or (plist-get session :status) "idle")) " "
            (propertize name 'face 'harness-ui-search-session-face)
            (if (harness-json-true-p (plist-get session :name-match))
                (propertize "  (its name matches)" 'face 'harness-dim-face)
              "")
            (propertize (concat "  "
                                (string-join
                                 (delq nil (list project
                                                 (and (stringp kind) (not (member kind '("main" ""))) kind)
                                                 (and (numberp updated) (harness-relative-time updated))))
                                 " · "))
                        'face 'harness-dim-face)
            "\n")
    (add-text-properties start (point) (list 'harness-ui-search-session sid
                                             'harness-ui-search-node (plist-get (car hits) :node)
                                             'harness-ui-search-find (and hits
                                                                          (harness-ui-search-hit-regexp
                                                                           (car hits) harness-ui-search--query
                                                                           harness-ui-search--mode))
                                             'mouse-face 'highlight
                                             'help-echo "RET: open this session at its best match"))
    (dolist (hit hits)
      (let ((from (point))
            (role (harness-ui-search--role hit)))
        (insert "     " (propertize (truncate-string-to-width role 12 nil ?\s) 'face 'harness-dim-face)
                " " (harness-ui-search--snippet hit) "\n")
        (add-text-properties from (point) (list 'harness-ui-search-session sid
                                                'harness-ui-search-node (plist-get hit :node)
                                                'harness-ui-search-find (harness-ui-search-hit-regexp
                                                                         hit harness-ui-search--query
                                                                         harness-ui-search--mode)
                                                'mouse-face 'highlight
                                                'help-echo "RET: open the session at this message"))))
    (when (> matches (length hits))
      (insert (propertize (format "     %s… %d more %s\n" (make-string 12 ?\s) (- matches (length hits))
                                  (if (= 1 (- matches (length hits))) "match" "matches"))
                          'face 'harness-dim-face)))))

(defun harness-ui-search--render (&optional first)
  "Draw the search's results, keeping point on the line it was on.
With FIRST non-nil point goes to the first match instead.  A window
showing the buffer keeps its point the same way."
  (let* ((inhibit-read-only t)
         (window (get-buffer-window (current-buffer) t))
         (line (line-number-at-pos (if window (window-point window) (point))))
         (result harness-ui-search--result))
    (erase-buffer)
    (cond
     (harness-ui-search--error
      (insert " " (propertize "The search failed: " 'face 'error) harness-ui-search--error "\n"))
     ((and harness-ui-search--loading (null result))
      (insert (propertize (format " Searching for “%s”…\n" harness-ui-search--query) 'face 'harness-dim-face)))
     (result
      (insert (harness-ui-search--summary result))
      (when-let* ((note (plist-get result :note)))
        (when (stringp note) (insert " " (propertize (concat note ".") 'face 'warning) "\n")))
      (when (harness-json-true-p (plist-get result :loose))
        (insert " " (propertize "No session has every word; these have some of them." 'face 'warning) "\n"))
      (mapc #'harness-ui-search--insert-session (plist-get result :sessions))
      (let ((more (- (or (plist-get result :total) 0) (length (plist-get result :sessions)))))
        (when (> more 0)
          (insert "\n " (propertize (substitute-command-keys
                                     (format "%d more %s: \\<harness-ui-search-mode-map>\\[harness-ui-search-more] shows more"
                                             more (if (= more 1) "session matches" "sessions match")))
                                    'face 'harness-dim-face)
                  "\n")))))
    (goto-char (point-min))
    (if first
        (let ((pos (text-property-not-all (point-min) (point-max) 'harness-ui-search-node nil)))
          (when pos (goto-char pos)))
      (forward-line (1- line)))
    (when (window-live-p window)
      (set-window-point window (point)))
    (force-mode-line-update)))

;;;; Searching

(defun harness-ui-search--run (buffer)
  "Search again for BUFFER's query, as BUFFER says, and show the result there."
  (with-current-buffer buffer
    (let ((seq (cl-incf harness-ui-search--seq)))
      (setq harness-ui-search--loading t
            harness-ui-search--error nil)
      (harness-ui-search--render)
      (harness-ui-call
       "_harness/session/search"
       (list :query harness-ui-search--query
             :opts (list :mode harness-ui-search--mode
                         :project harness-ui-search--project
                         :max-sessions harness-ui-search--max-sessions
                         :max-matches harness-ui-search-max-matches))
       (lambda (result)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= seq harness-ui-search--seq)
               ;; A new search starts on its best match; the same one,
               ;; searched again, stays where it was.
               (let ((first (null harness-ui-search--result)))
                 (setq harness-ui-search--loading nil
                       harness-ui-search--result result)
                 (harness-ui-search--render first))))))
       (lambda (err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= seq harness-ui-search--seq)
               (setq harness-ui-search--loading nil
                     harness-ui-search--result nil
                     harness-ui-search--error (harness-error-message err))
               (harness-ui-search--render)))))))))

(defun harness-ui-search--current-project ()
  "The project of the current buffer, a directory, or nil.
That is its session's project, else the task board's, else the git
checkout or project of its directory, else that directory."
  (or (when-let* ((sid harness-ui-session-id)
                  (session (harness-ui-session sid)))
        (harness-ui-session-project session))
      (bound-and-true-p harness-ui-tasks--project)
      (and (stringp default-directory) (not (file-remote-p default-directory))
           (file-name-as-directory
            (expand-file-name (or (ignore-errors (harness-files-main-root default-directory))
                                  default-directory))))))

(defun harness-ui-search--read-mode (&optional default)
  "Read a search mode with completion, DEFAULT first."
  (let* ((labels (mapcar (lambda (m) (cons (format "%s: %s" (nth 1 m) (nth 2 m)) (car m)))
                         harness-ui-search--modes))
         (default (car (rassoc (or default harness-ui-search-default-mode) labels))))
    (cdr (assoc (completing-read "Search by: " labels nil t nil nil default) labels))))

(defun harness-ui-search--read-query (prompt &optional initial)
  "Read a query with PROMPT, INITIAL the text to start from."
  (let ((query (string-trim (read-string prompt initial 'harness-ui-search-history))))
    (when (string-empty-p query) (user-error "Nothing to search for"))
    query))

;;;###autoload
(defun harness-search-sessions (query &optional mode)
  "Search the sessions' transcripts for QUERY and show what matches.
MODE is \"text\" (words in any form, ranked by the full-text index),
\"literal\", \"regexp\" or \"semantic\" (near in meaning), by default
`harness-ui-search-default-mode'; with a prefix argument it is read.
RET on a match opens its session there."
  (interactive
   (let ((mode (and current-prefix-arg (harness-ui-search--read-mode))))
     (list (harness-ui-search--read-query
            (format "Search sessions%s: " (if mode (format " (%s)" (downcase (harness-ui-search--mode-label mode))) "")))
           mode)))
  (let ((here (harness-ui-search--current-project))
        (buffer (get-buffer-create harness-ui-search--buffer-name)))
    (with-current-buffer buffer
      ;; The mode and whether to narrow to the project stay from one
      ;; search to the next; the project is the one searched from.
      (let ((narrow (if (derived-mode-p 'harness-ui-search-mode)
                        (and harness-ui-search--project t)
                      (harness-ui-search-mode)
                      (setq harness-ui-search--mode harness-ui-search-default-mode)
                      (eq harness-ui-search-default-scope 'project))))
        (setq harness-ui-search--query query
              harness-ui-search--here here
              harness-ui-search--project (and narrow here)
              harness-ui-search--result nil
              harness-ui-search--error nil
              harness-ui-search--max-sessions harness-ui-search-max-sessions))
      (when mode (setq harness-ui-search--mode mode)))
    (harness-ui-display-view buffer)
    (harness-ui-search--run buffer)
    buffer))

;;;; Commands of the results

(defun harness-ui-search--check ()
  "Signal a user error unless this is the buffer of a search."
  (unless (and (derived-mode-p 'harness-ui-search-mode) harness-ui-search--query)
    (user-error "Not a search's results")))

(defun harness-ui-search-again ()
  "Search again for the same query."
  (interactive)
  (harness-ui-search--check)
  (harness-ui-search--run (current-buffer)))

(defun harness-ui-search-new (query)
  "Search for QUERY instead, the same way."
  (interactive (list (harness-ui-search--read-query
                      (format "Search sessions (%s): " (downcase (harness-ui-search--mode-label harness-ui-search--mode)))
                      harness-ui-search--query)))
  (harness-ui-search--check)
  (setq harness-ui-search--query query
        harness-ui-search--result nil
        harness-ui-search--max-sessions harness-ui-search-max-sessions)
  (harness-ui-search--run (current-buffer)))

(defun harness-ui-search-set-mode (mode)
  "Search again in MODE: \"text\", \"literal\", \"regexp\" or \"semantic\"."
  (interactive (list (harness-ui-search--read-mode harness-ui-search--mode)))
  (harness-ui-search--check)
  (setq harness-ui-search--mode mode
        harness-ui-search--result nil)
  (harness-ui-search--run (current-buffer))
  (message "Searching by %s" (downcase (harness-ui-search--mode-label mode))))

(defun harness-ui-search-cycle-mode ()
  "Search again in the next mode: words, literal, regexp, meaning."
  (interactive)
  (harness-ui-search--check)
  (let* ((modes (mapcar #'car harness-ui-search--modes))
         (next (or (cadr (member harness-ui-search--mode modes)) (car modes))))
    (harness-ui-search-set-mode next)))

(defun harness-ui-search--set-project (dir)
  "Search again among the sessions of the project at DIR, or of every one."
  (harness-ui-search--check)
  (setq harness-ui-search--project dir
        harness-ui-search--result nil)
  (harness-ui-search--run (current-buffer)))

(defun harness-ui-search-toggle-scope ()
  "Search again in every project, or only in the one the search started from."
  (interactive)
  (harness-ui-search--check)
  (cond (harness-ui-search--project (harness-ui-search--set-project nil))
        (harness-ui-search--here (harness-ui-search--set-project harness-ui-search--here))
        (t (user-error "The search was started from no project"))))

(defun harness-ui-search-more ()
  "Show more of the sessions that match."
  (interactive)
  (harness-ui-search--check)
  (setq harness-ui-search--max-sessions (+ (or harness-ui-search--max-sessions harness-ui-search-max-sessions)
                                           harness-ui-search-max-sessions))
  (harness-ui-search--run (current-buffer)))

(defun harness-ui-search--move (forward)
  "Move to the next match, or the previous one unless FORWARD.
Point goes to the start of its line; at the last one it stays."
  (let ((pos (save-excursion
               (forward-line (if forward 1 -1))
               (while (and (not (if forward (eobp) (bobp)))
                           (not (get-text-property (point) 'harness-ui-search-node)))
                 (forward-line (if forward 1 -1)))
               (and (get-text-property (point) 'harness-ui-search-node) (point)))))
    (if pos (goto-char pos) (message "No %s match" (if forward "later" "earlier")))))

(defun harness-ui-search-next ()
  "Move to the next match, a session's best at its line."
  (interactive)
  (harness-ui-search--move t))

(defun harness-ui-search-previous ()
  "Move to the previous match."
  (interactive)
  (harness-ui-search--move nil))

(defun harness-ui-search-visit (session-id &optional node regexp)
  "Open session SESSION-ID, at NODE when one is given.
The session opens as `harness-ui-visit-session' has it.  With NODE its
chat then shows that node, point on the first match in it of REGEXP, an
Emacs regexp, and those matches highlighted (`harness-ui-chat-goto-node'):
the way a search shows what it found.  See `harness-ui-search-hit-regexp'
for the regexp of a hit."
  (harness-ui-visit-session session-id)
  (when node
    (harness-ui-chat-goto-node node session-id regexp)))

(defun harness-ui-search-open ()
  "Open the session of the match at point there, point on what was found.
On a session's line it opens at its best match."
  (interactive)
  (let ((sid (get-text-property (point) 'harness-ui-search-session))
        (node (get-text-property (point) 'harness-ui-search-node))
        (regexp (get-text-property (point) 'harness-ui-search-find)))
    (unless sid (user-error "No session on this line"))
    (harness-ui-search-visit sid node regexp)))

(defun harness-ui-search-mouse-open (event)
  "Open the session of the match clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-search-open))

;;;; Mode

(defvar harness-ui-search-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'harness-ui-search-open)
    (define-key map [mouse-1] #'harness-ui-search-mouse-open)
    (define-key map (kbd "n") #'harness-ui-search-next)
    (define-key map (kbd "p") #'harness-ui-search-previous)
    (define-key map (kbd "s") #'harness-ui-search-new)
    (define-key map (kbd "g") #'harness-ui-search-again)
    (define-key map (kbd "m") #'harness-ui-search-cycle-mode)
    (define-key map (kbd "M") #'harness-ui-search-set-mode)
    (define-key map (kbd "a") #'harness-ui-search-toggle-scope)
    (define-key map (kbd "+") #'harness-ui-search-more)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-search-mode'.")

(define-derived-mode harness-ui-search-mode special-mode "Search"
  "Major mode of the results of a search of the sessions.
\\{harness-ui-search-mode-map}"
  (setq truncate-lines t
        buffer-read-only t
        header-line-format '(:eval (harness-ui-search--header))))

;; The results' keys in the harness menu, behind `.'.
(put 'harness-ui-search-mode 'harness-menu-group
     '("Search"
       ["Results"
        (". RET" "Open the session there" harness-ui-search-open)
        (". n" "Next match" harness-ui-search-next)
        (". p" "Previous match" harness-ui-search-previous)
        (". +" "More sessions" harness-ui-search-more)]
       ["Search"
        (". s" "Something else…" harness-ui-search-new)
        (". m" "Next mode" harness-ui-search-cycle-mode)
        (". a" "Every project or this one" harness-ui-search-toggle-scope)
        (". g" "Again" harness-ui-search-again)]))

;;;; Module

(defvar harness-ui-tasks--project)

(defun harness-ui-search--init ()
  "Bind the search to the global keys."
  (define-key harness-ui-map (kbd "g") #'harness-search-sessions))

(harness-define-module 'ui-search
  :doc "Search the sessions' transcripts: words, literal text, regexps or meaning."
  :requires '(ui)
  :init #'harness-ui-search--init)

(provide 'harness-ui-search)
;;; harness-ui-search.el ends here
