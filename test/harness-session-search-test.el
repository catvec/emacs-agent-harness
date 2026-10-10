;;; harness-session-search-test.el --- Tests for the session search  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives `session/search' over real sessions in a temporary state
;; directory: what the SQLite index holds (every kind of node, the final
;; text of a streamed reply, forks, deleted sessions, a line still being
;; written), full-text queries (word forms, phrases, prefixes, OR,
;; exclusions, loose matches, ranking, names), literal and regexp search
;; by grep, the scope of a search, the fallback to grep without an
;; index, its status and rebuilding it, and semantic and hybrid search
;; with the demo provider's embedder.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)
(defvar harness-session-search-index)
(defvar harness-session-search-embedding-model)
(defvar harness-session-search-embedding-dimensions)
(defvar harness-session-search--catch-up-bytes)
(defvar harness-session-search--embedding)
(defvar harness-session-search--embed-failure)
(defvar harness-allowed-models)
(declare-function harness-session-search--db "harness-session-search")
(declare-function harness-session-search--step "harness-session-search")
(declare-function harness-session-search--sync "harness-session-search")
(declare-function harness-session-search-snippet "harness-session-search")
(declare-function harness-session-search-emacs-regexp "harness-session-search")
(declare-function harness-session-search--unanchored "harness-session-search")

(defmacro harness-session-search-test-with (&rest body)
  "Load sessions, usage and their search in a fresh state directory; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo session usage session-search))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((harness-session-search-index t)
           (harness-session-search-embedding-model nil)
           (harness-session-search-embedding-dimensions nil)
           (default-directory dir))
       ,@body)))

(defun harness-session-search-test-session (name &rest nodes)
  "Create a session called NAME holding NODES; return its id.
A node is a plist, or a string: a user message."
  (let ((id (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted" :name name)
                       :id)))
    (dolist (n nodes)
      (harness-call 'session/append id (if (stringp n) (list :kind 'user :content n) n)))
    id))

(defun harness-session-search-test-search (query &rest opts)
  "Return the result of searching for QUERY with OPTS."
  (harness-test-await (harness-call 'session/search query opts) 10))

(defun harness-session-search-test-ids (result)
  "Return the ids of the sessions of search RESULT, in order."
  (mapcar (lambda (s) (plist-get s :id)) (plist-get result :sessions)))

(defun harness-session-search-test-sorted (&rest ids)
  "Return IDS sorted."
  (sort (copy-sequence ids) #'string<))

(defun harness-session-search-test-found (query &rest opts)
  "Return the ids of the sessions a search for QUERY with OPTS finds, sorted."
  (apply #'harness-session-search-test-sorted
         (harness-session-search-test-ids (apply #'harness-session-search-test-search query opts))))

(defun harness-session-search-test-hits (result id)
  "Return the hits of session ID in search RESULT."
  (plist-get (cl-find id (plist-get result :sessions) :key (lambda (s) (plist-get s :id)) :test #'equal)
             :hits))

(defun harness-session-search-test-marked (hit)
  "Return the snippet of HIT with each of its match ranges in [brackets]."
  (let ((s (plist-get hit :snippet)) (out "") (pos 0))
    (dolist (r (plist-get hit :ranges))
      (setq out (concat out (substring s pos (car r)) "[" (substring s (car r) (cadr r)) "]")
            pos (cadr r)))
    (concat out (substring s pos))))

(defun harness-session-search-test-count (sql &rest args)
  "Return the number SQL with ARGS selects from the index."
  (caar (sqlite-select (harness-session-search--db) sql args)))

(defun harness-session-search-test-settle ()
  "Run the background of the index until it has nothing left to do."
  (let ((db (harness-session-search--db)))
    (harness-test-wait
     (lambda ()
       (and (not (harness-session-search--step db (+ (float-time) 1)))
            (not harness-session-search--embedding)
            (or (null harness-session-search-embedding-model)
                harness-session-search--embed-failure
                (zerop (harness-session-search-test-count
                        "SELECT count(*) FROM nodes WHERE embedded IS NULL")))))
     10 "the search index to settle")))

;;;; What is indexed

(ert-deftest harness-session-search-finds-words-in-every-kind-of-node ()
  "Messages, replies, thinking, tool calls (by the tool's name and its
input) and results, plans and summaries are searched; hints are not.
Each hit names its node and kind, and marks the words in its snippet."
  (harness-session-search-test-with
    (let* ((a (harness-session-search-test-session "Alpha"))
           (nodes (mapcar (lambda (n) (plist-get (harness-call 'session/append a n) :id))
                          '((:kind user :content "Please look at the zebra handler in lexer.el")
                            (:kind assistant :content "The handler drops the okapi tokens.")
                            (:kind thinking :content "Maybe the gazelle table is stale.")
                            (:kind tool-call :tool "grep" :call-id "c1" :input (:pattern "quokka_rule"))
                            (:kind tool-result :call-id "c1" :output "lexer.el:12: (defun narwhal-scan ())")
                            (:kind plan :content "1. Fix the axolotl case")
                            (:kind compaction :content "Summary: the pangolin bug was fixed")
                            (:kind hint :content "A wombat hint")))))
      (cl-loop for (word kind) in '(("zebra" user) ("okapi" assistant) ("gazelle" thinking)
                                    ("quokka_rule" tool-call) ("narwhal" tool-result) ("axolotl" plan)
                                    ("pangolin" compaction))
               for node in nodes
               do (let* ((r (harness-session-search-test-search word))
                         (hit (car (harness-session-search-test-hits r a))))
                    (should (equal "fts" (plist-get r :engine)))
                    (should (equal (list a) (harness-session-search-test-ids r)))
                    (should (equal node (plist-get hit :node)))
                    (should (eq kind (plist-get hit :kind)))))
      ;; A call is found by its tool's name too, and says which tool.
      (let ((hit (car (harness-session-search-test-hits (harness-session-search-test-search "grep") a))))
        (should (equal "grep" (plist-get hit :tool)))
        (should (equal "[grep] {\"pattern\":\"quokka_rule\"}" (harness-session-search-test-marked hit))))
      (should (equal "Please look at the [zebra] handler in lexer.el"
                     (harness-session-search-test-marked
                      (car (harness-session-search-test-hits (harness-session-search-test-search "Zebras") a)))))
      (should-not (plist-get (harness-session-search-test-search "wombat") :sessions))
      ;; The index holds a row per node searched, and has read the whole log.
      (should (= 7 (harness-session-search-test-count "SELECT count(*) FROM nodes WHERE session = ?" a)))
      (should (= 0 (plist-get (harness-call 'session/search-status) :pending))))))

(ert-deftest harness-session-search-finds-the-final-text-of-a-streamed-reply ()
  "A reply streams into its node, and its log gets the final text as an
update line: every search finds the whole of it, and none finds the
words it no longer has."
  (harness-session-search-test-with
    (let* ((a (harness-session-search-test-session "Streamer" "Tell me about marsupials"))
           (node (plist-get (harness-call 'session/append a '(:kind assistant :content "Kangaroos")) :id)))
      (should (equal (list a) (harness-session-search-test-ids (harness-session-search-test-search "kangaroos"))))
      (harness-call 'session/update-node a node :content "Kangaroos hop" :transient t)
      (harness-call 'session/update-node a node :content "Wallabies and wombats hop too.")
      (dolist (mode '(text literal regexp))
        (let ((r (harness-session-search-test-search "wombats" :mode mode)))
          (should (equal (list a) (harness-session-search-test-ids r)))
          (should (equal node (plist-get (car (harness-session-search-test-hits r a)) :node)))))
      (dolist (mode '(text literal regexp))
        (should-not (plist-get (harness-session-search-test-search "kangaroos" :mode mode) :sessions)))
      ;; Without the index, grep takes the rest of an update's node from
      ;; the session.
      (let* ((harness-session-search-index nil)
             (r (harness-session-search-test-search "wombats")))
        (should (equal "grep" (plist-get r :engine)))
        (should (equal (list a) (harness-session-search-test-ids r)))
        (should (equal "Wallabies and [wombats] hop too."
                       (harness-session-search-test-marked (car (harness-session-search-test-hits r a)))))))))

(ert-deftest harness-session-search-reads-each-log-once ()
  "The index reads only what a log gained since it last read it, leaves
a line still being written for later, and reads a log that shrank, a
replaced one, again from its start."
  (harness-session-search-test-with
    (let* ((a (harness-session-search-test-session "A" "first okapi"))
           (log (expand-file-name (concat a ".nodes.jsonl") (expand-file-name "sessions" harness-state-directory)))
           (size (lambda () (file-attribute-size (file-attributes log))))
           (offset (lambda () (harness-session-search-test-count "SELECT offset FROM logs WHERE session = ?" a))))
      (harness-session-search-test-search "okapi")
      (should (= (funcall size) (funcall offset)))
      (let ((before (funcall size)))
        (write-region "{\"id\":\"n-half\",\"kind\":\"user\",\"content\":\"half a line ab" nil log t 'silent)
        (should (harness-session-search--sync (harness-session-search--db) a))
        (should (= before (funcall offset)))
        (should-not (plist-get (harness-session-search-test-search "tapir") :sessions))
        (write-region "out a tapir\"}\n" nil log t 'silent)
        (should (equal (list a) (harness-session-search-test-ids (harness-session-search-test-search "tapir"))))
        (should (= (funcall size) (funcall offset))))
      (with-temp-file log
        (insert "{\"id\":\"n-new\",\"kind\":\"user\",\"content\":\"a new beginning with an ibex\"}\n"))
      (should (equal (list a) (harness-session-search-test-ids (harness-session-search-test-search "ibex"))))
      (should-not (plist-get (harness-session-search-test-search "tapir") :sessions))
      (should (= 1 (harness-session-search-test-count "SELECT count(*) FROM nodes WHERE session = ?" a))))))

(ert-deftest harness-session-search-follows-forks-and-deletions ()
  "A fork's copy of its parent's history is found under the fork too; a
deleted session's rows leave the index."
  (harness-session-search-test-with
    (let* ((parent (harness-session-search-test-session "Parent" "The capybara question"))
           (child (plist-get (harness-test-await (harness-call 'session/fork parent :name "Child")) :id)))
      (harness-session-search-test-settle)
      (should (equal (harness-session-search-test-sorted parent child) (harness-session-search-test-found "capybara")))
      (harness-call 'session/delete parent)
      (harness-session-search-test-settle)
      (should (equal (list child) (harness-session-search-test-found "capybara")))
      (should (= 0 (harness-session-search-test-count "SELECT count(*) FROM nodes WHERE session = ?" parent)))
      (should (= 0 (harness-session-search-test-count "SELECT count(*) FROM logs WHERE session = ?" parent))))))

;;;; Full-text queries

(ert-deftest harness-session-search-reads-words-phrases-prefixes-or-and-not ()
  "A word matches in any form, case and accents aside; every word must
match; \"a phrase\" matches in order, word* as a prefix, OR either word,
and -word excludes."
  (harness-session-search-test-with
    (let ((a (harness-session-search-test-session "A" "The lexer chokes on nested quotes in the Café menu while parsing"))
          (b (harness-session-search-test-session "B" "Quoting is hard; it parses nested strings badly"))
          (c (harness-session-search-test-session "C" "Use --no-verify only when the hook is broken")))
      (should (equal (harness-session-search-test-sorted a b) (harness-session-search-test-found "parse")))
      (should (equal (harness-session-search-test-sorted a b) (harness-session-search-test-found "QUOTE")))
      (should (equal (list a) (harness-session-search-test-found "cafe")))
      (should (equal (list a) (harness-session-search-test-found "lexer menu")))
      (should (equal (list a) (harness-session-search-test-found "\"nested quotes\"")))
      (should-not (harness-session-search-test-found "\"quotes nested\""))
      (should (equal (harness-session-search-test-sorted a b) (harness-session-search-test-found "pars*")))
      (should (equal (harness-session-search-test-sorted a c) (harness-session-search-test-found "menu OR hook")))
      (should (equal (list b) (harness-session-search-test-found "nested -menu")))
      ;; A word that starts with dashes is a word, not an exclusion.
      (should (equal (list c) (harness-session-search-test-found "--no-verify")))
      ;; Without a word, the text is matched as typed.
      (let ((d (harness-session-search-test-session "D" "What?!? ... ?!?")))
        (let ((r (harness-session-search-test-search "?!?")))
          (should (equal "grep" (plist-get r :engine)))
          (should (string-match-p "No word to search for" (plist-get r :note)))
          (should (equal (list d) (harness-session-search-test-ids r))))))))

(ert-deftest harness-session-search-falls-back-to-some-of-the-words ()
  "When no session has every word, those with some of them come, best
first, and the result says so."
  (harness-session-search-test-with
    (let ((a (harness-session-search-test-session "A" "the lexer is slow"))
          (b (harness-session-search-test-session "B" "the hook is broken"))
          (both (harness-session-search-test-session "Both" "lexer hook")))
      (let ((r (harness-session-search-test-search "lexer hook")))
        (should-not (plist-get r :loose))
        (should (equal (list both) (harness-session-search-test-ids r))))
      (harness-call 'session/delete both)
      (let ((r (harness-session-search-test-search "lexer hook")))
        (should (plist-get r :loose))
        (should (equal (harness-session-search-test-sorted a b)
                       (apply #'harness-session-search-test-sorted (harness-session-search-test-ids r)))))
      ;; A phrase or an exclusion asks for exactly that: no loose match.
      (should-not (plist-get (harness-session-search-test-search "\"lexer hook\"") :sessions))
      (should-not (plist-get (harness-session-search-test-search "lexer hook -slow -broken") :sessions)))))

(ert-deftest harness-session-search-ranks-the-best-match-first ()
  "Sessions come best match first, whatever their age: by their best
node, fused with the sessions whose name has the words, so a session
both name and content match ranks highest.  `:matches' counts a
session's matching nodes, of which `:max-matches' come."
  (harness-session-search-test-with
    (let* ((strong (harness-session-search-test-session
                    "Strong" "tokenizer tokenizer: the tokenizer is broken" "the tokenizer again"
                    "and the tokenizer" "one more tokenizer"))
           (weak (harness-session-search-test-session
                  "Weak" (concat "A long story. " (mapconcat #'identity (make-list 200 "of other things") " ")
                                 " It mentions the tokenizer once.")))
           (named (harness-session-search-test-session "Tokenizer notes" "it drops a byte at the end"))
           (both (harness-session-search-test-session "Tokenizer bug" "the tokenizer drops a byte")))
      (let ((r (harness-session-search-test-search "tokenizer" :max-matches 2)))
        (should (equal "fts" (plist-get r :engine)))
        (should (equal (list both strong named weak) (harness-session-search-test-ids r)))
        (should (= 4 (plist-get r :total)))
        (let ((s (car (plist-get r :sessions))))
          (should (plist-get s :name-match))
          (should (numberp (plist-get s :score))))
        (let ((s (nth 1 (plist-get r :sessions))))
          (should-not (plist-get s :name-match))
          (should (= 4 (plist-get s :matches)))
          (should (= 2 (length (plist-get s :hits)))))
        (let ((s (nth 2 (plist-get r :sessions))))
          (should (plist-get s :name-match))
          (should (= 0 (plist-get s :matches)))
          (should-not (plist-get s :hits))))
      ;; Literal search is newest first, names included.
      (should (equal (list both named weak strong)
                     (harness-session-search-test-ids (harness-session-search-test-search "tokenizer" :mode 'literal)))))))

(ert-deftest harness-session-search-searches-what-it-is-asked-to ()
  "`:sessions', `:exclude', `:project' and `:kinds' narrow a search, in
every mode; `:max-sessions' cuts what comes back, and `:total' says how
many matched."
  (harness-session-search-test-with
    (let* ((a (harness-session-search-test-session
               "A" "a giraffe in a message" '(:kind tool-result :call-id "c" :output "a giraffe in the output")))
           (b (harness-session-search-test-session "B" "a giraffe again"))
           (other (let ((default-directory (harness-test-temp-dir)))
                    (harness-session-search-test-session "Other" "a giraffe elsewhere"))))
      (dolist (mode '(text literal regexp))
        (should (equal (harness-session-search-test-sorted a b other)
                       (harness-session-search-test-found "giraffe" :mode mode)))
        (should (equal (list a) (harness-session-search-test-found "giraffe" :mode mode :sessions (list a))))
        (should (equal (harness-session-search-test-sorted b other)
                       (harness-session-search-test-found "giraffe" :mode mode :exclude (list a))))
        (should (equal (harness-session-search-test-sorted a b)
                       (harness-session-search-test-found "giraffe" :mode mode :project default-directory)))
        (let ((r (harness-session-search-test-search "giraffe" :mode mode :kinds '("tool-result"))))
          (should (equal (list a) (harness-session-search-test-ids r)))
          (should (eq 'tool-result (plist-get (car (harness-session-search-test-hits r a)) :kind))))
        (let ((r (harness-session-search-test-search "giraffe" :mode mode :max-sessions 1)))
          (should (= 1 (length (plist-get r :sessions))))
          (should (= 3 (plist-get r :total)))))
      (should (equal "none" (plist-get (harness-session-search-test-search "giraffe" :sessions '("s-none")) :engine)))
      (should-error (harness-session-search-test-search "   "))
      (should-error (harness-session-search-test-search "giraffe" :mode 'fuzzy)))))

;;;; Literal and regexp search

(ert-deftest harness-session-search-literal-and-regexp-search-by-grep ()
  "Literal search finds the text as given, special characters and quotes
included; regexp search reads grep -E syntax; both ignore case, match
names too, and come newest first."
  (harness-session-search-test-with
    (let* ((old (harness-session-search-test-session "Old" "call foo.bar(baz) twice"))
           (new (harness-session-search-test-session "New" "fooXbar(baz) and the \"zebra\" handler")))
      (let ((r (harness-session-search-test-search "FOO.BAR(" :mode 'literal)))
        (should (equal "grep" (plist-get r :engine)))
        (should (equal (list old) (harness-session-search-test-ids r)))
        (should (equal "call [foo.bar(]baz) twice"
                       (harness-session-search-test-marked (car (harness-session-search-test-hits r old))))))
      (should (equal (list new) (harness-session-search-test-ids
                                 (harness-session-search-test-search "\"zebra\" handler" :mode 'literal))))
      (should (equal (list new old) (harness-session-search-test-ids
                                     (harness-session-search-test-search "foo.bar\\(baz\\)" :mode 'regexp))))
      (let ((r (harness-session-search-test-search "(twice|thrice)\\s*$|ZEB+RA" :mode "regexp")))
        (should (equal (list new old) (harness-session-search-test-ids r)))
        (should (equal "fooXbar(baz) and the \"[zebra]\" handler"
                       (harness-session-search-test-marked (car (harness-session-search-test-hits r new))))))
      ;; Anchors hold at the start and end of the text, not of the log's line.
      (should (equal (list new) (harness-session-search-test-ids
                                 (harness-session-search-test-search "^foo" :mode 'regexp))))
      (should (equal (list old) (harness-session-search-test-ids
                                 (harness-session-search-test-search "^call [a-z.]+\\(baz\\) twice$" :mode 'regexp))))
      (should-not (plist-get (harness-session-search-test-search "^twice" :mode 'regexp) :sessions))
      ;; Names match, with no hit to show.
      (let ((r (harness-session-search-test-search "^ne" :mode 'regexp)))
        (should (equal (list new) (harness-session-search-test-ids r)))
        (should (plist-get (car (plist-get r :sessions)) :name-match))
        (should-not (harness-session-search-test-hits r new)))
      ;; A regexp grep cannot read fails the search.
      (should-error (harness-session-search-test-search "(unclosed" :mode 'regexp)))))

(ert-deftest harness-session-search-reads-extended-regexps ()
  "An extended regexp as grep -E reads it becomes the same Emacs regexp."
  (harness-session-search-test-with
    (should (equal "a\\(b\\|c\\)\\{2\\}" (harness-session-search-emacs-regexp "a(b|c){2}")))
    (should (equal "f(x)|y" (harness-session-search-emacs-regexp "f\\(x\\)\\|y")))
    (should (equal "a[^z-a]b" (harness-session-search-emacs-regexp "a.b")))
    (should (equal "[[:space:]]+[^[:space:]]" (harness-session-search-emacs-regexp "\\s+\\S")))
    (should (equal "[(|.)]x" (harness-session-search-emacs-regexp "[(|.)]x")))
    (should (equal "[]a[:alpha:]]+" (harness-session-search-emacs-regexp "[]a[:alpha:]]+")))
    (should (equal "\\\\" (harness-session-search-emacs-regexp "\\")))
    ;; For grep over the logs, the anchors go; escaped or in brackets they stay.
    (should (equal "foo|bar\\$[$^]" (harness-session-search--unanchored "^foo$|^bar\\$[$^]$")))))

(ert-deftest harness-session-search-snippet-stays-short ()
  "A snippet shows the match where it is, on one line, cut to a few hundred characters."
  (harness-session-search-test-with
    (let ((text (concat (make-string 1000000 ?x) " see\n\n   README.md   for\tdetails " (make-string 1000000 ?y))))
      (should (equal (concat "…" (make-string 65 ?x) " see README.md for details " (make-string 77 ?y) "…")
                     (harness-session-search-snippet text "readme.md" nil)))
      (should (equal (harness-session-search-snippet text "readme.md" nil)
                     (harness-session-search-snippet text "R[a-z]+ME\\.md" t)))
      ;; A long match, which overflows the matcher over the whole text, is
      ;; cut 300 characters after its start.
      (let ((snippet (harness-session-search-snippet text "README.*y" t)))
        (should (string-prefix-p (concat "…" (make-string 65 ?x) " see README.md for details yyy") snippet))
        (should (= (+ 1 70 300 1) (length snippet))))
      ;; Without a match, the start of the text.
      (should (equal (concat (make-string 159 ?x) "…") (harness-session-search-snippet text "zebra" nil)))
      (should (equal (concat (make-string 159 ?x) "…") (harness-session-search-snippet text "\\(" t)))
      ;; A short text is shown whole.
      (should (equal "line 3: ZEBRA stripes" (harness-session-search-snippet "line 3:\nZEBRA  stripes" "zebra" nil))))))

(ert-deftest harness-session-search-snippets-of-long-nodes-stay-short ()
  "A node of megabytes is found by every mode, with a short snippet."
  (harness-session-search-test-with
    (let ((a (harness-session-search-test-session
              "A" (list :kind 'tool-result :call-id "c"
                        :output (concat (make-string 1000 ?x) " see README.md for details "
                                        (make-string 1500000 ?y))))))
      (dolist (mode '(text literal regexp))
        (let* ((r (harness-session-search-test-search (if (eq mode 'regexp) "READ.E\\.md" "readme.md") :mode mode))
               (hit (car (harness-session-search-test-hits r a))))
          (should (equal (list a) (harness-session-search-test-ids r)))
          (should (string-match-p "README\\.md for details" (plist-get hit :snippet)))
          (should (< (length (plist-get hit :snippet)) 400))
          (should (string-match-p "\\`\\[?README\\.md\\]?\\'"
                                  (apply #'substring (plist-get hit :snippet) (car (plist-get hit :ranges))))))))))

;;;; Without the index

(ert-deftest harness-session-search-falls-back-to-grep ()
  "Without the index, or while it is far behind, text search matches the
text as typed, by grep, and says why; once the background catches up,
the index answers."
  (harness-session-search-test-with
    (let ((a (harness-session-search-test-session "A" "The parsing step")))
      (let ((harness-session-search-index nil))
        (let ((r (harness-session-search-test-search "parsing step")))
          (should (equal "grep" (plist-get r :engine)))
          (should (equal "No full-text index (harness-session-search-index is off): the text was matched as typed"
                         (plist-get r :note)))
          (should (equal (list a) (harness-session-search-test-ids r))))
        (should-not (plist-get (harness-session-search-test-search "parse") :sessions))
        (should (equal '(:index nil :reason "harness-session-search-index is off")
                       (harness-call 'session/search-status)))
        (should-error (harness-session-search-test-search "parse" :mode 'semantic)))
      (let ((b (harness-session-search-test-session "B" "Another parsing step"))
            (harness-session-search--catch-up-bytes 10))
        (let ((r (harness-session-search-test-search "parsing")))
          (should (equal "grep" (plist-get r :engine)))
          (should (string-match-p "\\`The full-text index is still being built (0% done)" (plist-get r :note)))
          (should (equal (list b a) (harness-session-search-test-ids r)))))
      (harness-session-search-test-settle)
      (let ((r (harness-session-search-test-search "parse")))
        (should (equal "fts" (plist-get r :engine)))
        (should-not (plist-get r :note))
        (should (= 2 (plist-get r :total)))))))

(ert-deftest harness-session-search-status-and-rebuild ()
  "The status says what the index holds; a rebuild drops it and the
background builds it again; an index of another version is built anew."
  (harness-session-search-test-with
    (let ((a (harness-session-search-test-session "A" "one ibex" "two ibexes")))
      (harness-session-search-test-search "ibex")
      (let ((status (harness-call 'session/search-status)))
        (should (eq t (plist-get status :index)))
        (should (equal (expand-file-name "search.db" harness-state-directory) (plist-get status :file)))
        (should (> (plist-get status :size) 0))
        (should (= 1 (plist-get status :sessions)))
        (should (= 2 (plist-get status :nodes)))
        (should (= 0 (plist-get status :pending)))
        (should-not (plist-get status :progress))
        (should-not (plist-get status :embedding)))
      (let ((status (harness-call 'session/search-rebuild)))
        (should (= 0 (plist-get status :nodes)))
        (should (= 1 (plist-get status :pending)))
        (should (= 0 (plist-get status :progress))))
      (harness-session-search-test-settle)
      (should (= 2 (plist-get (harness-call 'session/search-status) :nodes)))
      (should (equal (list a) (harness-session-search-test-ids (harness-session-search-test-search "ibex"))))
      (sqlite-execute (harness-session-search--db) "UPDATE meta SET value = '0' WHERE key = 'schema'")
      (harness-call 'store/sqlite-close "search")
      (should (= 0 (plist-get (harness-call 'session/search-status) :nodes)))
      (should (equal (list a) (harness-session-search-test-ids (harness-session-search-test-search "ibex")))))))

;;;; By meaning

(ert-deftest harness-session-search-finds-what-is-near-in-meaning ()
  "With an embedding model, the background embeds messages and replies
once each; semantic search finds them by meaning; text search ranks the
sessions with the words by it too, and when none has them, the nearest
in meaning stand in, and the result says so."
  (harness-session-search-test-with
    (let* ((harness-session-search-embedding-model "demo:embed")
           (recorded nil)
           (_ (harness-on 'usage/recorded (lambda (row) (push row recorded))))
           (crash (harness-session-search-test-session
                   "One" "The app crashes when I open a file" '(:kind tool-result :call-id "c" :output "crash log")))
           (docs (harness-session-search-test-session "Two" "Write the readme for the new release"))
           (speed (harness-session-search-test-session "Three" "Make the slow startup faster")))
      (harness-session-search-test-settle)
      (let ((status (plist-get (harness-call 'session/search-status) :embedding)))
        (should (equal "demo:embed" (plist-get status :model)))
        ;; Tool output is not embedded.
        (should (= 3 (plist-get status :chunks)))
        (should (= 0 (plist-get status :pending)))
        (should-not (plist-get status :error)))
      (let* ((r (harness-session-search-test-search "a bug" :mode 'semantic))
             (hit (car (harness-session-search-test-hits r crash))))
        (should (equal "vectors" (plist-get r :engine)))
        (should (equal crash (car (harness-session-search-test-ids r))))
        (should (equal "The app crashes when I open a file" (plist-get hit :snippet)))
        (should (eq 'user (plist-get hit :kind)))
        (should (> (plist-get hit :score) 0.3)))
      (let ((r (harness-session-search-test-search "documentation")))
        (should (equal "vectors" (plist-get r :engine)))
        (should (equal (list docs) (harness-session-search-test-ids r)))
        (should (equal "No session has these words: these are the nearest in meaning" (plist-get r :note))))
      (let ((r (harness-session-search-test-search "startup")))
        (should (equal "hybrid" (plist-get r :engine)))
        (should (equal (list speed) (harness-session-search-test-ids r)))
        (should-not (plist-get r :note)))
      ;; The same text in another session is not embedded again.
      (let ((copy (harness-session-search-test-session "Four" "Make the slow startup faster")))
        (harness-session-search-test-settle)
        (should (= 4 (harness-session-search-test-count "SELECT count(*) FROM chunks")))
        (should (= 3 (harness-session-search-test-count "SELECT count(*) FROM vectors")))
        (should (equal (harness-session-search-test-sorted speed copy)
                       (harness-session-search-test-found "faster startup"))))
      ;; The tokens embedding took are recorded, under no session.
      (should recorded)
      (dolist (row recorded)
        (should-not (plist-get row :session))
        (should (equal "demo:embed" (plist-get row :model)))
        (should (> (plist-get row :input) 0)))
      ;; Another model embeds everything again.
      (let ((harness-session-search-embedding-dimensions 32))
        (harness-session-search-test-settle)
        (should (= 4 (harness-session-search-test-count "SELECT count(*) FROM chunks")))
        (should (= 32 (harness-session-search-test-count "SELECT length(vec) FROM vectors LIMIT 1")))
        (should (equal crash (car (harness-session-search-test-ids
                                   (harness-session-search-test-search "error" :mode 'semantic))))))
      (let ((harness-session-search-embedding-model nil))
        (should (string-match-p "needs an embedding model"
                                (cadr (should-error (harness-session-search-test-search "bug" :mode 'semantic)))))
        ;; Text search goes on without vectors.
        (should (equal "fts" (plist-get (harness-session-search-test-search "startup") :engine)))))))

(ert-deftest harness-session-search-waits-for-a-failing-embedder ()
  "A model that cannot embed leaves text search working; semantic search
says why it has nothing, and the background tries again later, with
fewer texts at a time."
  (harness-session-search-test-with
    (let ((harness-session-search-embedding-model "demo:embed")
          (harness-allowed-models '("demo:scripted"))
          (a (harness-session-search-test-session "A" "The app crashes")))
      (harness-session-search-test-settle)
      (should harness-session-search--embed-failure)
      (should (string-match-p "demo:embed" (plist-get (plist-get (harness-call 'session/search-status) :embedding) :error)))
      (should (string-match-p "No session text is embedded yet: .*demo:embed"
                              (cadr (should-error (harness-session-search-test-search "bug" :mode 'semantic)))))
      (should (equal (list a) (harness-session-search-test-ids (harness-session-search-test-search "crashes")))))))

(provide 'harness-session-search-test)
;;; harness-session-search-test.el ends here
