;;; harness-tools-fuzz.el --- Tools that fuzz the harness with AFL++  -*- lexical-binding: t; -*-

;;; Commentary:

;; The tools of the fuzzing plugin (harness-fuzz.el): run an AFL++
;; campaign against the harness's protocol edges, list the targets, and
;; replay an input a report names.  They belong to module tools-fuzz,
;; so only a session whose project names that module in
;; `harness-plugin-modules' sees or can call them.
;;
;; A campaign is safe to run from a session: a target's check runs in
;; an adapter Emacs of its own, never in the harness, the built-in
;; targets are pure parsers and protocol halves that touch no session,
;; file or network, and AFL++ is bounded by executions and by wall
;; clock.  What a target of another project's plugin does is that
;; plugin's business.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-fuzz)

(defun harness-tools-fuzz--number (value default minimum maximum)
  "Return VALUE as a number from MINIMUM to MAXIMUM, or DEFAULT.
A string that is a number is accepted, as a model may send one; a
value that is not a number is DEFAULT.  The clamp is the tool's own
safety rail before the campaign's budget."
  (let* ((number (cond ((numberp value) (float value))
                       ((and (stringp value)
                             (string-match-p
                              "\\`[ \t]*[-+]?[0-9.]+\\(?:e[-+]?[0-9]+\\)?[ \t]*\\'"
                              value))
                        (string-to-number value))
                       (t (float default))))
         (number (if (or (not (numberp number)) (/= number number))
                     (float default)
                   number)))
    (max minimum (min maximum number))))

(defun harness-tools-fuzz--integer (value default minimum maximum)
  "Return VALUE as an integer from MINIMUM to MAXIMUM, or DEFAULT."
  (round (harness-tools-fuzz--number value default minimum maximum)))

(defun harness-tools-fuzz--seed (input)
  "Return INPUT's `:seed' as a positive integer, or nil."
  (let ((seed (plist-get input :seed)))
    (when (or (numberp seed) (and (stringp seed) (string-match-p "\\`[0-9]+\\'" seed)))
      (let ((seed (round (string-to-number (format "%s" seed)))))
        (max 1 seed)))))

(defun harness-tools-fuzz--afl ()
  "Return the afl-fuzz path, or nil when AFL++ is not installed."
  (ignore-errors (harness-fuzz--program harness-fuzz-afl-program
                                        'harness-fuzz-afl-program)))

(harness-define-tool "fuzz_harness"
  :label "Fuzz harness"
  :description
  "Fuzz the harness's protocol boundaries with AFL++ and report crashes. Use target \"all\", or one target named by fuzz_targets. AFL++ mutates each target's seed inputs in an adapter Emacs of its own; a crash is a signal, a broken invariant or a hang, and afl-tmin minimises a sample of them. The result holds each crash's input and the fuzz_replay call that runs it again."
  :kind 'meta
  :timeout 240
  :schema
  '(:type "object"
    :properties (:target (:type "string"
                                :description "A target name, or \"all\". Defaults to \"all\".")
                 :executions (:type "integer"
                                   :description "How many inputs AFL++ tries per target; default 200.")
                 :seconds (:type "number"
                                :description "Wall-clock budget per target; default 5, at most 60.")
                 :seed (:type "integer"
                             :description "AFL++'s mutation seed; the same seed repeats a campaign's choices.")
                 :shrink (:type "boolean"
                               :description "Minimise a crash with afl-tmin before reporting it; default true.")))
  :handler
  (lambda (input _ctx)
    (let* ((targets (or (plist-get input :target) "all"))
           (executions (harness-tools-fuzz--integer
                        (plist-get input :executions) 200 1
                        harness-fuzz-max-executions))
           (seconds (harness-tools-fuzz--number
                     (plist-get input :seconds) 5 1 harness-fuzz-max-seconds))
           (seed (harness-tools-fuzz--seed input))
           (shrink (if (plist-member input :shrink)
                       (harness-json-true-p (plist-get input :shrink))
                     t)))
      (condition-case err
          (let ((report (harness-fuzz-run :targets targets :executions executions
                                          :seconds seconds :seed seed :shrink shrink)))
            (harness-tool-ok (harness-fuzz-describe-report report 10)))
        (error
         (harness-tool-error
          (format "Fuzz campaign failed: %s" (error-message-string err))))))))

(harness-define-tool "fuzz_targets"
  :label "Fuzz targets"
  :description "List the places AFL++ can fuzz, with what each one exercises, its seed inputs, and whether AFL++ is installed."
  :kind 'meta
  :schema '(:type "object" :properties :empty)
  :handler
  (lambda (_input _ctx)
    (let ((targets (harness-fuzz-targets))
          (afl (harness-tools-fuzz--afl)))
      (harness-tool-ok
       (concat
        (if afl
            (format "AFL++: %s (%s)\n" afl
                    (pcase harness-fuzz-afl-mode
                      ('dumb "dumb mode")
                      ('instrumented "coverage-guided")
                      ('qemu "QEMU mode")
                      (_ (format "%s" harness-fuzz-afl-mode))))
          (format "AFL++: not found.  Install afl++ or set `harness-fuzz-afl-program'.\n"))
        (if (null targets)
            "No fuzz targets are registered."
          (mapconcat (lambda (target)
                       (format "- %s: %s (%d seed%s)"
                               (harness-fuzz-target-name target)
                               (harness-fuzz-target-description target)
                               (length (harness-fuzz-target-seeds target))
                               (if (= 1 (length (harness-fuzz-target-seeds target))) "" "s")))
                     targets "\n")))))))

(harness-define-tool "fuzz_replay"
  :label "Fuzz replay"
  :description
  "Run one fuzz input again in an adapter Emacs. Give the target and either the input a report printed or the number of a crash in the last report; a crash, a pass and a hang each come back named."
  :kind 'meta
  :timeout 60
  :schema
  '(:type "object"
    :properties (:target (:type "string" :description "The target to replay.")
                 :input (:type "string"
                               :description "The printed input from a fuzz report, copied exactly.")
                 :crash (:type "integer"
                               :description "The number of a crash in the last report, instead of input."))
    :required ("target"))
  :handler
  (lambda (input _ctx)
    (let ((target (plist-get input :target))
          (text (plist-get input :input))
          (crash (let ((crash (plist-get input :crash)))
                   (when (or (numberp crash)
                             (and (stringp crash)
                                  (string-match-p "\\`[0-9]+\\'" crash)))
                     (round (string-to-number (format "%s" crash)))))))
      (cond
       ((not (and (stringp target) (not (string-blank-p target))))
        (harness-tool-error "A target name is required"))
       ((and (not (stringp text)) (not crash))
        (harness-tool-error "Give :input, or :crash from the last report"))
       ((and crash (<= crash 0))
        (harness-tool-error "Give a positive :crash number"))
       (t
        (condition-case err
            (harness-tool-ok
             (harness-fuzz-describe-replay
              (harness-fuzz-replay (intern target)
                                   :input (and (stringp text) text)
                                   :crash crash)))
          (error
           (harness-tool-error
            (format "Fuzz replay failed: %s" (error-message-string err))))))))))

(harness-define-module 'tools-fuzz
  :doc "Run AFL++ fuzz campaigns on the harness, list their targets and replay a crash."
  :requires '(tools fuzz))

(provide 'harness-tools-fuzz)
;;; harness-tools-fuzz.el ends here
