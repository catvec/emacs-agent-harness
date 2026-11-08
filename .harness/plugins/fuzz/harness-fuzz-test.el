;;; harness-fuzz-test.el --- Tests for the AFL++ fuzzing plugin  -*- lexical-binding: t; -*-

;;; Commentary:

;; The fuzzing plugin (.harness/plugins/fuzz) is an adapter that lets
;; AFL++ fuzz the harness's protocol boundaries.  These tests check the
;; parts a campaign cannot check about itself: that a target's bytes
;; reach the check unchanged, that a broken adapter fails a campaign
;; instead of looking like a clean one, that a crash replays, and that
;; a report says what happened.  A short campaign against the built-in
;; targets runs when AFL++ is installed, and is skipped otherwise.
;; Two tests are the regressions the old generator-based fuzzer found: a
;; malformed CallToolResult from an MCP server, and ACP wire
;; normalisation of an improper list.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-mcp-protocol)
(require 'harness-acp)

(defmacro harness-fuzz-test-with (&rest body)
  "Run BODY with the fuzz module loaded on a fresh bus."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-test-load-module 'fuzz)
     ,@body))

(defun harness-fuzz-test--write-target (name form)
  "Write a target file defining NAME with FORM, and return its path.
FORM is inserted as the body of the top-level definition."
  (let* ((directory (harness-test-temp-dir))
         (file (expand-file-name (format "%s.el" name) directory)))
    (with-temp-file file
      (insert ";;; -*- lexical-binding: t; -*-\n"
              "(harness-fuzz-define-target '" (format "%s" name) "\n"
              "  :description \"A test target.\"\n"
              "  :seeds '(\"ok\")\n"
              "  :check (lambda (bytes)\n"
              form
              "           t))\n"))
    file))

(ert-deftest harness-fuzz-registers-the-built-in-targets ()
  "Every target the plugin ships is registered with a check and seeds."
  (harness-fuzz-test-with
    (let ((names (mapcar #'harness-fuzz-target-name (harness-fuzz-targets))))
      (dolist (name '(mcp-serve mcp-result mcp-line acp-lines acp-params
                      acp-normalise links search-query http-headers provider-events))
        (should (memq name names)))
      (dolist (target (harness-fuzz-targets t))
        (should (functionp (harness-fuzz-target-check target)))
        (should (harness-fuzz-target-seeds target))
        (should (harness-fuzz-target-file target))))
    (harness-fuzz-define-target 'fuzz-test-hidden :hidden t
                                :description "Hidden."
                                :seeds '("x")
                                :check #'identity)
    (unwind-protect
        (progn
          (should-not (memq 'fuzz-test-hidden
                            (mapcar #'harness-fuzz-target-name (harness-fuzz-targets))))
          (should (memq 'fuzz-test-hidden
                        (mapcar #'harness-fuzz-target-name (harness-fuzz-targets t)))))
      (harness-fuzz-remove-target 'fuzz-test-hidden))))

(ert-deftest harness-fuzz-a-target-needs-a-check-and-seeds ()
  "A target without a check, or without a string to start from, is refused."
  (harness-fuzz-test-with
    (should-error (harness-fuzz-define-target 'fuzz-test-invalid :seeds '("x")))
    (should-error (harness-fuzz-define-target 'fuzz-test-invalid
                    :check #'identity :seeds nil))
    (should-error (harness-fuzz-define-target 'fuzz-test-invalid
                    :check #'identity :seeds '(1 2)))
    (should-not (harness-fuzz-target-get 'fuzz-test-invalid))))

(ert-deftest harness-fuzz-the-adapter-runs-a-check-in-another-emacs ()
  "The adapter runs a target file's check on the exact bytes it was given."
  (harness-fuzz-test-with
    (let* ((file (harness-fuzz-test--write-target
                  'fuzz-test-canary
                  "           (when (string-match-p \"boom\" bytes)\n\
           (error \"Canary: boom in %S\" bytes))\n"))
           (directory (file-name-directory file)))
      (load file nil t)
      (unwind-protect
          (let ((target (harness-fuzz-target-get 'fuzz-test-canary)))
            (should (equal file (harness-fuzz-target-file target)))
            (should (eq 'pass (plist-get (harness-fuzz--run-adapter target "ok") :status)))
            (let ((outcome (harness-fuzz--run-adapter target "a boom here")))
              (should (eq 'crash (plist-get outcome :status)))
              (should (string-match-p "Canary" (plist-get outcome :message))))
            ;; The check gets bytes, not decoded characters.
            (let ((file (harness-fuzz-test--write-target
                         'fuzz-test-bytes
                         "           (unless (equal bytes (unibyte-string 0 10 128 255 65))\n\
             (error \"Not the bytes: %S\" bytes))\n")))
              (load file nil t)
              (unwind-protect
                  (should (eq 'pass
                              (plist-get (harness-fuzz--run-adapter
                                          (harness-fuzz-target-get 'fuzz-test-bytes)
                                          (unibyte-string 0 10 128 255 65))
                                         :status)))
                (harness-fuzz-remove-target 'fuzz-test-bytes))))
        (harness-fuzz-remove-target 'fuzz-test-canary))
      (ignore directory))))

(ert-deftest harness-fuzz-a-broken-adapter-fails-the-campaign ()
  "A target file that cannot load is an error, not a campaign with no crashes."
  (harness-fuzz-test-with
    (let* ((directory (harness-test-temp-dir))
           (bogus (expand-file-name "fuzz-test-bogus.el" directory))
           (work (make-temp-file "harness-fuzz-test-" t)))
      (with-temp-file bogus
        (insert ";;; -*- lexical-binding: t; -*-\n(error \"The target file is broken\")\n"))
      (harness-fuzz-define-target 'fuzz-test-bogus
                                  :description "A target the adapter cannot load."
                                  :seeds '("x")
                                  :check #'identity
                                  :file bogus)
      (unwind-protect
          (progn
            (should-error (harness-fuzz--probe-targets
                           (list (harness-fuzz-target-get 'fuzz-test-bogus)) work))
            ;; A target the adapter cannot even name is the same failure.
            (harness-fuzz-define-target 'fuzz-test-nowhere
                                        :description "A target with no file."
                                        :seeds '("x")
                                        :check #'identity
                                        :file nil)
            (let ((error (should-error
                          (harness-fuzz--probe-targets
                           (list (harness-fuzz-target-get 'fuzz-test-nowhere)) work))))
              (should (string-match-p "cannot run" (error-message-string error)))))
        (harness-fuzz-remove-target 'fuzz-test-bogus)
        (harness-fuzz-remove-target 'fuzz-test-nowhere)
        (delete-directory work t)))))

(ert-deftest harness-fuzz-the-adapter-command ()
  "The adapter is a batch Emacs with this load path and the target's file."
  (harness-fuzz-test-with
    (let* ((target (harness-fuzz-target-get 'links))
           (command (harness-fuzz--adapter-command target "@@")))
      (should (equal "--batch" (nth 1 command)))
      (should (equal "-q" (nth 2 command)))
      (should (member "-L" command))
      (should (member (expand-file-name "harness-fuzz" harness-fuzz-directory) command))
      (should (string-match-p "(harness-fuzz--adapter-main 'links \"@@\")"
                              (car (last command))))
      (should (string-match-p "--eval" (nth (- (length command) 2) command))))))

(ert-deftest harness-fuzz-the-afl-command-line ()
  "Dumb, instrumented and QEMU modes pass what AFL++ expects."
  (let* ((target (harness-fuzz-target-get 'links))
         (command (lambda (mode)
                    (let ((harness-fuzz-afl-mode mode)
                          (harness-fuzz-afl-arguments '("-x" "/tmp/tokens.dict")))
                      (harness-fuzz--afl-command "afl-fuzz" target "seeds" "out"
                                                 7 30 5)))))
    (let ((dumb (funcall command 'dumb)))
      (should (member "-n" dumb))
      (should (equal "30" (nth (1+ (cl-position "-E" dumb :test #'equal)) dumb)))
      (should (equal "5" (nth (1+ (cl-position "-V" dumb :test #'equal)) dumb)))
      (should (equal "5000" (nth (1+ (cl-position "-t" dumb :test #'equal)) dumb)))
      (should (equal "7" (nth (1+ (cl-position "-s" dumb :test #'equal)) dumb)))
      (should (member "-x" dumb))
      (should (member "--" dumb))
      (should (string-match-p "harness-fuzz--adapter-main 'links \"@@\""
                              (car (last dumb)))))
    (should-not (member "-n" (funcall command 'instrumented)))
    (should (member "-Q" (funcall command 'qemu)))
    (should-not (member "-n" (funcall command 'qemu)))
    (should (member (format "AFL_CRASH_EXITCODE=%d" harness-fuzz-crash-exit-code)
                    (harness-fuzz--afl-environment)))
    (should (member "AFL_CRASH_TRACES=1" (harness-fuzz--afl-environment)))
    (should (member "AFL_NO_FORKSRV=1" (harness-fuzz--tmin-environment)))))

(ert-deftest harness-fuzz-a-printed-input-round-trips-bytes ()
  "A report's printed input reads back as the same bytes, and runs nothing."
  (let* ((bytes (unibyte-string 0 10 128 255 65 39 92))
         (printed (car (harness-fuzz--print-input bytes))))
    (should (string-match-p "\\`[ -~]+\\'" printed))
    (should (equal bytes (harness-fuzz--read-input printed)))
    (should (equal (unibyte-string 0 10 128 255 65 39 92)
                   (harness-fuzz--read-input "\"\\000\\012\\200\\377A'\\\\\""))))
  (should (equal (encode-coding-string "λ and 😀" 'utf-8)
                 (harness-fuzz--read-input "\"λ and 😀\"")))
  (should-error (harness-fuzz--read-input "#.(+ 1 2)"))
  (should-error (harness-fuzz--read-input "42"))
  (should-error (harness-fuzz--read-input "(\"a\" . \"b\")")))

(ert-deftest harness-fuzz-a-reported-crash-replays ()
  "A crash of the last report runs again by number, and by printed input."
  (harness-fuzz-test-with
    (let ((file (harness-fuzz-test--write-target
                 'fuzz-test-canary
                 "           (when (string-match-p \"boom\" bytes)\n\
           (error \"Canary: boom in %S\" bytes))\n")))
      (load file nil t)
      (unwind-protect
          (let ((harness-fuzz--last-report
                 (list :run "test" :seed 1 :mode 'dumb
                       :targets '(fuzz-test-canary) :executions 1
                       :crashes (list (list :target 'fuzz-test-canary :kind 'crash
                                            :input "boom" :message "Canary"
                                            :file "seed" :shrunk nil)))))
            (let ((result (harness-fuzz-replay 'fuzz-test-canary :crash 1)))
              (should (plist-get result :crash))
              (should (string-match-p "Canary" (plist-get result :message)))
              (should (equal "boom" (plist-get result :input))))
            (should (plist-get (harness-fuzz-replay 'fuzz-test-canary
                                                    :input "\"boom\"")
                               :crash))
            (should-not (plist-get (harness-fuzz-replay 'fuzz-test-canary
                                                        :input "\"ok\"")
                                   :crash))
            (should-error (harness-fuzz-replay 'fuzz-test-canary :crash 2))
            (should-error (harness-fuzz-replay 'no-such-target :input "\"x\"")))
        (harness-fuzz-remove-target 'fuzz-test-canary)))))

(ert-deftest harness-fuzz-reads-afl-crash-files ()
  "A crash file, its trace and its signal become a finding."
  (let* ((directory (harness-test-temp-dir))
         (crashes (expand-file-name "crashes" directory))
         (first (expand-file-name "id:000000,sig:00,src:000000,time:8,execs:7,op:havoc,rep:2"
                                  crashes))
         (second (expand-file-name "id:000001,sig:11,src:000000,time:9,execs:8,op:havoc,rep:1"
                                   crashes)))
    (make-directory crashes t)
    (harness-fuzz--write-bytes first (unibyte-string 104 105 0 255))
    (harness-fuzz--write-bytes second "x")
    (with-temp-file (concat first ".txt")
      (insert "=== AFL++ crash trace ===\ncrash file : x\nsignal     : 0\n"
              "=========================\n\nharness-fuzz: links: the invariant broke\n"))
    (make-directory (expand-file-name "hangs" directory) t)
    (harness-fuzz--write-bytes
     (expand-file-name "id:000000,src:000000,time:9,execs:8,op:havoc,rep:1"
                       (expand-file-name "hangs" directory))
     "slow")
    (let ((findings (harness-fuzz--findings (harness-fuzz-target-get 'links) directory)))
      (should (= 3 (length findings)))
      (should (eq 'crash (plist-get (car findings) :kind)))
      (should (equal (unibyte-string 104 105 0 255) (plist-get (car findings) :input)))
      (should (equal "links: the invariant broke" (plist-get (car findings) :message)))
      (should (= 11 (plist-get (nth 1 findings) :signal)))
      (should-not (plist-get (nth 1 findings) :exit))
      (should (eq 'hang (plist-get (nth 2 findings) :kind)))
      (should-not (plist-get (nth 2 findings) :exit)))))

(ert-deftest harness-fuzz-reads-afl-statistics ()
  "AFL++'s plot data gives a campaign its execution count and rate."
  (let* ((directory (harness-test-temp-dir))
         (file (expand-file-name "plot_data" directory)))
    (with-temp-file file
      (insert "# relative_time, cycles_done, cur_item, corpus_count, pending_total, pending_favs, map_size, saved_crashes, saved_hangs, max_depth, execs_per_sec, total_execs, edges_found, total_crashes, servers_count\n")
      (insert "5, 0, 0, 2, 0, 0, 0.00%, 2, 0, 1, 12.20, 41, 0, 2, 0\n"))
    (let ((stats (harness-fuzz--plot-stats directory)))
      (should (= 41 (plist-get stats :executions)))
      (should (= 12.2 (plist-get stats :execs-per-sec)))
      (should (= 2 (plist-get stats :saved-crashes))))))

(ert-deftest harness-fuzz-describes-a-report ()
  "A report names the mode, each target, and each crash's replay call."
  (harness-fuzz-test-with
    (let ((report (list :run "demo" :seed 7 :mode 'dumb
                        :targets '(links mcp-serve) :executions 120
                        :elapsed 2.5 :stopped 'executions
                        :crashes (list (list :target 'links :kind 'crash
                                             :signal nil :exit 42
                                             :message "links: boom"
                                             :input "harness:boom" :shrunk t
                                             :file "id:1"))
                        :by-target '((links :executions 60 :execs-per-sec 4.0
                                            :crashes 1 :hangs 0)
                                     (mcp-serve :executions 60 :execs-per-sec 4.0
                                                :crashes 0 :hangs 0)))))
      (let ((text (harness-fuzz-describe-report report 5)))
        (should (string-match-p (regexp-quote "AFL++ dumb mode") text))
        (should (string-match-p "1 crash" text))
        (should (string-match-p "links: boom" text))
        (should (string-match-p "minimised" text))
        (should (string-match-p "fuzz_replay target: links crash: 1" text))))
    (should (string-match-p "No crashes"
                            (harness-fuzz-describe-report
                             (list :run "empty" :seed 1 :mode 'dumb :targets '(links)
                                   :executions 3 :elapsed 0.1 :stopped 'executions
                                   :crashes nil
                                   :by-target '((links :executions 3 :execs-per-sec 1.0
                                                       :crashes 0 :hangs 0))))))))

(ert-deftest harness-fuzz-the-built-in-targets-survive-a-campaign ()
  "No built-in target finds a crash in the harness as it stands."
  (skip-unless (executable-find "afl-fuzz"))
  (harness-fuzz-test-with
    (let* ((harness-fuzz-parallel-targets 10)
           (report (harness-fuzz-run :targets 'all :executions 40 :seconds 3
                                     :seed 42 :shrink nil)))
      (should-not (plist-get report :crashes))
      (should (>= (plist-get report :executions) 10))
      (should (equal (length (harness-fuzz-targets))
                     (length (plist-get report :targets))))
      (should (string-match-p "No crashes" (harness-fuzz-describe-report report))))))

(ert-deftest harness-fuzz-finds-and-minimises-a-crash ()
  "AFL++ finds a crash, afl-tmin minimises it, and it replays."
  (skip-unless (and (executable-find "afl-fuzz") (executable-find "afl-tmin")))
  (harness-fuzz-test-with
    (let ((file (harness-fuzz-test--write-target
                 'fuzz-test-broken
                 "           (unless (equal bytes \"hello\")\n\
             (error \"The broken target got %S\" bytes))\n")))
      (load file nil t)
      (unwind-protect
          (let* ((report (harness-fuzz-run :targets 'fuzz-test-broken
                                           :executions 25 :seconds 5
                                           :seed 3 :shrink t))
                 (crashes (plist-get report :crashes))
                 (shrunk (cl-find-if (lambda (crash) (plist-get crash :shrunk))
                                     crashes)))
            (should crashes)
            (should shrunk)
            (should (< (length (plist-get shrunk :input)) (length "hello")))
            (should (eq 'crash
                        (plist-get (harness-fuzz-replay
                                    'fuzz-test-broken
                                    :crash (1+ (cl-position shrunk crashes)))
                                   :kind))))
        (harness-fuzz-remove-target 'fuzz-test-broken)))))

(ert-deftest harness-fuzz-mcp-results-of-every-shape-are-read ()
  "A malformed CallToolResult becomes a tool result, never a signal.
A fuzzer found this: an MCP server is untrusted, so its `content' may
be a string, a number or `:false', and its `_meta' may be none of the
shapes the harness hopes for."
  (harness-fuzz-test-with
    (dolist (result '((:content "x")
                      (:content 42)
                      (:content :false)
                      (:content nil)
                      (:content (:type "text" :text "ok")
                                (:type "image" :data "x"))
                      (:content "x" :isError 1)
                      (:content "x" :_meta (:harness/result (:false nil "bad")))
                      (:content "x" :_meta :not-a-plist)
                      (:content "x" :structuredContent (:false nil "x"))
                      (:content 42 :_meta (:harness/result (:id 7)))))
      (let ((tool-result (harness-mcp-call-result-to-tool-result result)))
        (should (stringp (plist-get tool-result :content)))
        (should (memq (plist-get tool-result :is-error) '(nil t)))
        (should (harness-mcp-tool-result-to-call-result tool-result)))))
  ;; A handler's odd return value is a tool failure or text, never a
  ;; signal from the server's answer path.
  (let* ((server (harness-mcp-make-server
                  :name "test"
                  :tools (list (harness-mcp-make-tool
                                :name "odd"
                                :handler (lambda (_arguments _context)
                                           (cons :content "dotted"))))))
         (response (harness-mcp-serve
                    server '(:jsonrpc "2.0" :id 1 :method "tools/call"
                                       :params (:name "odd")))))
    (should (equal 1 (plist-get response :id)))
    (should (plist-get response :result))))

(ert-deftest harness-fuzz-acp-normalisation-tolerates-improper-values ()
  "ACP wire normalisation and enum interning survive a dotted list.
A fuzzer found this while normalising values code, not JSON, can hand
the client side."
  (should (equal '(:a 1) (harness-acp--normalise '(:a . 1))))
  (should (equal '(:a 1 2) (harness-acp--normalise '(:a 1 . 2))))
  (should (equal '("a" "b") (harness-acp--normalise '(a . b))))
  (should (equal '(:a 1) (harness-acp--intern-enums '(:a . 1))))
  (should (equal '(:a 1 2) (harness-acp--intern-enums '(:a 1 . 2))))
  (should (equal '(a b) (harness-acp--intern-enums '(a . b)))))

(ert-deftest harness-fuzz-tools-are-only-for-sessions-that-name-the-module ()
  "The fuzz tools are plugin tools: only a session naming tools-fuzz gets them."
  (harness-fuzz-test-with
    (harness-test-load-module 'tools)
    (harness-test-load-module 'session)
    (harness-test-load-module 'plugins)
    (harness-test-load-module 'tools-fuzz)
    (let ((tool (harness-tool-get "fuzz_harness"))
          (session (list :id "fuzz-test-session")))
      (should (harness-module-plugin-p 'tools-fuzz))
      (should (harness-tools--in-scope-p tool session '(tools-fuzz)))
      (should-not (harness-tools--in-scope-p tool session '(other)))
      (should-not (harness-tools--in-scope-p tool session nil)))))

(ert-deftest harness-fuzz-plugin-loads-through-directory-locals ()
  "The plugin entry loads the engine, starts module tools-fuzz, and scopes its tools."
  (harness-test-with-temp-state
    ;; Other tests may have loaded the plugin's files already; a fresh
    ;; bus needs their module definitions to run again.
    (dolist (feature '(harness-fuzz-plugin harness-tools-fuzz harness-fuzz))
      (setq features (delq feature features)))
    (harness-test-reset-bus)
    (dolist (m '(store project config tools session plugins))
      (harness-test-load-module m))
    (clrhash harness-sessions)
    (clrhash harness-plugins--applied)
    (let* ((dir (harness-test-temp-dir))
           (other (harness-test-temp-dir))
           (plugin (expand-file-name ".harness/plugins/fuzz/harness-fuzz-plugin"
                                     harness-test-root))
           (entries `((eval . (require 'harness-fuzz-plugin ,plugin))
                      (harness-plugin-modules . (tools-fuzz)))))
      (with-temp-file (expand-file-name ".dir-locals.el" dir)
        (let ((print-length nil) (print-level nil))
          (prin1 (list (cons nil entries)) (current-buffer))))
      (setq dir-locals-directory-cache nil)
      (let ((safe-local-variable-values entries)
            (enable-local-variables t)
            (enable-local-eval 'maybe)
            (harness-plugin-modules nil))
        (let* ((session (plist-get (harness-call 'session/create :cwd dir :project dir) :id))
               (other-session (plist-get (harness-call 'session/create
                                                       :cwd other :project other) :id))
               (tool-names (lambda (id)
                             (mapcar (lambda (spec) (plist-get spec :name))
                                     (harness-call 'tools/list id)))))
          (should (featurep 'harness-fuzz-plugin))
          (should (harness-module-ready-p 'tools-fuzz))
          (should (equal '(tools-fuzz) (harness-call 'plugins/of-session session)))
          (should (member "fuzz_harness" (funcall tool-names session)))
          (should-not (member "fuzz_harness" (funcall tool-names other-session))))))))

(provide 'harness-fuzz-test)
;;; harness-fuzz-test.el ends here
