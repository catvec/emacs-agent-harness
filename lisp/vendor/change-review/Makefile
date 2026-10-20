# Run change-review's tests, and check that it compiles cleanly.
#
#   make test      run the tests (ERT), with nothing but this directory
#   make compile   byte-compile, warnings as errors
#   make clean     remove compiled files
#
# EMACS names the Emacs to use: make test EMACS=emacs-29.1

EMACS ?= emacs
LIBRARIES = change-review change-review-diff change-review-mail change-review-ui
TESTS = $(wildcard *-test.el)

.PHONY: all test compile clean

all: compile test

test:
	@for test in $(TESTS); do \
	  $(EMACS) -Q --batch -L . -l $$test -f ert-run-tests-batch-and-exit || exit 1; \
	done

# The compiled files go to a temporary directory, never next to the
# source: a stale .elc on the load path would shadow the source.
compile:
	@dir=$$(mktemp -d) && status=0 && \
	for library in $(LIBRARIES); do \
	  [ -f $$library.el ] || continue; \
	  $(EMACS) -Q --batch -L . \
	    --eval "(setq byte-compile-error-on-warn t)" \
	    --eval "(setq byte-compile-dest-file-function (lambda (_) \"$$dir/$$library.elc\"))" \
	    --eval "(unless (byte-compile-file \"$$library.el\") (kill-emacs 1))" || status=1; \
	done; rm -rf "$$dir"; exit $$status

clean:
	rm -f *.elc
