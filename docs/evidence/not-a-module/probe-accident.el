;;; A live harness with every module enabled, as a dev daemon or a user's config.
(setq harness-state-directory (file-name-as-directory (getenv "PROBE_STATE"))
      harness-enabled-modules t
      harness-off-by-default-modules nil
      harness-policy-file nil
      harness-notifications-providers nil
      harness-process nil
      harness-auto-reload-mode nil)
(condition-case err (harness-start) (error (princ (format "start error: %S\n" err))))
(princ (format "RESULT state-directory-after-start=%S\n" harness-state-directory))
(princ (format "RESULT test-helpers-loaded=%S\n" (featurep 'harness-test-helpers)))
(princ (format "RESULT tmp-root=%S\n" (and (boundp 'harness-session--tmp-root) harness-session--tmp-root)))
(princ (format "RESULT store-in-repository=%S\n" (and (boundp 'harness-tasks-store-in-repository) harness-tasks-store-in-repository)))
