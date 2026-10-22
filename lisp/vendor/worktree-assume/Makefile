# Run worktree-assume's tests, and check that it compiles cleanly.
#
#   make test      run the tests (ERT), with nothing but this directory
#   make compile   byte-compile, warnings as errors
#   make clean     remove compiled files
#
# EMACS names the Emacs to use: make test EMACS=emacs-29.1

EMACS ?= emacs

.PHONY: all test compile clean

all: compile test

test:
	$(EMACS) -Q --batch -L . -l worktree-assume-test.el -f ert-run-tests-batch-and-exit

# The compiled file goes to a temporary directory, never next to the
# source: a stale .elc on the load path would shadow worktree-assume.el.
compile:
	@dir=$$(mktemp -d) && \
	$(EMACS) -Q --batch -L . \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  --eval "(setq byte-compile-dest-file-function (lambda (_) \"$$dir/worktree-assume.elc\"))" \
	  --eval "(unless (byte-compile-file \"worktree-assume.el\") (kill-emacs 1))"; \
	status=$$?; rm -rf "$$dir"; exit $$status

clean:
	rm -f *.elc
