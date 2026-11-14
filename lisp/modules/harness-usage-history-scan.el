;;; harness-usage-history-scan.el --- Metadata-only historical usage reader -*- lexical-binding: t; -*-

;;; Commentary:

;; The only historical source read here is sessions/ID.nodes.jsonl, for
;; IDs explicitly supplied by the caller.  The session layer appends
;; nodes, updates and deletes there.  The agent stores the provider's
;; last usage event in an assistant node's :meta :usage, alongside its
;; :model.  Session-record :usage is cumulative, not dated history, and
;; provider call-usage events are not persisted.  Neither session record
;; files nor provider transcripts, auth directories or arbitrary logs
;; are read.  In particular, hosted Claude/Copilot turn totals often
;; arrive too late to be attached to an assistant node at all.
;;
;; This is a partial historical source, never a replacement for a usage
;; ledger.  A node's timestamp dates its creation, not the usage event.
;; Missing usage, request identity, model provenance and counters are
;; coverage gaps, not zero readings.  Fork-inherited nodes are excluded.
;; Updates replace metadata as the session loader does; deleted nodes
;; are excluded, with coverage accounting for the potential loss.  Event
;; workspace stamps, or an immovable worktree scope, supply attribution;
;; an ordinary session's current directory cannot date its old usage.
;;
;; JSONL is read in bounded byte chunks.  A projecting JSON reader skips
;; message strings, tool arguments/results, blocks and arbitrary metadata
;; without decoding or constructing their values.  Only fixed whitelist
;; keys can leave the line buffer.  No parse error quotes input, and no
;; transcript text is returned, written, logged or sent to a model.
;;
;; `harness-usage-history-scan' is the synchronous entry point, intended
;; for a worker or tests.  `harness-usage-history-scan-run' returns a
;; promise and performs file reading in a fresh background batch Emacs,
;; following the Insights child-process pattern.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'harness-core)
(require 'harness-util)

(defvar harness-elisp-emacs)

(defconst harness-usage-history-scan--chunk-bytes (* 64 1024)
  "Bytes read at a time, independently of the node log's total size.")

(defconst harness-usage-history-scan--line-bytes (* 4 1024 1024)
  "Maximum bytes retained for one JSONL record; larger lines are gaps.")

(defconst harness-usage-history-scan--timeout 120
  "Seconds allowed for the background metadata reader.")

(defconst harness-usage-history-scan--token-keys
  '(:input :output :cache-read :cache-write)
  "Token categories whose absence must remain unknown.")

(defun harness-usage-history-scan--number-p (value)
  "Non-nil for a finite, nonnegative real VALUE."
  (and (numberp value) (>= value 0) (<= value most-positive-fixnum)))

(defun harness-usage-history-scan--text (value &optional limit)
  "Return bounded, control-free text VALUE, or nil; LIMIT defaults to 512."
  (and (stringp value) (> (length value) 0)
       (<= (length value) (or limit 512))
       (not (string-match-p "[[:cntrl:]]" value)) value))

(defun harness-usage-history-scan--identity (value)
  "Return a bounded scalar identity VALUE, or nil."
  (or (harness-usage-history-scan--text value 256)
      (and (harness-usage-history-scan--number-p value) value)))

(defun harness-usage-history-scan--enum (value choices)
  "Return VALUE as a string if it is a member of CHOICES."
  (let ((text (if (symbolp value) (symbol-name value) value)))
    (and (member text choices) text)))

(defun harness-usage-history-scan-normalize (record model &optional granularity source)
  "Return whitelisted usage and provenance from RECORD for MODEL.
GRANULARITY is \"call\", \"turn\" or \"unknown\".  SOURCE is
\"session-log\" for a provider event, or \"ledger\" (the default) for
old ledger rows whose cost may have been catalogue-priced.

The result has :version 1, :usage, :input-semantics,
:cache-write-status, :cost-source, :observed-cost and :currency.
Explicit :pricing and :priced-at are preserved, never invented.
A present :usage, even nil, is authoritative counter-presence
provenance from newer providers.  Otherwise only positive legacy
counters are trusted: old providers and ledger code manufactured zero
for missing categories.  OpenAI/Responses legacy writes are
not-reported unless positive, and Claude/Copilot zero writes unknown.

Legacy native :context arithmetic proves inclusive or exclusive
input when cache reads are known; it is not used for hosted turn
summaries, whose context sizes only the last call.  Legacy Responses
and generic OpenAI input is inclusive, DeepSeek and Bedrock exclusive;
OpenRouter without context evidence is unknown, since its gateway can
report either layout.  A missing cache-read leaves the split unknown.
This function never consults a current catalogue or prices history."
  (let* ((raw-p (and (listp record) (plist-member record :usage)))
         (raw (if raw-p (plist-get record :usage) record))
         (provider (and (stringp model) (car (split-string model ":"))))
         (hosted (or (equal granularity "turn") (member provider '("claude" "copilot"))))
         usage pricing)
    (dolist (key (append harness-usage-history-scan--token-keys '(:context :last-output)))
      (let ((n (and (listp raw) (plist-get raw key))))
        (when (and (harness-usage-history-scan--number-p n) (or raw-p (> n 0)))
          (setq usage (plist-put usage key n)))))
    ;; Monetary amounts are not token-presence evidence.  Their provenance
    ;; below decides whether a recorded amount is an observed USD cost.
    (dolist (key '(:cost :list-cost))
      (let ((n (plist-get record key)))
        (when (harness-usage-history-scan--number-p n)
          (setq usage (plist-put usage key n)))))
    (dolist (key harness-usage-history-scan--token-keys)
      (let ((n (plist-get (plist-get record :pricing) key)))
        (when (harness-usage-history-scan--number-p n)
          (setq pricing (plist-put pricing key n)))))
    (let* ((input (plist-get usage :input))
           (read (plist-get usage :cache-read))
           (write (plist-get usage :cache-write))
           (context (plist-get usage :context))
           (semantics
            (or (harness-usage-history-scan--enum
                 (plist-get record :input-semantics) '("exclusive" "inclusive" "unknown"))
                (cond
                 ((or (null input) (null read)) "unknown")
                 ((and (not hosted) context (> read 0) (= context input)) "inclusive")
                 ((and (not hosted) context (= context (+ input read (or write 0)))) "exclusive")
                 ((member provider '("responses" "chatgpt" "openai")) "inclusive")
                 ((member provider '("deepseek" "bedrock" "claude" "copilot")) "exclusive")
                 (t "unknown"))))
           (write-status
            (or (harness-usage-history-scan--enum
                 (plist-get record :cache-write-status) '("reported" "not-reported" "unknown"))
                (cond (write "reported")
                      ((member provider '("openai" "openrouter" "responses" "chatgpt" "deepseek"))
                       "not-reported")
                      (t "unknown"))))
           (cost-source
            (or (harness-usage-history-scan--enum
                 (plist-get record :cost-source) '("observed" "estimated" "subscription" "unknown" "legacy"))
                (and (equal (harness-usage-history-scan--enum
                             (plist-get record :billing) '("subscription")) "subscription")
                     "subscription")
                ;; Copilot's legacy USD counter was a quota conversion, not
                ;; an observed bill; only explicit newer origins override it.
                (and (equal source "session-log") (equal provider "copilot")
                     (harness-usage-history-scan--number-p (plist-get record :cost)) "estimated")
                (and (equal source "session-log")
                     (harness-usage-history-scan--number-p (plist-get record :cost)) "observed")
                "unknown"))
           (observed (or (and (equal cost-source "observed")
                              (harness-usage-history-scan--number-p (plist-get record :observed-cost))
                              (plist-get record :observed-cost))
                         (and (equal cost-source "observed")
                              (harness-usage-history-scan--number-p (plist-get record :cost))
                              (plist-get record :cost)))))
      (append (list :version 1 :usage usage :input-semantics semantics
                    :cache-write-status write-status :cost-source cost-source
                    :observed-cost observed
                    :currency (if (not (plist-member record :currency)) "USD"
                                (let ((currency (plist-get record :currency)))
                                  (if (and (stringp currency)
                                           (string-match-p "\\`[A-Z]\\{3\\}\\'" currency))
                                      currency "unknown")))
                    :billing (harness-usage-history-scan--enum
                              (plist-get record :billing) '("api" "extra-usage" "subscription")))
              (and (harness-usage-history-scan--number-p (plist-get record :cost))
                   (list :recorded-cost (plist-get record :cost)))
              (and pricing (list :pricing pricing))
              (and (harness-usage-history-scan--number-p (plist-get record :priced-at))
                   (list :priced-at (plist-get record :priced-at)))))))

;;;; Projecting JSON reader

;; An entry is (JSON-KEY PLIST-KEY TYPE).  TYPE is a scalar name or a
;; nested whitelist.  Skipped objects never decode even their keys.
(defconst harness-usage-history-scan--counts-spec
  '(("input" :input number) ("output" :output number)
    ("cache-read" :cache-read number) ("cache-write" :cache-write number)
    ("context" :context number) ("last-output" :last-output number))
  "Raw token metadata whitelist.")

(defconst harness-usage-history-scan--usage-spec
  (append harness-usage-history-scan--counts-spec
          `(("cost" :cost number) ("list-cost" :list-cost number)
            ("usage" :usage ,harness-usage-history-scan--counts-spec)
            ("model" :model string) ("request-id" :request-id identity)
            ("message-id" :message-id identity) ("turn-id" :turn-id identity)
            ("turn" :turn identity) ("scope" :scope string)
            ("granularity" :granularity string) ("cumulative" :cumulative boolean)
            ("input-semantics" :input-semantics string)
            ("cache-write-status" :cache-write-status string)
            ("cost-source" :cost-source string) ("observed-cost" :observed-cost number)
            ("currency" :currency string) ("billing" :billing string) ("pricing" :pricing ,harness-usage-history-scan--counts-spec)
            ("priced-at" :priced-at number)))
  "Usage event whitelist, including explicit newer-provider provenance.")

(defconst harness-usage-history-scan--meta-spec
  `(("model" :model string) ("project" :project string)
    ("usage" :usage ,harness-usage-history-scan--usage-spec)
    ("request-id" :request-id identity) ("message-id" :message-id identity)
    ("turn-id" :turn-id identity) ("turn" :turn identity)
    ("usage-scope" :usage-scope string) ("granularity" :granularity string)
    ("steering" :steering boolean))
  "Assistant metadata whitelist; no arbitrary metadata survives.")

(defconst harness-usage-history-scan--node-spec
  `(("id" :id identity) ("session" :session string) ("kind" :kind string)
    ("ts" :ts number) ("_op" :_op string) ("meta" :meta ,harness-usage-history-scan--meta-spec)
    ("request-id" :request-id identity) ("message-id" :message-id identity)
    ("turn-id" :turn-id identity) ("turn" :turn identity))
  "Node whitelist; no content, blocks, tool names, arguments or results.")

(defun harness-usage-history-scan--invalid ()
  "Signal a parse error without including any part of the private record."
  (error "Invalid usage metadata record"))

(defun harness-usage-history-scan--space ()
  "Advance over JSON whitespace."
  (skip-chars-forward " \t\r\n"))

(defun harness-usage-history-scan--string-end ()
  "Skip one JSON string without constructing its value."
  (unless (eq (char-after) ?\") (harness-usage-history-scan--invalid))
  (forward-char)
  (catch 'end
    (while (re-search-forward "[\"\\\\\x00-\x1f]" nil t)
      (pcase (char-before)
        (?\" (throw 'end t))
        (?\\
         (let ((c (char-after)))
           (unless (memq c '(?\" ?\\ ?/ ?b ?f ?n ?r ?t ?u))
             (harness-usage-history-scan--invalid))
           (forward-char)
           (when (eq c ?u)
             (unless (looking-at "[[:xdigit:]]\\{4\\}")
               (harness-usage-history-scan--invalid))
             (forward-char 4))))
        (_ (harness-usage-history-scan--invalid))))
    (harness-usage-history-scan--invalid)))

(defun harness-usage-history-scan--value (spec depth)
  "Consume one JSON value, projecting SPEC, at nesting DEPTH.
Nil SPEC validates and skips without allocating the value."
  (when (> depth 128) (harness-usage-history-scan--invalid))
  (harness-usage-history-scan--space)
  (let ((start (point)) value)
    (pcase (char-after)
      (?\"
       (harness-usage-history-scan--string-end)
       (when (and (memq spec '(string identity key))
                  (<= (- (point) start) (if (eq spec 'key) 128 4096)))
         (setq value (json-parse-string
                      (decode-coding-string (buffer-substring-no-properties start (point)) 'utf-8)
                      :null-object nil :false-object :false))))
      (?{
       (forward-char)
       (harness-usage-history-scan--space)
       (unless (eq (char-after) ?})
         (let ((more t))
           (while more
             (unless (eq (char-after) ?\") (harness-usage-history-scan--invalid))
             (let* ((key (harness-usage-history-scan--value (and (consp spec) 'key) (1+ depth)))
                    (entry (and key (consp spec) (assoc key spec))))
               (harness-usage-history-scan--space)
               (unless (eq (char-after) ?:) (harness-usage-history-scan--invalid))
               (forward-char)
               (let ((v (harness-usage-history-scan--value (nth 2 entry) (1+ depth))))
                 (when entry (setq value (plist-put value (nth 1 entry) v)))))
             (harness-usage-history-scan--space)
             (if (eq (char-after) ?,)
                 (progn (forward-char) (harness-usage-history-scan--space))
               (setq more nil)))))
       (unless (eq (char-after) ?}) (harness-usage-history-scan--invalid))
       (forward-char))
      (?\[
       (forward-char)
       (harness-usage-history-scan--space)
       (unless (eq (char-after) ?\])
         (let ((more t))
           (while more
             (harness-usage-history-scan--value nil (1+ depth))
             (harness-usage-history-scan--space)
             (if (eq (char-after) ?,)
                 (progn (forward-char) (harness-usage-history-scan--space))
               (setq more nil)))))
       (unless (eq (char-after) ?\]) (harness-usage-history-scan--invalid))
       (forward-char))
      ((or ?t ?f ?n)
       (cond ((looking-at "true") (goto-char (match-end 0)) (when (eq spec 'boolean) (setq value t)))
             ((looking-at "false") (goto-char (match-end 0)))
             ((looking-at "null") (goto-char (match-end 0)))
             (t (harness-usage-history-scan--invalid))))
      (_
       (unless (looking-at "-?\\(?:0\\|[1-9][0-9]*\\)\\(?:\\.[0-9]+\\)?\\(?:[eE][+-]?[0-9]+\\)?")
         (harness-usage-history-scan--invalid))
       (goto-char (match-end 0))
       (when (memq spec '(number identity))
         (setq value (string-to-number (buffer-substring-no-properties start (point)))))))
    value))

(defun harness-usage-history-scan--record ()
  "Project the current narrowed JSONL line to safe metadata only."
  (goto-char (point-min))
  (harness-usage-history-scan--space)
  (unless (eq (char-after) ?{) (harness-usage-history-scan--invalid))
  (let ((record (harness-usage-history-scan--value harness-usage-history-scan--node-spec 0)))
    (harness-usage-history-scan--space)
    (unless (eobp) (harness-usage-history-scan--invalid))
    record))

;;;; Reading and ownership

(defun harness-usage-history-scan--bump (coverage key &optional amount)
  "Increment COVERAGE's KEY by AMOUNT, default one."
  (setf (plist-get coverage key) (+ (or (plist-get coverage key) 0) (or amount 1))))

(defun harness-usage-history-scan--gap (coverage gap)
  "Record the fixed GAP code in COVERAGE."
  (unless (member gap (plist-get coverage :gaps))
    (setf (plist-get coverage :gaps) (append (plist-get coverage :gaps) (list gap)))))

(defun harness-usage-history-scan--read (file consume coverage)
  "Read FILE incrementally; call CONSUME with projected records.
Parse failures contribute only counters to COVERAGE, never payloads."
  (let ((size (file-attribute-size (file-attributes file)))
        (offset 0) dropping)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((coding-system-for-read 'no-conversion))
        (while (< offset size)
          (goto-char (point-max))
          (let ((end (min size (+ offset harness-usage-history-scan--chunk-bytes))))
            (insert-file-contents-literally file nil offset end)
            (setq offset end))
          (goto-char (point-min))
          (let ((start (point-min)))
            (while (search-forward "\n" nil t)
              (let ((next (point)) (end (1- (point))))
                (harness-usage-history-scan--bump coverage :lines)
                (cond
                 (dropping (setq dropping nil))
                 ((> (- end start) harness-usage-history-scan--line-bytes)
                  (harness-usage-history-scan--bump coverage :oversized-lines))
                 (t
                  (save-restriction
                    (narrow-to-region start end)
                    (unless (save-excursion
                              (goto-char (point-min))
                              (skip-chars-forward " \t\r")
                              (eobp))
                      (let ((record (condition-case nil (harness-usage-history-scan--record)
                                      (error (harness-usage-history-scan--bump coverage :malformed-lines) nil))))
                        (when record (funcall consume record)))))))
                (setq start next)
                (goto-char next)))
            (delete-region (point-min) start))
          (when (> (buffer-size) harness-usage-history-scan--line-bytes)
            (unless dropping (harness-usage-history-scan--bump coverage :oversized-lines))
            (setq dropping t)
            (erase-buffer)))
        ;; Even a syntactically complete last record without its newline
        ;; can still be in flight.  Do not turn a partial append into usage.
        (when (or dropping (> (buffer-size) 0))
          (harness-usage-history-scan--bump coverage :partial-lines))))))

(defun harness-usage-history-scan--nodes (file sid coverage)
  "Return only metadata of FILE's nodes owned by SID, in append order."
  (let ((table (make-hash-table :test 'equal))
        (ordered (make-hash-table :test 'equal)) order result)
    (harness-usage-history-scan--read
     file
     (lambda (record)
       (let ((id (harness-usage-history-scan--identity (plist-get record :id)))
             (op (plist-get record :_op)))
         (when id
           (cond
            ((equal op "delete")
             (when (gethash id table)
               (harness-usage-history-scan--bump coverage :deleted-nodes)
               (remhash id table)))
            ((equal op "update")
             (if-let* ((old (gethash id table)))
                 (puthash id (harness-plist-merge old (harness-plist-remove record :_op)) table)
               (harness-usage-history-scan--bump coverage :orphan-updates)))
            ((and op (not (equal op "append")))
             (harness-usage-history-scan--bump coverage :malformed-lines))
            (t
             (when (gethash id table)
               (harness-usage-history-scan--bump coverage :duplicate-nodes))
             (unless (gethash id ordered)
               (puthash id t ordered)
               (push id order))
             (puthash id record table))))))
     coverage)
    (dolist (id (nreverse order))
      (when-let* ((node (gethash id table)))
        (let ((owner (harness-usage-history-scan--text (plist-get node :session))))
          (cond
           ((and owner (not (equal owner sid)))
            (harness-usage-history-scan--bump coverage :inherited-nodes))
           (t
            (unless owner (harness-usage-history-scan--bump coverage :missing-owner-nodes))
            (push node result))))))
    (nreverse result)))

(defun harness-usage-history-scan--input (input)
  "Return INPUT reduced to safe descriptors and scan boundaries.
No descriptor's arbitrary fields enter the worker's request file."
  (let ((dir (plist-get input :sessions-dir))
        (since (plist-get input :since)) (until (plist-get input :until)) sessions)
    (unless (and (stringp dir) (not (file-remote-p dir))
                 (or (null since) (harness-usage-history-scan--number-p since))
                 (or (null until) (harness-usage-history-scan--number-p until))
                 (or (null since) (null until) (<= since until))
                 (listp (plist-get input :sessions)))
      (error "Invalid historical usage scan input"))
    (dolist (s (plist-get input :sessions))
      (let ((id (plist-get s :id)))
        (push (append (list :id (and (stringp id) (<= (length id) 128)
                                    (string-match-p "\\`[[:alnum:]_-]+\\'" id) id)
                           :project (harness-usage-history-scan--text (plist-get s :project) 4096)
                           :scope-stable (and (harness-json-true-p (plist-get s :scope-stable)) t))
                      (and (plist-member s :main)
                           (list :main (harness-usage-history-scan--text (plist-get s :main) 4096))))
              sessions)))
    (list :sessions-dir (expand-file-name dir) :sessions (nreverse sessions) :since since :until until)))

(defun harness-usage-history-scan--granularity (node model)
  "Return NODE's usage granularity, using only documented MODEL routes."
  (let* ((meta (plist-get node :meta)) (usage (plist-get meta :usage))
         (scope (or (plist-get usage :scope) (plist-get usage :granularity)
                    (plist-get meta :usage-scope) (plist-get meta :granularity)))
         (provider (and model (car (split-string model ":")))))
    (or (harness-usage-history-scan--enum scope '("call" "turn" "session"))
        (and (plist-get usage :cumulative) "turn")
        (cond ((member provider '("claude" "copilot")) "turn")
              ((member provider '("openai" "openrouter" "deepseek" "responses" "chatgpt" "bedrock")) "call")
              (t "unknown")))))

(defun harness-usage-history-scan--samples (nodes descriptor coverage)
  "Return deduplicated metadata samples from NODES for DESCRIPTOR.
Cumulative turns keep only their last snapshot.  Explicit request or
message IDs take precedence.  Without those IDs, identical call
snapshots in one inferred turn collapse, and unknown-granularity
snapshots keep only the last.  These conservative losses are gaps,
never invented deltas or extra calls."
  (let ((sid (plist-get descriptor :id)) (table (make-hash-table :test 'equal))
        (identities (make-hash-table :test 'equal)) turn order)
    (dolist (node nodes)
      (let* ((meta (plist-get node :meta)) (record (plist-get meta :usage))
             (kind (plist-get node :kind)))
        (when (and (equal kind "user") (not (plist-get meta :steering)))
          (setq turn (plist-get node :id)))
        (when (equal kind "assistant")
          (if (null record)
              (harness-usage-history-scan--bump coverage :missing-usage-nodes)
            (let* ((model (harness-usage-history-scan--text (plist-get meta :model)))
                   (granularity (harness-usage-history-scan--granularity node model))
                   (explicit-turn (harness-usage-history-scan--identity
                                   (or (plist-get record :turn-id) (plist-get record :turn)
                                       (plist-get meta :turn-id) (plist-get meta :turn)
                                       (plist-get node :turn-id) (plist-get node :turn))))
                   (tid (or explicit-turn turn))
                   (request (harness-usage-history-scan--identity
                             (or (plist-get record :request-id) (plist-get meta :request-id)
                                 (plist-get node :request-id))))
                   (message (harness-usage-history-scan--identity
                             (or (plist-get record :message-id) (plist-get meta :message-id)
                                 (plist-get node :message-id))))
                   (details (harness-usage-history-scan-normalize record model granularity "session-log"))
                   (usage (plist-get details :usage))
                   (ts (plist-get node :ts))
                   (recorded-project (harness-usage-history-scan--text (plist-get meta :project) 4096))
                   (project (or recorded-project
                                (and (plist-get descriptor :scope-stable) (plist-get descriptor :project))))
                   (request-key (and request (gethash (list "request" request) identities)))
                   (message-key (and message (gethash (list "message" message) identities)))
                   (key (cond
                         ((equal granularity "session") nil)
                         ((equal granularity "turn") (list "turn" tid model))
                         ((or request message)
                          (or request-key message-key
                              (if request (list "request" request) (list "message" message))))
                         ((equal granularity "call") (list "snapshot" tid model usage))
                         (t (list "unknown" tid model)))))
              ;; A late chunk can bridge two identities first seen separately.
              ;; Union their existing records before replacing the snapshot;
              ;; merely aliasing future chunks would leave one bill counted twice.
              (when (and request-key message-key (not (equal request-key message-key))
                         (not (member granularity '("turn" "session"))))
                (let* ((kept (gethash key table))
                       (other (gethash message-key table))
                       (dates (delq nil (list (plist-get kept :ts) (plist-get other :ts)))))
                  (when dates (setf (plist-get kept :ts) (apply #'min dates)))
                  (remhash message-key table)
                  (setq order (cl-delete message-key order :test #'equal))
                  (maphash (lambda (identity target)
                             (when (equal target message-key) (puthash identity key identities))) identities)
                  (harness-usage-history-scan--bump coverage :duplicate-samples)))
              (cond
               ((equal granularity "session")
                (harness-usage-history-scan--bump coverage :unallocated-samples))
               ((not usage) (harness-usage-history-scan--bump coverage :empty-usage-nodes))
               (t
                (unless model (harness-usage-history-scan--bump coverage :model-gaps))
                (unless project (harness-usage-history-scan--bump coverage :unattributed-samples))
                (unless (or request message (and explicit-turn (equal granularity "turn")))
                  (harness-usage-history-scan--bump coverage :ambiguous-samples))
                (let* ((old (gethash key table))
                       (sample (append
                                (list :id (if old (plist-get old :id)
                                            (format "session-log:%s:%s" sid (plist-get node :id)))
                                      :session sid :node (plist-get node :id)
                                      :project project
                                      :main (and project (equal project (plist-get descriptor :project))
                                                 (or (plist-get descriptor :main) project))
                                      :attribution (cond (recorded-project "recorded")
                                                         (project "stable-worktree") (t "unknown"))
                                      :model model :ts (and (harness-usage-history-scan--number-p ts) ts)
                                      :turn tid :turn-source (cond (explicit-turn "recorded") (turn "user-node") (t "unknown"))
                                      :source "session-log" :granularity granularity)
                                (and request (list :request request)) (and message (list :message message)) details)))
                  ;; A request's first chunk dates the request; a cumulative
                  ;; turn's final snapshot dates the turn total instead.
                  (when old
                    (harness-usage-history-scan--bump coverage :duplicate-samples)
                    (when (and (or request message) (not (equal granularity "turn")))
                      (setf (plist-get sample :ts) (or (plist-get old :ts) (plist-get sample :ts)))))
                  (unless old (push key order))
                  (unless (equal granularity "turn")
                    (when request (puthash (list "request" request) key identities))
                    (when message (puthash (list "message" message) key identities)))
                  (puthash key sample table)))))))))
    (mapcar (lambda (key) (gethash key table)) (nreverse order))))

(defun harness-usage-history-scan (input)
  "Return (:samples LIST :coverage PLIST) for metadata-only INPUT.
INPUT has :sessions-dir, :sessions (safe :id/:project/:main descriptors),
:since (inclusive float or nil) and :until (exclusive float or nil).
Only explicitly named local ID.nodes.jsonl regular files are read;
symlinks, path traversal, provider directories and session record files
are not sources.  No current descriptor model is applied to old nodes.

Each sample has :id, :session, :node, :project, :main, :model, :ts,
:turn, :turn-source, :source \"session-log\", :granularity and the
fields returned by `harness-usage-history-scan-normalize'.  Optional
:request/:message carry recorded request/message identities.
Undated samples and session-cumulative counters are counted as gaps,
not returned as dated events.  Deduplication precedes date filtering.

Coverage includes a :status string (empty, partial or failed),
:supported-sources, :gaps string codes, per-session :sessions and
numeric file/line/metadata gap counters.  Even healthy node logs are
partial: usage events without an assistant attachment are unrecoverable."
  (let* ((input (harness-usage-history-scan--input input))
         (dir (plist-get input :sessions-dir)) (since (plist-get input :since))
         (until (plist-get input :until)) (seen (make-hash-table :test 'equal))
         (coverage (list :version 1 :status "partial" :supported-sources '("session-log")
                         :files-requested 0 :files-read 0 :files-missing 0 :files-unreadable 0
                         :files-rejected 0 :lines 0 :malformed-lines 0 :partial-lines 0 :oversized-lines 0
                         :inherited-nodes 0 :missing-owner-nodes 0 :deleted-nodes 0 :orphan-updates 0
                         :duplicate-nodes 0 :duplicate-samples 0 :ambiguous-samples 0 :undated-samples 0
                         :unallocated-samples 0 :empty-usage-nodes 0 :missing-usage-nodes 0 :model-gaps 0
                         :unknown-input-semantics 0 :partial-usage-samples 0 :unattributed-samples 0 :samples 0
                         :gaps '("assistant-metadata-only" "unrecorded-usage-events" "node-creation-timestamps")
                         :sessions nil))
         samples sessions)
    (dolist (s (plist-get input :sessions))
      (let* ((sid (plist-get s :id)) (status "missing") (count 0)
             (file (and sid (expand-file-name (concat sid ".nodes.jsonl") dir))))
        (unless (and sid (gethash sid seen))
          (when sid (puthash sid t seen))
          (harness-usage-history-scan--bump coverage :files-requested)
          (cond
           ((or (null sid) (file-symlink-p file)
                (and (file-exists-p file) (not (file-regular-p file)))
                (file-symlink-p (directory-file-name dir)))
            (setq status "rejected") (harness-usage-history-scan--bump coverage :files-rejected))
           ((not (file-exists-p file)) (harness-usage-history-scan--bump coverage :files-missing))
           ((not (file-readable-p file))
            (setq status "unreadable") (harness-usage-history-scan--bump coverage :files-unreadable))
           (t
            (condition-case nil
                (let ((found (harness-usage-history-scan--samples
                              (harness-usage-history-scan--nodes file sid coverage) s coverage)))
                  (setq status "partial")
                  (harness-usage-history-scan--bump coverage :files-read)
                  (dolist (sample found)
                    (let ((ts (plist-get sample :ts)) (usage (plist-get sample :usage)))
                      (cond
                       ((null ts) (harness-usage-history-scan--bump coverage :undated-samples))
                       ((and (or (null since) (>= ts since)) (or (null until) (< ts until)))
                        (cl-incf count)
                        (when (equal (plist-get sample :input-semantics) "unknown")
                          (harness-usage-history-scan--bump coverage :unknown-input-semantics))
                        (unless (cl-every (lambda (key) (plist-member usage key)) harness-usage-history-scan--token-keys)
                          (harness-usage-history-scan--bump coverage :partial-usage-samples))
                        (push sample samples))))))
              (error (setq status "unreadable")
                     (harness-usage-history-scan--bump coverage :files-unreadable)))))
          (push (list :session sid :status status :samples count) sessions))))
    (dolist (entry '((:files-missing . "missing-files") (:files-unreadable . "unreadable-files")
                     (:files-rejected . "rejected-files") (:malformed-lines . "malformed-records")
                     (:partial-lines . "partial-records") (:oversized-lines . "oversized-records")
                     (:missing-usage-nodes . "missing-usage") (:model-gaps . "missing-model")
                     (:missing-owner-nodes . "missing-node-owner") (:deleted-nodes . "deleted-nodes")
                     (:orphan-updates . "orphan-updates") (:ambiguous-samples . "ambiguous-request-identity")
                     (:undated-samples . "undated-usage") (:unallocated-samples . "session-cumulative-usage")
                     (:partial-usage-samples . "missing-token-categories")
                     (:unattributed-samples . "workspace-attribution-unknown")
                     (:unknown-input-semantics . "unknown-input-semantics")))
      (when (> (plist-get coverage (car entry)) 0)
        (harness-usage-history-scan--gap coverage (cdr entry))))
    (setf (plist-get coverage :sessions) (nreverse sessions)
          (plist-get coverage :samples) (length samples)
          (plist-get coverage :status) (cond ((zerop (plist-get coverage :files-requested)) "empty")
                                              ((zerop (plist-get coverage :files-read)) "failed")
                                              (t "partial")))
    (list :samples (sort samples (lambda (a b) (< (plist-get a :ts) (plist-get b :ts))))
          :coverage coverage)))

;;;; Background worker

(defun harness-usage-history-scan-main ()
  "Run the metadata scanner in a child Emacs using its request/output files."
  (let* ((input (getenv "HARNESS_USAGE_HISTORY_INPUT"))
         (output (getenv "HARNESS_USAGE_HISTORY_OUTPUT"))
         (result (condition-case nil
                     (harness-usage-history-scan (harness-json-parse (harness-read-file input)))
                   (error (list :error "Historical usage scan failure")))))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (harness-json-encode result) nil output nil 'silent)))
  (kill-emacs 0))

(defun harness-usage-history-scan-run (input)
  "Return a promise of a metadata-only scan of INPUT in a child Emacs.
Only sanitized descriptors enter temporary request files.  Worker
failures reject with fixed diagnostic text, never child stderr or a
parse error containing private record data.  Temporary files are
removed on completion, rejection, timeout and process-start failure."
  (condition-case nil
      (let* ((safe (harness-usage-history-scan--input input))
             (dir (make-temp-file "harness-usage-history-" t))
             (in (expand-file-name "input.json" dir)) (out (expand-file-name "output.json" dir))
             (clean (lambda () (ignore-errors (delete-directory dir t)))))
        ;; Interpreted closures retain their lexical environment.  Do not
        ;; retain the unsanitized caller object in a worker callback.
        (setq input nil)
        (condition-case nil
            (progn
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region (harness-json-encode safe) nil in nil 'silent))
              (harness-then
               (harness-run-command
                (list (if (boundp 'harness-elisp-emacs) harness-elisp-emacs
                        (expand-file-name invocation-name invocation-directory))
                      "--batch" "-Q" "-L" harness-directory
                      "-L" (expand-file-name "lisp" harness-directory)
                      "-L" (expand-file-name "lisp/modules" harness-directory)
                      "-l" (symbol-file 'harness-usage-history-scan-main 'defun)
                      "-f" "harness-usage-history-scan-main")
                :cwd dir :timeout harness-usage-history-scan--timeout :name "harness-usage-history"
                :env (list (cons "HARNESS_USAGE_HISTORY_INPUT" in) (cons "HARNESS_USAGE_HISTORY_OUTPUT" out)))
               (lambda (r)
                 (let ((result (and (file-readable-p out)
                                    (condition-case nil (harness-json-parse (harness-read-file out)) (error nil)))))
                   (funcall clean)
                   (cond ((eq (plist-get r :exit) 'timeout)
                          (harness-rejected '(harness-error "Historical usage scan timeout")))
                         ((or (not (equal (plist-get r :exit) 0)) (plist-get result :error)
                              (not (plist-member result :coverage)))
                          (harness-rejected '(harness-error "Historical usage scan failure")))
                         (t result))))
               (lambda (_err)
                 (funcall clean)
                 (harness-rejected '(harness-error "Historical usage scan process failure")))))
          (error (funcall clean)
                 (harness-rejected '(harness-error "Historical usage scan process failure")))))
    (error (harness-rejected '(harness-error "Invalid historical usage scan input")))))

(provide 'harness-usage-history-scan)
;;; harness-usage-history-scan.el ends here
