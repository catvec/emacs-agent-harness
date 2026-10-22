;;; harness-media.el --- Regenerate the README screenshots  -*- lexical-binding: t; -*-

;;; Commentary:

;; `scripts/media.sh' loads this file into a fresh `emacs -Q' on a
;; graphical display and calls `harness-media-main', which builds a
;; small world, photographs the harness's views in it and exits.
;;
;; The world: a demo project, ~/src/acme-api, under the HOME that
;; media.sh makes for the run, so every path in the pictures is short
;; and no real one shows; the harness of this checkout, running in this
;; Emacs with its state under that HOME; sessions and tasks in every
;; state, a month of usage and a few budgets.
;;
;; The agents are scripted.  Stand-ins for the Claude Code provider (on
;; a Max plan) and for OpenRouter (billed per token) replay a script
;; picked by the prompt, and the tools they call are the real ones, run
;; on the demo project: every tool output in the pictures is genuine.
;; The auto-mode judge, session titles and backlog write-ups get
;; scripted answers too.  Nothing talks to a network.
;;
;; Each shot lays the frame out, waits for the views to settle and
;; writes NAME.png with `x-export-frames' into HARNESS_MEDIA_OUT
;; (docs/media by default), plus NAME.txt with the text of every window
;; into HARNESS_MEDIA_DUMPS when that is set, to check a picture without
;; looking at it.  HARNESS_MEDIA_SHOTS limits the run to some shots.
;;
;; docs/screenshots.md walks through it all, with recipes for adding a
;; picture of a new view, a conversation or a task.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'text-property-search)

;;;; Settings of the run

(defvar harness-media-root
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name))))
  "The checkout whose harness is photographed.")

(defvar harness-media-output nil "Directory the pictures are written to.")
(defvar harness-media-dumps nil "Directory for the text of every shot, or nil.")
(defvar harness-media-only nil "Names of the shots to take; nil takes them all.")

(defconst harness-media-theme 'modus-vivendi-tinted "Theme of the pictures.")
(defconst harness-media-font "Hack" "Font family of the pictures, when it is installed.")
(defconst harness-media-font-height 120 "Height of the default face, in 1/10 pt.")
(defconst harness-media-columns 160 "Frame width in columns.")
(defconst harness-media-hero-columns 180
  "Frame width of the first picture, in columns.
It shows the board and a session side by side, in the fullscreen
layout: half the frame keeps the board's cards whole.")
(defconst harness-media-lines 54 "Frame height in lines, unless a shot asks for another.")
(defconst harness-media-delay 0.02 "Seconds between the events of a scripted turn.")

(defconst harness-media-identity
  '(("GIT_AUTHOR_NAME" . "Sam Rivera") ("GIT_AUTHOR_EMAIL" . "sam@acme.example")
    ("GIT_COMMITTER_NAME" . "Sam Rivera") ("GIT_COMMITTER_EMAIL" . "sam@acme.example"))
  "Who commits in the demo project, tasks and merges included.")

(defvar harness-media-project nil "Root of the demo project.")
(defvar harness-media-failures nil "Shots that failed, as (NAME . ERROR).")
(defvar harness-media--world nil "Plist naming the sessions and tasks of the world.")
(defvar harness-media--insights-summary)

;; Harness variables set or read here.
(defvar harness-state-directory)
(defvar harness-process)
(defvar harness-disabled-modules)
(defvar harness-enabled-modules)
(defvar harness-ui-positions)
(defvar harness-ui-default-position)
(defvar harness-ui--position-buffers)
(defvar harness-ui--fullscreen-layouts)
(defvar harness-ui-tasks--target)
(defvar harness-ui-tasks-search--state)
(defvar harness-quick-search--state)
(defvar harness-chat--blocks)
(defvar harness-chat--loading)
(defvar harness-chat--order)
(defvar harness-sessions)
(defvar harness-ui-tasks--tasks)
(defvar harness-cache-ttl)
(defvar harness-supervisor)
(defvar harness-supervisor-tasks)
(defvar harness-recap--sessions)
(defvar harness-merge--locks)
(defvar harness-ui-access--describe)
(defvar harness-ui-access--judgements)

(declare-function harness-start "harness")
(declare-function harness-call "harness-core")
(declare-function harness-await "harness-core")
(declare-function harness-as-promise "harness-core")
(declare-function harness-resolved "harness-core")
(declare-function harness-define-provider "harness-provider")
(declare-function harness-ui-session "harness-ui")
(declare-function harness-ui-refresh-sessions "harness-ui")
(declare-function harness-ui-refresh-models "harness-ui")
(declare-function harness-ui-refresh-quotas "harness-ui")
(declare-function harness-ui-display-session "harness-ui")
(declare-function harness-menu "harness-ui")
(declare-function harness-chat-toggle-block "harness-ui-chat")
(declare-function harness-chat-scroll-to-bottom "harness-ui-chat")
(declare-function harness-access "harness-ui-access")
(declare-function harness-ui-access--find-anchor "harness-ui-access")
(declare-function harness-tools-session-note "harness-tools" (session-id &optional options))
(declare-function harness-tools-session-activity "harness-tools" (session-id))
(declare-function harness-chat-block-node "harness-ui-chat")
(declare-function harness-chat-block-collapsed "harness-ui-chat")
(declare-function harness-compose-set "harness-ui-compose")
(declare-function harness-compose-text "harness-ui-compose")
(declare-function harness-compose-repad "harness-ui-compose")
(defvar harness-compose-start)
(defvar harness-compose-end)
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks-requests "harness-ui-tasks")
(declare-function harness-ui-tasks-open "harness-ui-tasks")
(declare-function harness-ui-tasks-reply "harness-ui-tasks")
(declare-function harness-ui-tasks-compose-reset "harness-ui-tasks")
(declare-function harness-ui-tasks--find "harness-ui-tasks")
(declare-function harness-ui-tasks-search-clear "harness-ui-tasks-search")
(declare-function harness-ui-tasks--searching-p "harness-ui-tasks")
(declare-function harness-ui-tasks-search "harness-ui-tasks")
(declare-function harness-ui-tasks-compose-quit "harness-ui-tasks")
(declare-function harness-quick-search "harness-ui-quick-search")
(declare-function harness-quick-search-box-submit "harness-ui-quick-search")
(declare-function harness-ui-popout-close "harness-ui-popout")
(declare-function harness-ui-report-popout "harness-ui-report")
(declare-function harness-ui-popout-buffer "harness-ui-popout")
(declare-function harness-sessions "harness-ui-sessions")
(declare-function harness-ui-sessions-requests "harness-ui-sessions")
(declare-function harness-tree "harness-ui-tree")
(declare-function harness-usage "harness-ui-usage")
(declare-function harness-ui-usage-set-period "harness-ui-usage")
(declare-function harness-ui-usage-set-group "harness-ui-usage")
(declare-function harness-ui-usage-toggle-worktrees "harness-ui-usage")
(defvar harness-ui-usage--unfolded)
(declare-function harness-insights "harness-ui-insights")
(declare-function harness-insights--permissions-name "harness-insights")
(defvar harness-ui-insights--buffer-name)
(defvar harness-ui-insights--data)
(defvar harness-ui-insights--loading)
(defvar harness-ui-insights--writing)
(declare-function harness-worktrees "harness-ui-worktree")
(declare-function harness-settings "harness-ui-config")
(declare-function harness-slots "harness-ui-slots" (&optional dir))
(defvar harness-ui-slots--data)
(defvar harness-tasks-max-running)
(declare-function harness-tasks--set "harness-tasks")
(declare-function harness-merge--key "harness-merge")
(defvar harness-merge--locks)
(declare-function harness-ui-cowboy-waiting-p "harness-ui-cowboy")
(declare-function harness-sender-session "harness-util")
(declare-function harness-json-array "harness-util")
(declare-function harness-json-encode-text "harness-util")
(declare-function transient-quit-all "transient")

;;;; Small helpers

(defun harness-media--log (format-string &rest args)
  "Print FORMAT-STRING with ARGS on standard error."
  (princ (concat "media: " (apply #'format format-string args) "\n") #'external-debugging-output))

(defun harness-media--wait (predicate &optional timeout what)
  "Run the event loop until PREDICATE returns non-nil, and return that.
Signal an error naming WHAT after TIMEOUT seconds (default 30)."
  (let ((deadline (+ (float-time) (or timeout 30))) value)
    (while (and (not (setq value (funcall predicate))) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sit-for 0.02))
    (or value (error "Timed out waiting for %s" (or what "a condition")))))

(defun harness-media--settle (&optional seconds)
  "Let timers, processes and redisplay run for SECONDS (default 0.5)."
  (let ((deadline (+ (float-time) (or seconds 0.5))))
    (while (< (float-time) deadline)
      (accept-process-output nil 0.02)
      (sit-for 0.02))))

(defun harness-media--ago (minutes)
  "Return the float time MINUTES ago."
  (- (float-time) (* 60 minutes)))

(defun harness-media--path (file)
  "Return FILE in the demo project."
  (expand-file-name file harness-media-project))

(defun harness-media--write (file content)
  "Write CONTENT to FILE in the demo project."
  (let ((path (harness-media--path file)))
    (make-directory (file-name-directory path) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region content nil path nil 'silent))))

(defun harness-media--git (&rest args)
  "Run git with ARGS in the demo project; return its output or signal."
  (let ((default-directory harness-media-project))
    (with-temp-buffer
      (let ((status (apply #'call-process "git" nil t nil args)))
        (unless (eql status 0)
          (error "Git %s failed: %s" (string-join args " ") (buffer-string)))
        (buffer-string)))))

(defun harness-media--commit (message days-ago)
  "Commit everything in the demo project as MESSAGE, dated DAYS-AGO days back."
  (let* ((date (format-time-string "%Y-%m-%dT%H:%M:%S" (- (float-time) (* days-ago 86400))))
         (process-environment (append (list (concat "GIT_AUTHOR_DATE=" date)
                                            (concat "GIT_COMMITTER_DATE=" date))
                                      process-environment)))
    (harness-media--git "add" "-A")
    (harness-media--git "-c" "commit.gpgsign=false" "commit" "-q" "--no-gpg-sign" "-m" message)))

;;;; The demo project

(defconst harness-media--readme "# acme-api

The orders API behind the Acme storefront: a small WSGI application with
API key authentication, orders, a product catalogue and webhooks.

    python3 -m unittest    # run the tests
")

(defconst harness-media--pyproject "[project]
name = \"acme-api\"
version = \"0.4.0\"
description = \"Orders API behind the Acme storefront\"
requires-python = \">=3.11\"
dependencies = []
")

(defconst harness-media--settings-v1 "\"\"\"Settings, read from the environment.\"\"\"

import os

API_KEYS = {key for key in os.environ.get(\"ACME_API_KEYS\", \"dev-key\").split(\",\") if key}
DATABASE_URL = os.environ.get(\"ACME_DATABASE_URL\", \"sqlite:///acme.db\")
")

(defconst harness-media--settings-v2 (concat harness-media--settings-v1 "WEBHOOK_URLS = [url for url in os.environ.get(\"ACME_WEBHOOK_URLS\", \"\").split(\",\") if url]
"))

(defconst harness-media--auth "\"\"\"API key authentication.\"\"\"

from acme import settings


def authenticate(environ):
    \"\"\"Return the request's API key when it is valid, else None.\"\"\"
    header = environ.get(\"HTTP_AUTHORIZATION\", \"\")
    scheme, _, key = header.partition(\" \")
    if scheme.lower() != \"bearer\" or key not in settings.API_KEYS:
        return None
    return key
")

(defconst harness-media--orders-v1 "\"\"\"Order handlers.\"\"\"

import json

ORDERS = []


def list_orders(environ):
    return \"200 OK\", {\"orders\": ORDERS}


def create_order(environ):
    size = int(environ.get(\"CONTENT_LENGTH\") or 0)
    order = json.loads(environ[\"wsgi.input\"].read(size) or b\"{}\")
    order[\"id\"] = len(ORDERS) + 1
    ORDERS.append(order)
    return \"201 Created\", order
")

(defconst harness-media--orders-v2 "\"\"\"Order handlers.\"\"\"

import json

from acme import webhooks

ORDERS = []


def list_orders(environ):
    return \"200 OK\", {\"orders\": ORDERS}


def create_order(environ):
    size = int(environ.get(\"CONTENT_LENGTH\") or 0)
    order = json.loads(environ[\"wsgi.input\"].read(size) or b\"{}\")
    order[\"id\"] = len(ORDERS) + 1
    ORDERS.append(order)
    webhooks.notify(order)
    return \"201 Created\", order
")

(defconst harness-media--app-v1 "\"\"\"The WSGI application: routing, authentication, JSON responses.\"\"\"

import json

from acme import orders
from acme.auth import authenticate

ROUTES = {
    (\"GET\", \"/orders\"): orders.list_orders,
    (\"POST\", \"/orders\"): orders.create_order,
}


def respond(start_response, status, body, headers=()):
    payload = json.dumps(body).encode()
    start_response(status, [(\"Content-Type\", \"application/json\"), *headers])
    return [payload]


def application(environ, start_response):
    key = authenticate(environ)
    if key is None:
        return respond(start_response, \"401 Unauthorized\",
                       {\"error\": \"missing or invalid API key\"})
    handler = ROUTES.get((environ[\"REQUEST_METHOD\"], environ[\"PATH_INFO\"]))
    if handler is None:
        return respond(start_response, \"404 Not Found\",
                       {\"error\": \"no such route\"})
    status, body = handler(environ)
    return respond(start_response, status, body)
")

(defconst harness-media--app-v2
  (replace-regexp-in-string
   "from acme import orders\n" "from acme import orders, products\n"
   (replace-regexp-in-string
    "    (\"POST\", \"/orders\"): orders.create_order,\n"
    "    (\"POST\", \"/orders\"): orders.create_order,\n    (\"GET\", \"/products\"): products.list_products,\n"
    harness-media--app-v1 t t)
   t t))

(defconst harness-media--db "\"\"\"A thin wrapper around sqlite3.\"\"\"

import sqlite3

from acme import settings


def connect():
    connection = sqlite3.connect(settings.DATABASE_URL.removeprefix(\"sqlite:///\"))
    connection.row_factory = sqlite3.Row
    return connection


def query(sql, *params):
    with connect() as connection:
        return connection.execute(sql, params).fetchall()
")

(defconst harness-media--products "\"\"\"The product catalogue.\"\"\"

from acme import db


def list_products(environ):
    rows = db.query(\"SELECT id, name, price_cents FROM products ORDER BY name\")
    return \"200 OK\", {\"products\": [dict(row) for row in rows]}
")

(defconst harness-media--webhooks "\"\"\"Tell subscribers about new orders.\"\"\"

import json
import urllib.request

from acme import settings


def notify(order, timeout=5):
    \"\"\"POST ORDER to every subscriber; return the URLs that failed.\"\"\"
    failed = []
    for url in settings.WEBHOOK_URLS:
        request = urllib.request.Request(
            url, data=json.dumps(order).encode(), method=\"POST\",
            headers={\"Content-Type\": \"application/json\"})
        try:
            with urllib.request.urlopen(request, timeout=timeout):
                pass
        except OSError:
            failed.append(url)
    return failed
")

(defconst harness-media--test-app "import io
import json
import unittest
from wsgiref.util import setup_testing_defaults

from acme import orders
from acme.app import application


def call(method=\"GET\", path=\"/orders\", key=\"dev-key\", body=None):
    environ = {}
    setup_testing_defaults(environ)
    data = b\"\" if body is None else json.dumps(body).encode()
    environ.update(REQUEST_METHOD=method, PATH_INFO=path, CONTENT_LENGTH=str(len(data)),
                   HTTP_AUTHORIZATION=f\"Bearer {key}\" if key else \"\")
    environ[\"wsgi.input\"] = io.BytesIO(data)
    response = {}

    def start_response(status, headers):
        response.update(status=status, headers=dict(headers))

    payload = json.loads(b\"\".join(application(environ, start_response)))
    return response[\"status\"], response[\"headers\"], payload


class AppTest(unittest.TestCase):
    def setUp(self):
        orders.ORDERS.clear()

    def test_lists_orders(self):
        status, _, body = call()
        self.assertEqual(status, \"200 OK\")
        self.assertEqual(body, {\"orders\": []})

    def test_creates_an_order(self):
        status, _, body = call(\"POST\", body={\"sku\": \"TEE-M\", \"quantity\": 2})
        self.assertEqual(status, \"201 Created\")
        self.assertEqual(body[\"id\"], 1)

    def test_rejects_a_missing_key(self):
        self.assertEqual(call(key=None)[0], \"401 Unauthorized\")

    def test_unknown_route(self):
        self.assertEqual(call(path=\"/nope\")[0], \"404 Not Found\")
")

(defconst harness-media--test-auth "import unittest

from acme.auth import authenticate


class AuthenticateTest(unittest.TestCase):
    def test_accepts_a_known_key(self):
        self.assertEqual(authenticate({\"HTTP_AUTHORIZATION\": \"Bearer dev-key\"}), \"dev-key\")

    def test_rejects_an_unknown_key(self):
        self.assertIsNone(authenticate({\"HTTP_AUTHORIZATION\": \"Bearer nope\"}))

    def test_rejects_another_scheme(self):
        self.assertIsNone(authenticate({\"HTTP_AUTHORIZATION\": \"Basic dev-key\"}))
")

(defun harness-media--make-project ()
  "Create the demo project with a short git history."
  (when (file-exists-p harness-media-project)
    (delete-directory harness-media-project t))
  (make-directory harness-media-project t)
  (harness-media--git "init" "-q")
  (harness-media--git "symbolic-ref" "HEAD" "refs/heads/main")
  (harness-media--write "README.md" harness-media--readme)
  (harness-media--write "pyproject.toml" harness-media--pyproject)
  (harness-media--write ".gitignore" "__pycache__/\n*.db\n")
  (harness-media--write "acme/__init__.py" "\"\"\"The Acme orders API.\"\"\"\n\n__version__ = \"0.4.0\"\n")
  (harness-media--write "acme/settings.py" harness-media--settings-v1)
  (harness-media--write "acme/auth.py" harness-media--auth)
  (harness-media--write "acme/orders.py" harness-media--orders-v1)
  (harness-media--write "acme/app.py" harness-media--app-v1)
  (harness-media--write "tests/__init__.py" "")
  (harness-media--write "tests/test_app.py" harness-media--test-app)
  (harness-media--write "tests/test_auth.py" harness-media--test-auth)
  (harness-media--commit "Orders API with API key authentication" 41)
  (harness-media--write "acme/db.py" harness-media--db)
  (harness-media--write "acme/products.py" harness-media--products)
  (harness-media--write "acme/app.py" harness-media--app-v2)
  (harness-media--commit "Serve the product catalogue" 17)
  (harness-media--write "acme/settings.py" harness-media--settings-v2)
  (harness-media--write "acme/webhooks.py" harness-media--webhooks)
  (harness-media--write "acme/orders.py" harness-media--orders-v2)
  (harness-media--commit "Tell webhook subscribers about new orders" 4)
  (dolist (other '("~/src/acme-web/" "~/src/infra/"))
    (make-directory (expand-file-name other) t)))

;;;; The harness's own repositories

;; The version picture compares the harness with the places its newer
;; commits come from, as on a machine that installed it with straight.el
;; from GitHub: straight's clone, which the harness was loaded from, the
;; repository on GitHub that clone pulls from, and a development
;; checkout.  The three are made here, with a history of their own.
;; GitHub is a bare repository in the scratch HOME: the scratch
;; ~/.gitconfig sends its URL there, and git may use no protocol but
;; file, so neither the clone nor a check reaches the network.

(defvar harness-version-origins)

(defconst harness-media--github "https://github.com/catvec/emacs-agent-harness"
  "The URL of the harness's repository on GitHub, which straight cloned.")

(defconst harness-media--harness-history
  '(("Run the harness in an Emacs process of its own" . 12)
    ("Restore the harness's tools under Claude Code 2.1.289" . 3.2)
    ("Hand conversations over when switching to a hosted-loop provider" . 2.9)
    ("Fallback: carry on with another provider when one runs out of quota or money" . 2.6)
    ("Auto-accept pending permission prompts when a session switches to yolo" . 2.3)
    ("Providers say why a call failed, so the fallback can act on it" . 2.1)
    ("Paste images with C-y, leaving C-c C-v to Verify" . 1.8)
    ("The usage dashboard shows and edits the fallback list" . 1.5)
    ("Search the task board in words, and act on it" . 1.2)
    ("Lay the handoff prompt out as a table view" . 0.9)
    ("Show the fallback entries' tiers in the usage dashboard" . 0.6)
    ("Ask how to hand over in a chat banner, not a wall of text" . 0.3))
  "The harness's history in the version picture, oldest first.
Each commit is (SUBJECT . DAYS-AGO).  The first
`harness-media--harness-installed' are what straight.el cloned and the
harness runs; the development checkout and GitHub have them all.")

(defconst harness-media--harness-installed 2
  "How many commits of `harness-media--harness-history' the harness runs.")

(defun harness-media--harness-paths ()
  "Return the harness's repositories in the scratch HOME, as a plist.
:dev the development checkout, :bare the stand-in for GitHub,
:clone straight's clone and :build straight's build directory, which
links to the clone's files."
  (list :dev (expand-file-name "~/src/emacs-agent-harness/")
        :bare (expand-file-name "~/srv/emacs-agent-harness.git/")
        :clone (expand-file-name "~/.emacs.d/straight/repos/emacs-agent-harness/")
        :build (expand-file-name "~/.emacs.d/straight/build/harness/")))

(defun harness-media--git-in (dir &rest args)
  "Run git with ARGS in DIR; return its output or signal."
  (let ((harness-media-project (file-name-as-directory (expand-file-name dir))))
    (apply #'harness-media--git args)))

(defun harness-media--harness-origins ()
  "Send GitHub's URL to the scratch HOME; configure the development checkout.
The URL leads to the bare repository there from the start, before
straight's clone is made or any check runs, as a file:// URL, which a
shallow clone needs; git may use no other protocol.  The version module
finds GitHub by itself, as the repository straight's clone pulls from;
the development checkout, which no session works in, is configured."
  (let ((paths (harness-media--harness-paths)))
    (harness-media--git-in "~" "config" "--global"
                           (format "url.file://%s.insteadOf" (directory-file-name (plist-get paths :bare)))
                           harness-media--github)
    (setenv "GIT_ALLOW_PROTOCOL" "file")
    (setq harness-version-origins
          (list (list :name "local" :location (abbreviate-file-name (plist-get paths :dev)) :branch "main")))))

(defconst harness-media--harness-bodies
  '(("Show the fallback entries' tiers in the usage dashboard"
     . "Name each fallback entry's tier beside its model, so the cheapest
fit for what a session needs is visible before it is chosen.")
    ("Ask how to hand over in a chat banner, not a wall of text"
     . "The handoff question is a banner of the choices now: what each
option keeps, and the box to change it."))
  "Bodies of the commits in the version picture that have one, by subject.
A commit's message body shows on the version page as its changelog entry.")

(defun harness-media--harness-commit (subject days-ago)
  "Commit SUBJECT in the development checkout, dated DAYS-AGO days back.
A subject in `harness-media--harness-bodies' is committed with that
body, so the version picture shows a commit as its changelog entry."
  (let* ((dev (plist-get (harness-media--harness-paths) :dev))
         (date (format-time-string "%Y-%m-%dT%H:%M:%S" (- (float-time) (* days-ago 86400))))
         (process-environment (append (list (concat "GIT_AUTHOR_DATE=" date)
                                            (concat "GIT_COMMITTER_DATE=" date))
                                      process-environment)))
    (with-temp-buffer
      (insert "- " subject "\n")
      (write-region nil nil (expand-file-name "NEWS.md" dev) t 'silent))
    (harness-media--git-in dev "add" "-A")
    (apply #'harness-media--git-in dev "-c" "commit.gpgsign=false" "commit" "-q" "--no-gpg-sign"
           "-m" subject
           (when-let* ((body (cdr (assoc subject harness-media--harness-bodies))))
             (list "-m" body)))))

(defun harness-media--make-harness-repos ()
  "Make the development checkout, GitHub and straight's clone of the harness.
Straight cloned GitHub's URL shallowly, back when GitHub had the commits
the harness runs; the development checkout has made the rest since and
pushed them."
  (let* ((paths (harness-media--harness-paths))
         (dev (plist-get paths :dev))
         (bare (plist-get paths :bare))
         (clone (plist-get paths :clone))
         (build (plist-get paths :build)))
    (dolist (dir (list dev bare clone build))
      (when (file-exists-p dir) (delete-directory dir t))
      (make-directory dir t))
    (harness-media--git-in dev "init" "-q")
    (harness-media--git-in dev "symbolic-ref" "HEAD" "refs/heads/main")
    (dolist (file '("harness.el" "lisp/harness-core.el"))
      (make-directory (file-name-directory (expand-file-name file dev)) t)
      (write-region (format ";;; %s --- the harness\n" (file-name-nondirectory file)) nil
                    (expand-file-name file dev) nil 'silent))
    (harness-media--git-in bare "init" "-q" "--bare")
    (harness-media--git-in bare "symbolic-ref" "HEAD" "refs/heads/main")
    (cl-loop for (subject . days) in harness-media--harness-history
             for n from 1
             do (harness-media--harness-commit subject days)
             when (= n harness-media--harness-installed)
             do (harness-media--git-in dev "push" "-q" bare "main")
             (harness-media--git-in "~" "clone" "-q" "--depth" "1" harness-media--github clone))
    (harness-media--git-in dev "push" "-q" bare "main")
    (dolist (file '("harness.el" "lisp/harness-core.el"))
      (make-directory (file-name-directory (expand-file-name file build)) t)
      (make-symbolic-link (expand-file-name file clone) (expand-file-name file build)))))

;;;; Files the scripted agents write

(defconst harness-media--ratelimit "\"\"\"Per-key rate limiting with token buckets.\"\"\"

import math
import threading
import time


class TokenBucket:
    \"\"\"Up to BURST tokens; RATE of them come back every PER seconds.\"\"\"

    def __init__(self, rate, per, burst, clock=time.monotonic):
        self.capacity, self.tokens = burst, float(burst)
        self.fill_rate = rate / per
        self.clock = clock
        self.updated = clock()

    def _refill(self):
        now = self.clock()
        gained = (now - self.updated) * self.fill_rate
        self.tokens = min(self.capacity, self.tokens + gained)
        self.updated = now

    def take(self):
        \"\"\"Spend a token; return False when there is none left.\"\"\"
        self._refill()
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False

    def wait_time(self):
        self._refill()
        return max(0.0, (1 - self.tokens) / self.fill_rate)


class RateLimiter:
    \"\"\"One token bucket per API key.\"\"\"

    def __init__(self, rate=100, per=60.0, burst=20,
                 clock=time.monotonic):
        self.rate, self.per, self.burst = rate, per, burst
        self.clock = clock
        self.buckets = {}
        self.lock = threading.Lock()

    def _bucket(self, key):
        if key not in self.buckets:
            self.buckets[key] = TokenBucket(
                self.rate, self.per, self.burst, self.clock)
        return self.buckets[key]

    def allow(self, key):
        with self.lock:
            return self._bucket(key).take()

    def retry_after(self, key):
        with self.lock:
            return math.ceil(self._bucket(key).wait_time())
")

(defconst harness-media--test-ratelimit "import unittest
from unittest import mock

from acme import app
from acme.ratelimit import RateLimiter
from tests.test_app import call


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


class RateLimiterTest(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.limiter = RateLimiter(rate=60, per=60.0, burst=3, clock=self.clock)

    def spend(self, key, n=3):
        for _ in range(n):
            self.limiter.allow(key)

    def test_allows_a_burst(self):
        self.assertTrue(all(self.limiter.allow(\"k\") for _ in range(3)))

    def test_refuses_past_the_burst(self):
        self.spend(\"k\")
        self.assertFalse(self.limiter.allow(\"k\"))
        self.assertEqual(self.limiter.retry_after(\"k\"), 1)

    def test_refills_over_time(self):
        self.spend(\"k\")
        self.clock.now += 1.0
        self.assertTrue(self.limiter.allow(\"k\"))

    def test_keys_have_their_own_buckets(self):
        self.spend(\"a\")
        self.assertTrue(self.limiter.allow(\"b\"))


class AppLimitTest(unittest.TestCase):
    def test_answers_429_with_retry_after(self):
        with mock.patch.object(app, \"limiter\", RateLimiter(rate=1, per=60.0, burst=1)):
            self.assertEqual(call()[0], \"200 OK\")
            status, headers, _ = call()
        self.assertEqual(status, \"429 Too Many Requests\")
        self.assertEqual(headers[\"Retry-After\"], \"60\")
")

(defconst harness-media--auth-constant-time "\"\"\"API key authentication.\"\"\"

import hmac

from acme import settings


def authenticate(environ):
    \"\"\"Return the request's API key when it is valid, else None.\"\"\"
    header = environ.get(\"HTTP_AUTHORIZATION\", \"\")
    scheme, _, key = header.partition(\" \")
    if scheme.lower() != \"bearer\":
        return None
    # Compare against every key in constant time, so timing leaks nothing.
    if not any(hmac.compare_digest(key, known) for known in settings.API_KEYS):
        return None
    return key
")

(defconst harness-media--latency-chart "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"960\" height=\"540\" viewBox=\"0 0 960 540\" font-family=\"sans-serif\">
  <rect width=\"960\" height=\"540\" rx=\"10\" fill=\"#181a28\"/>
  <text x=\"90\" y=\"44\" font-size=\"24\" font-weight=\"bold\" fill=\"#e6e8f4\">GET /orders: p95 latency by orders stored</text>
  <g stroke=\"#2e3148\" stroke-width=\"1\">
    <line x1=\"90\" y1=\"470\" x2=\"920\" y2=\"470\"/>
    <line x1=\"90\" y1=\"336.7\" x2=\"920\" y2=\"336.7\"/>
    <line x1=\"90\" y1=\"203.3\" x2=\"920\" y2=\"203.3\"/>
    <line x1=\"90\" y1=\"70\" x2=\"920\" y2=\"70\"/>
  </g>
  <g font-size=\"15\" fill=\"#9a9cb0\" text-anchor=\"end\">
    <text x=\"80\" y=\"475\">10 ms</text>
    <text x=\"80\" y=\"341.7\">100 ms</text>
    <text x=\"80\" y=\"208.3\">1 s</text>
    <text x=\"80\" y=\"75\">10 s</text>
  </g>
  <g font-size=\"15\" fill=\"#9a9cb0\" text-anchor=\"middle\">
    <text x=\"173\" y=\"500\">1,000</text>
    <text x=\"339\" y=\"500\">5,000</text>
    <text x=\"505\" y=\"500\">10,000</text>
    <text x=\"671\" y=\"500\">50,000</text>
    <text x=\"837\" y=\"500\">100,000</text>
    <text x=\"505\" y=\"528\">orders in the database</text>
  </g>
  <polyline fill=\"none\" stroke=\"#f78166\" stroke-width=\"3\" points=\"173,379.2 339,288.4 505,248.3 671,153.9 837,112.5\"/>
  <g fill=\"#f78166\">
    <circle cx=\"173\" cy=\"379.2\" r=\"5\"/><circle cx=\"339\" cy=\"288.4\" r=\"5\"/><circle cx=\"505\" cy=\"248.3\" r=\"5\"/>
    <circle cx=\"671\" cy=\"153.9\" r=\"5\"/><circle cx=\"837\" cy=\"112.5\" r=\"5\"/>
    <text x=\"837\" y=\"98\" font-size=\"15\" text-anchor=\"middle\">4.8 s</text>
  </g>
  <polyline fill=\"none\" stroke=\"#56d364\" stroke-width=\"3\" points=\"173,464.5 339,459.4 505,459.4 671,454.8 837,450.5\"/>
  <g fill=\"#56d364\">
    <circle cx=\"173\" cy=\"464.5\" r=\"5\"/><circle cx=\"339\" cy=\"459.4\" r=\"5\"/><circle cx=\"505\" cy=\"459.4\" r=\"5\"/>
    <circle cx=\"671\" cy=\"454.8\" r=\"5\"/><circle cx=\"837\" cy=\"450.5\" r=\"5\"/>
    <text x=\"837\" y=\"436\" font-size=\"15\" text-anchor=\"middle\">14 ms</text>
  </g>
  <g font-size=\"16\" fill=\"#c6c8d8\">
    <rect x=\"110\" y=\"92\" width=\"18\" height=\"4\" fill=\"#f78166\"/>
    <text x=\"138\" y=\"99\">every order at once (before)</text>
    <rect x=\"110\" y=\"118\" width=\"18\" height=\"4\" fill=\"#56d364\"/>
    <text x=\"138\" y=\"125\">limit=50, the default (after)</text>
  </g>
</svg>
"
  "docs/orders-latency.svg, the chart the pagination task hands in.")

(defconst harness-media--orders-paginated "\"\"\"Order handlers.\"\"\"

import json
from urllib.parse import parse_qs

from acme import webhooks

ORDERS = []
PAGE_SIZE = 50
MAX_PAGE_SIZE = 200


def list_orders(environ):
    query = parse_qs(environ.get(\"QUERY_STRING\", \"\"))
    limit = min(int(query.get(\"limit\", [PAGE_SIZE])[0]), MAX_PAGE_SIZE)
    offset = max(int(query.get(\"offset\", [0])[0]), 0)
    return \"200 OK\", {\"orders\": ORDERS[offset:offset + limit], \"total\": len(ORDERS)}


def create_order(environ):
    size = int(environ.get(\"CONTENT_LENGTH\") or 0)
    order = json.loads(environ[\"wsgi.input\"].read(size) or b\"{}\")
    order[\"id\"] = len(ORDERS) + 1
    ORDERS.append(order)
    webhooks.notify(order)
    return \"201 Created\", order
")

(defconst harness-media--timing "\"\"\"Log the requests that take longer than SLOW_SECONDS.\"\"\"

import logging
import time

SLOW_SECONDS = 0.5
log = logging.getLogger(\"acme.timing\")


def timed(app):
    \"\"\"Wrap the WSGI APP so that slow requests are logged.\"\"\"
    def wrapper(environ, start_response):
        started = time.monotonic()
        try:
            return app(environ, start_response)
        finally:
            elapsed = time.monotonic() - started
            if elapsed > SLOW_SECONDS:
                log.warning(\"slow request: %s %s took %.0f ms\",
                            environ[\"REQUEST_METHOD\"], environ[\"PATH_INFO\"], elapsed * 1000)
    return wrapper
")

(defconst harness-media--typed-settings "\"\"\"Settings, read from the environment once and checked at startup.\"\"\"

import os
from dataclasses import dataclass, field


def _list(name, default=\"\"):
    return [item for item in os.environ.get(name, default).split(\",\") if item]


@dataclass(frozen=True)
class Settings:
    api_keys: frozenset = field(default_factory=lambda: frozenset(_list(\"ACME_API_KEYS\", \"dev-key\")))
    database_url: str = os.environ.get(\"ACME_DATABASE_URL\", \"sqlite:///acme.db\")
    webhook_urls: tuple = field(default_factory=lambda: tuple(_list(\"ACME_WEBHOOK_URLS\")))
")

(defconst harness-media--openapi "openapi: 3.1.0
info:
  title: Acme orders API
  version: 0.4.0
components:
  schemas:
    Order:
      type: object
      required: [id, sku, quantity]
      properties:
        id: {type: integer, readOnly: true}
        sku: {type: string, example: TEE-M}
        quantity: {type: integer, minimum: 1}
")

(defconst harness-media--api-guide "# The Acme orders API

Every request needs an API key: `Authorization: Bearer KEY`.

## Orders

    curl -H 'Authorization: Bearer dev-key' http://localhost:8000/orders

    curl -X POST -H 'Authorization: Bearer dev-key' \\
         -d '{\"sku\": \"TEE-M\", \"quantity\": 2}' http://localhost:8000/orders

## Products

    curl -H 'Authorization: Bearer dev-key' http://localhost:8000/products
")

;;;; Scripted turns

(defvar harness-media--call-count 0 "Tool calls scripted so far, for their ids.")

(defun harness-media--think (text)
  "A thinking event of TEXT."
  (list :type 'thinking :delta text))

(defun harness-media--say (text)
  "A text event of TEXT."
  (list :type 'text :delta text))

(defun harness-media--tool (name &rest input)
  "A call of tool NAME with INPUT."
  (list :type 'tool-call :id (format "call-%03d" (cl-incf harness-media--call-count))
        :name name :input input))

(defun harness-media--todos (&rest items)
  "A todo_write call; each of ITEMS is (TEXT . STATUS)."
  (harness-media--tool "todo_write"
                       :todos (cl-loop for (text . status) in items for i from 1
                                       collect (list :id (number-to-string i) :text text :status status))))

(defun harness-media--git-commit (message)
  "A bash call committing every change as MESSAGE."
  (harness-media--tool "bash" :command (format "git add -A && git commit -q -m '%s'" message)))

(defun harness-media--ratelimit-script (_request)
  "The turn of the rate-limit session: rate limiting, from reading to tests."
  (list
   (harness-media--think "Requests are authenticated in acme/app.py before they reach a handler, so the limit belongs right after authentication, keyed by the API key. A token bucket per key gives the burst for free. I'll check how responses are built, put the limiter in a module of its own, wire it in and test it with a fake clock.")
   (harness-media--tool "list_dir" :path ".")
   (harness-media--tool "read_file" :path "acme/app.py")
   (harness-media--tool "read_file" :path "acme/auth.py")
   (harness-media--tool "grep" :pattern "authenticate" :path "acme")
   (harness-media--say "`application()` authenticates first; the limit goes right after that.")
   (harness-media--tool "write_file" :path "acme/ratelimit.py" :content harness-media--ratelimit)
   (harness-media--tool "edit_file" :path "acme/app.py"
                        :old_string "from acme.auth import authenticate\n"
                        :new_string "from acme.auth import authenticate\nfrom acme.ratelimit import RateLimiter\n\nlimiter = RateLimiter(rate=100, per=60.0, burst=20)\n")
   (harness-media--tool "edit_file" :path "acme/app.py"
                        :old_string "    handler = ROUTES.get("
                        :new_string "    if not limiter.allow(key):\n        retry = str(limiter.retry_after(key))\n        return respond(start_response, \"429 Too Many Requests\",\n                       {\"error\": \"rate limit exceeded\"},\n                       [(\"Retry-After\", retry)])\n    handler = ROUTES.get(")
   (harness-media--tool "write_file" :path "tests/test_ratelimit.py" :content harness-media--test-ratelimit)
   (harness-media--tool "bash" :command "python3 -m unittest")
   (harness-media--say "Each API key now gets a bucket of **20 requests** that refills at **100 a minute**; past that, the API answers `429` with a `Retry-After` header.

| File | Change |
|---|---|
| `acme/ratelimit.py` | `TokenBucket`, and a thread-safe `RateLimiter` |
| `acme/app.py` | the check, right after authentication |
| `tests/test_ratelimit.py` | 5 tests, with a fake clock |

All 12 tests pass.")))

(defun harness-media--fork-script (_request)
  "The turn of the fork in the rate-limit session's tree."
  (list
   (harness-media--think "A sliding-window log keeps each key's request times from the last minute and drops older ones. It is exact, at the cost of one timestamp per request.")
   (harness-media--say "A sliding-window log is exact: it keeps each key's request times from the last 60 seconds and refuses a request once there are 100 of them.

```python
class SlidingWindow:
    def __init__(self, limit=100, window=60.0, clock=time.monotonic):
        self.limit, self.window, self.clock = limit, window, clock
        self.hits = defaultdict(deque)

    def allow(self, key):
        now, hits = self.clock(), self.hits[key]
        while hits and hits[0] <= now - self.window:
            hits.popleft()
        if len(hits) >= self.limit:
            return False
        hits.append(now)
        return True
```

It costs up to 100 timestamps per key. Shall I use it in `acme/app.py` instead of the buckets?")))

(defun harness-media--btw-script (_request)
  "The answer of the BTW over the rate-limit session."
  (list
   (harness-media--say "A `429` that says how long to wait:

```
HTTP/1.1 429 Too Many Requests
Content-Type: application/json
Retry-After: 1

{\"error\": \"rate limit exceeded\"}
```

`Retry-After` is in whole seconds. At 100 requests a minute a token comes back every 0.6 s, so it is almost always 1.")))

(defun harness-media--webhooks-script (_request)
  "How webhooks go out: the turn before the permission request."
  (list
   (harness-media--tool "grep" :pattern "notify" :path "acme")
   (harness-media--tool "read_file" :path "acme/webhooks.py")
   (harness-media--say "`create_order()` calls `webhooks.notify(order)` once the order is stored. `notify()` then:

- POSTs the order as JSON to every URL in `ACME_WEBHOOK_URLS`, one after the other,
- opens a new connection for each, with a 5 second timeout,
- returns the URLs that failed; nothing retries them.")))

(defun harness-media--permission-script (_request)
  "A turn that stops on a permission request (in Ask mode)."
  (list
   (harness-media--think "An httpx.Client at module level keeps connections alive between calls, and a Limits object caps the pool. The project does not depend on httpx yet, so it has to be installed first.")
   (harness-media--say "I'll replace the per-request urllib calls with one module-level `httpx.Client`, which pools connections and reuses them across orders. httpx is not installed yet, so first:")
   (harness-media--tool "bash" :command "python3 -m pip install 'httpx>=0.28'")
   (harness-media--say "Installed.")))

(defun harness-media--slowest-script (_request)
  "Which endpoint is slowest: the turn before the question."
  (list
   (harness-media--tool "read_file" :path "acme/app.py")
   (harness-media--tool "read_file" :path "acme/products.py")
   (harness-media--tool "read_file" :path "acme/db.py")
   (harness-media--say "`GET /products`, by far. Each request opens a new SQLite connection and reads the whole catalogue, sorted by name:

```python
rows = db.query(\"SELECT id, name, price_cents FROM products ORDER BY name\")
```

The orders endpoints only touch a list in memory, and authentication is a set lookup.")))

(defun harness-media--question-script (_request)
  "A turn that stops on a question for the user."
  (list
   (harness-media--think "The catalogue changes rarely, so caching is safe. Where the cache lives depends on the deployment: per-process memory is simplest, Redis is shared by every worker but is one more service. Ask.")
   (harness-media--say "At that rate of change a cache is safe, and it takes the database off every request. Where it should live depends on how you deploy:")
   (harness-media--tool "ask_user"
                        :question "Where should the cached catalogue live?"
                        :options ["In each worker's memory, refreshed every 5 minutes"
                                  "In Redis, shared by every worker"
                                  "Nowhere yet: add an index on products.name first"])
   (harness-media--say "Thanks.")))

(defun harness-media--api-guide-script (_request)
  "An older session billed per token."
  (list
   (harness-media--tool "read_file" :path "acme/app.py")
   (harness-media--tool "write_file" :path "docs/api.md" :content harness-media--api-guide)
   (harness-media--say "docs/api.md covers authentication, orders and products, with a curl example each.")
   (list :type 'usage :input 152000 :output 64000 :cache-read 210000 :cache-write 0
         :cost 0.8203 :list-cost 0.8203 :billing 'api :context 23800)))

(defun harness-media--flaky-script (_request)
  "An older session, closed since."
  (list
   (harness-media--tool "read_file" :path "tests/test_app.py")
   (harness-media--say "`ORDERS` is module state, so `test_creates_an_order` saw the orders of whichever test ran before it. `setUp` now clears it, and the test passes in any order.")))

(defun harness-media--task-script (todos changes message summary &optional hold evidence problem)
  "A task's turn: TODOS, CHANGES (tool calls), a commit as MESSAGE, SUMMARY.
TODOS are the item texts.  With HOLD the turn stops working half way
and never ends, so the task stays in progress, and nothing is committed.
With EVIDENCE, hand_in's evidence items and PROBLEM, its required short
summary of what must be fixed, the turn hands its work in with SUMMARY
rather than saying it.  Every finished round should hand in, as a task
session is told to: one that ends without it puts [No report] on the
task's card (`harness-tasks--missing-report')."
  (let* ((n (length todos))
         (at (lambda (done)
               (apply #'harness-media--todos
                      (cl-loop for text in todos for i from 0
                               collect (cons text (cond ((< i done) "done") ((= i done) "in-progress") (t "pending"))))))))
    (if hold
        (append (list (funcall at 0)) (cl-subseq changes 0 1)
                (list (funcall at 1)) (cl-subseq changes 1)
                (list (list :type 'hold)))
      (append (list (funcall at 0)) changes
              (list (funcall at (1- n)) (harness-media--git-commit message) (funcall at n))
              (if evidence
                  ;; A word first, as models do: a session is named after
                  ;; a first turn that said something.
                  (list (harness-media--say "Done, and the tests pass: handing it in for review.")
                        (harness-media--tool "hand_in" :problem (or problem summary) :summary summary
                                             :evidence evidence))
                (list (harness-media--say summary)))))))

(defun harness-media--task-constant-time (_request)
  "Task: constant-time key checks."
  (harness-media--task-script
   '("Find where keys are compared" "Compare them with hmac.compare_digest")
   (list (harness-media--tool "read_file" :path "acme/auth.py")
         (harness-media--tool "write_file" :path "acme/auth.py" :content harness-media--auth-constant-time))
   "Compare API keys in constant time"
   "`authenticate()` now compares the key with every known key through `hmac.compare_digest`."
   nil
   (list (list :file "acme/auth.py" :caption "The key check, through hmac.compare_digest"))
   "API keys are compared with `==`, so a wrong key leaks how much of it matched."))

(defun harness-media--task-python (_request)
  "Task: require Python 3.12."
  (harness-media--task-script
   '("Raise requires-python" "List the supported versions")
   (list (harness-media--tool "read_file" :path "pyproject.toml")
         (harness-media--tool "edit_file" :path "pyproject.toml"
                              :old_string "requires-python = \">=3.11\"\n"
                              :new_string "requires-python = \">=3.12\"\nclassifiers = [\n    \"Programming Language :: Python :: 3.12\",\n    \"Programming Language :: Python :: 3.13\",\n]\n"))
   "Require Python 3.12"
   "pyproject.toml requires Python 3.12 and lists 3.12 and 3.13."
   nil
   (list (list :file "pyproject.toml" :caption "requires-python and the supported versions"))
   "The package advertises Python 3.11 support that no test covers."))

(defun harness-media--task-pagination (_request)
  "Task: paginate GET /orders, handed in with a chart and the test run."
  (let ((tests (harness-media--tool "bash" :command "python3 -m unittest")))
    (harness-media--task-script
     '("Read the orders handler" "Add limit and offset" "Update the tests" "Chart the latency")
     (list (harness-media--tool "read_file" :path "acme/orders.py")
           (harness-media--tool "write_file" :path "acme/orders.py" :content harness-media--orders-paginated)
           (harness-media--tool "edit_file" :path "tests/test_app.py"
                                :old_string "{\"orders\": []}" :new_string "{\"orders\": [], \"total\": 0}")
           tests
           (harness-media--tool "write_file" :path "docs/orders-latency.svg" :content harness-media--latency-chart))
     "Paginate GET /orders"
     "GET /orders takes `limit` (50 by default, 200 at most) and `offset`, and returns the total, so a client pages through the orders instead of loading them all."
     nil
     (list (list :image "docs/orders-latency.svg"
                 :caption "p95 latency of GET /orders: flat at 11-14 ms with pagination, where it grew to 4.8 s with every order at once")
           (list :tool_call (plist-get tests :id) :caption "The tests pass, the total included."))
     "GET /orders returns every order at once, so a client can only load the whole list.")))

(defun harness-media--task-slow (_request)
  "Task: log slow requests."
  (harness-media--task-script
   '("Time every request" "Log the slow ones")
   (list (harness-media--tool "read_file" :path "acme/app.py")
         (harness-media--tool "write_file" :path "acme/timing.py" :content harness-media--timing))
   "Log slow requests"
   "`acme.timing.timed()` wraps the app and logs every request slower than 500 ms."
   nil
   (list (list :file "acme/timing.py" :caption "The timing middleware and its threshold"))
   "Requests slower than 500 ms are invisible in the logs, so slowness is found only by report."))

(defun harness-media--task-slow-again (_request)
  "Task: log slow requests, after review: the round hands its work in again."
  (list (harness-media--tool "edit_file" :path "acme/timing.py"
                             :old_string "SLOW_SECONDS = 0.5" :new_string "SLOW_SECONDS = 0.5  # seconds")
        (harness-media--git-commit "Say the threshold is in seconds")
        (harness-media--say "The threshold says it is in seconds now: handing it in again.")
        (harness-media--tool "hand_in" :problem "The threshold constant does not say it is in seconds."
                             :summary "`SLOW_SECONDS`, the threshold of `acme.timing`, says it is in seconds."
                             :evidence (list (list :file "acme/timing.py" :caption "The threshold, in seconds")))))

(defun harness-media--task-settings (_request)
  "Task in progress: typed settings."
  (harness-media--task-script
   '("Read how settings are used" "Define a typed Settings class" "Fail at startup on bad values" "Update the callers")
   (list (harness-media--tool "grep" :pattern "settings\\." :path "acme")
         (harness-media--tool "write_file" :path "acme/settings.py" :content harness-media--typed-settings))
   nil nil t))

(defun harness-media--task-openapi (_request)
  "Task in progress: the OpenAPI schema."
  (harness-media--task-script
   '("Describe the order model" "Document GET and POST /orders" "Validate the schema")
   (list (harness-media--tool "read_file" :path "acme/orders.py")
         (harness-media--tool "write_file" :path "docs/openapi.yaml" :content harness-media--openapi))
   nil nil t))

(defun harness-media--task-compress (_request)
  "Task in progress, taking the slots picture's last slot: compressed responses."
  (harness-media--task-script
   '("Find where responses are written" "Compress them when the client accepts gzip" "Test both ways")
   (list (harness-media--tool "read_file" :path "acme/app.py")
         (harness-media--tool "read_file" :path "tests/test_app.py"))
   nil nil t))

(defun harness-media--task-health (_request)
  "Task that asks the user a question."
  (list
   (harness-media--think "A health endpoint for the load balancer. Whether it should touch the database changes what a failing check means.")
   (harness-media--tool "read_file" :path "acme/app.py")
   (harness-media--tool "ask_user"
                        :question "Should /health check the database too, or only that the process is up?"
                        :options ["Only that the process is up"
                                  "The process and the database (SELECT 1)"
                                  "Both: /health for liveness, /ready for the database"])
   (harness-media--say "Thanks.")))

(defconst harness-media--write-ups
  '(("csv" "Export orders as CSV" "Finance copies orders out of the JSON by hand to reconcile them in a spreadsheet. Give them a CSV export."
     "Add an `export_orders_csv` handler to `acme/orders.py` that writes `id`, `sku`, `quantity` and `created` with `csv.DictWriter`, and route `GET /orders.csv` to it in `acme/app.py`. Answer `text/csv` with a `Content-Disposition` file name."
     "Should the export honour the pagination parameters, or always contain every order?")
    ("retry" "Retry failed webhooks with backoff" "`notify()` gives up on a subscriber after one failed POST, so a subscriber that is briefly down misses orders for good."
     "Keep failed deliveries in a `webhook_retries` table and retry them from a background thread in `acme/webhooks.py`, waiting 1, 2, 4... minutes and giving up after an hour."
     "Should a delivery that gave up be reported somewhere?"))
  "Backlog write-ups as (KEYWORD TITLE WHY CHANGE QUESTION).")

(defun harness-media--write-up (note)
  "The turn that writes up the backlog task NOTE."
  (let ((entry (or (cl-find-if (lambda (e) (string-match-p (car e) note)) harness-media--write-ups)
                   (list "" (string-trim note) "" "" ""))))
    (list (harness-media--tool "read_file" :path (if (string-match-p "webhook" note) "acme/webhooks.py" "acme/orders.py"))
          (harness-media--say (format "%s\n\n**What and why.** %s\n\n**Change.** %s\n\n**Done when.** The behaviour above works and a test in `tests/` covers it.\n\n**Open questions.** %s"
                                      (nth 1 entry) (nth 2 entry) (nth 3 entry) (nth 4 entry))))))

(defun harness-media--baseline-denied-script (_request)
  "A turn that stops on a call the session's own rule refuses."
  (list
   (harness-media--think "The suite is the fastest way to see what the pooled client changes, and it has to be run before I touch anything. `python3 -m unittest` is exactly what this session's rules refuse, so the call will be denied; the user can approve that one call in the chat.")
   (harness-media--say "Before I change `acme/webhooks.py`, let me run the suite as a baseline:")
   (harness-media--tool "bash" :command "python3 -m unittest")))

(defun harness-media--rerun-approved-script (request)
  "The turn the user's approval starts: rerun the refused call by handle.
The handle is the one the approval message names."
  (let* ((text (or (car (last (harness-media--user-texts request))) ""))
         (handle (and (string-match "handle \\([^ )]+\\)" text) (match-string 1 text))))
    (list (harness-media--tool "rerun_approved" :handle handle)
          (harness-media--say "The suite is green, so the baseline holds. Now the pooled client in `acme/webhooks.py`."))))

(defconst harness-media--titles
  '(("hmac" . "Constant-time API key checks")
    ("requires-python" . "Require Python 3.12")
    ("limit/offset" . "Paginate GET /orders")
    ("slower than" . "Log slow requests")
    ("typed config" . "Validate settings at startup")
    ("OpenAPI" . "Write the OpenAPI schema")
    ("/health" . "Add a /health endpoint")
    ("csv" . "Export orders as CSV")
    ("retry" . "Retry failed webhooks")
    ;; The slots picture's: one at work, four waiting.
    ("gzip" . "Compress large responses")
    ("refund" . "Refund paid orders")
    ("customer_id" . "Index orders by customer")
    ("DELETE /orders" . "Cancel unshipped orders")
    ("created_at" . "Rename the created column"))
  "Titles the scripted naming gives, by a regexp of the first message.")

(defconst harness-media--scripts
  '(("Rate-limit the orders API" . harness-media--ratelimit-script)
    ("sliding-window" . harness-media--fork-script)
    ("hits the limit" . harness-media--btw-script)
    ("tell subscribers" . harness-media--webhooks-script)
    ("webhook sender" . harness-media--permission-script)
    ("slowest" . harness-media--slowest-script)
    ("Cache the catalogue" . harness-media--question-script)
    ("docs/api.md" . harness-media--api-guide-script)
    ("one time in ten" . harness-media--flaky-script)
    ("type hints to acme/db.py" . harness-media--queue-script)
    ("sqlite3.Row factory" . harness-media--queue-steered)
    ("Sent back from review" . harness-media--task-slow-again)
    ("hmac" . harness-media--task-constant-time)
    ("requires-python" . harness-media--task-python)
    ("limit/offset" . harness-media--task-pagination)
    ("slower than" . harness-media--task-slow)
    ("typed config" . harness-media--task-settings)
    ("OpenAPI" . harness-media--task-openapi)
    ("Let a sub-agent run" . harness-media--notes-script)
    ("Run the project's check suite" . harness-media--notes-child-script)
    ("old build" . harness-media--decisions-script)
    ("dropped after one try" . harness-media--quote-script)
    ;; The denied call and the user's approval of it.
    ("baseline" . harness-media--baseline-denied-script)
    ("The user approved the denied call" . harness-media--rerun-approved-script)
    ("Audit how API keys" . harness-media--access-script)
    ("/health" . harness-media--task-health)
    ("gzip" . harness-media--task-compress))
  "Scripts as (REGEXP . FUNCTION), matched against the newest user message.")

;;;; Scripted providers

(defvar harness-media--rest (make-hash-table :test 'equal)
  "Session id -> the rest of its script after a tool call.")

(defun harness-media--user-texts (request)
  "Return the text of each user message of REQUEST, oldest first."
  (cl-loop for m in (plist-get request :messages)
           when (member (plist-get m :role) '(user "user"))
           append (cl-loop for b in (plist-get m :content)
                           when (equal (plist-get b :type) "text") collect (plist-get b :text))))

(defun harness-media--continuing-p (request)
  "Non-nil when REQUEST carries tool results: the turn goes on."
  (let ((last (car (last (plist-get request :messages)))))
    (and last (cl-some (lambda (b) (equal (plist-get b :type) "tool_result")) (plist-get last :content)))))

(defun harness-media--search-query (text)
  "The line a search asked: the line of TEXT that starts with \"Query:\".
TEXT is the message that carries the line to the search's model."
  (if (string-match "^Query: \\(.*\\)$" text) (match-string 1 text) ""))

(defun harness-media--search-session (key)
  "How a search names the session KEY of the world to its model.
That is the first eight characters of its id, as the sessions are listed."
  (let ((id (plist-get harness-media--world key)))
    (and id (substring id 0 (min 8 (length id))))))

(defun harness-media--search-json (&rest fields)
  "The one line of JSON a search's model answers with.
FIELDS are `:show' (task ids), `:sessions' (session ids), `:commands'
\(command names) and `:do' (actions on tasks), each a list, `:answer',
the answer in words, in Markdown, and `:note', a sentence; a field left
out is empty."
  (harness-json-encode-text
   (append (list :show (harness-json-array (plist-get fields :show))
                 :sessions (harness-json-array (plist-get fields :sessions))
                 :commands (harness-json-array (plist-get fields :commands))
                 :do (harness-json-array (plist-get fields :do)))
           (and (plist-get fields :answer) (list :answer (plist-get fields :answer)))
           (and (plist-get fields :note) (list :note (plist-get fields :note))))))

(defconst harness-media--attach-answer
  "The guide is `docs/api.md`, which the *Write the API guide* session wrote. To attach it to your next message:

1. Press `C-c C-a` in the chat's box (`harness-compose-add-attachment`).
2. Type part of its name, `api.md`, then `RET`: a file of the project is found in any directory.

A file copied in a file manager attaches with `C-y` instead (`harness-compose-yank`)."
  "What the scripted search model answers in words to how to attach the API guide.")

(defun harness-media--search-answer (text &optional looked)
  "The scripted search model's answer to TEXT, the message carrying the query.
TEXT is what a search sends its model: where the query was typed, the
board, the sessions and the commands, then the query, which alone picks
the answer.  LOOKED is non-nil once the model has asked to look further
and been told what it found (its second answer):
- the slow-request warning, asked on the board, shows that task and
  archives it, so the picture has a filter, a toast and an [Undo];
- attaching the API guide, asked in a chat, asks to look in the
  sessions' transcripts for the guide, as a model does when a name says
  little, then answers how in words (`harness-media--attach-answer')
  and names the command that attaches a file and the session that wrote
  the guide, which the session search found by what was said in it: the
  picture shows the answer, then the passage, for [Open] to go to;
- anything else finds nothing."
  (let ((query (harness-media--search-query text))
        (slow (plist-get (plist-get harness-media--world :tasks) :slow))
        (guide (harness-media--search-session :guide)))
    (cond
     ((and slow (string-match-p "slow request warning" query))
      (harness-media--search-json :show (list slow)
                                  :do (list (list :task slow :action "archive"))))
     ((and guide (string-match-p "\\`how do i attach the api guide" (downcase query)))
      (if looked
          (harness-media--search-json :sessions (list guide)
                                      :commands (list "harness-compose-add-attachment" "harness-compose-yank")
                                      :answer harness-media--attach-answer)
        (harness-json-encode-text (list :sessions "API guide"))))
     (t (harness-media--search-json)))))

(defun harness-media--script (request)
  "Return the events that answer REQUEST."
  (let* ((system (or (plist-get request :system) ""))
         (texts (harness-media--user-texts request))
         (first (or (car texts) ""))
         (newest (or (car (last texts)) "")))
    (cond
     ((string-prefix-p "You are the permission judge" system)
      (list (harness-media--say "{\"decision\":\"allow\",\"reason\":\"Ordinary development work inside the project.\"}")))
     ((string-prefix-p "You write short titles" system)
      (list (harness-media--say (or (cdr (cl-find-if (lambda (e) (string-match-p (car e) first)) harness-media--titles))
                                    "Work on the API"))))
     ((string-match-p "^## Task refinement" system) (harness-media--write-up first))
     ;; The harness's search: answer in JSON, as the prompt asks.  The
     ;; query is in the first message; a second one is what a look at
     ;; the transcripts came back with.
     ((string-prefix-p "You are the search box" system)
      (list (harness-media--say (harness-media--search-answer first (cdr texts)))))
     ;; The Insights report's summary, in JSON too.
     ((string-prefix-p "You write the Insights report" system)
      (list (harness-media--say (harness-json-encode-text harness-media--insights-summary))))
     (t (let ((entry (cl-find-if (lambda (e) (string-match-p (car e) newest)) harness-media--scripts)))
          (if entry
              (funcall (cdr entry) request)
            (list (harness-media--say "Done."))))))))

(defun harness-media--size (request)
  "Estimate the tokens of REQUEST: four characters a token, plus the tools."
  (let ((chars (length (or (plist-get request :system) ""))))
    (dolist (m (plist-get request :messages))
      (dolist (b (plist-get m :content))
        (setq chars (+ chars (length (format "%s" (or (plist-get b :text) (plist-get b :content)
                                                      (plist-get b :input) "")))))))
    (+ 7800 (/ chars 4))))

(defun harness-media--usage (request written)
  "Return the usage event of REQUEST, whose answer had WRITTEN characters."
  (let* ((model (plist-get request :model))
         (context (harness-media--size request))
         (fresh (min context 1800))
         (output (+ 60 (/ written 4)))
         (tokens (list :input fresh :output output :cache-read (- context fresh) :cache-write fresh))
         (price (or (ignore-errors (harness-call 'usage/price model tokens)) 0.0)))
    (append (list :type 'usage :context (+ context output)) tokens
            (if (string-prefix-p "claude:" model)
                (list :cost 0.0 :list-cost price :billing 'subscription :plan "max")
              (list :cost price :list-cost price :billing 'api)))))

(defun harness-media--complete (request)
  "Answer REQUEST with its script, one event at a time.
A tool call ends the request, as with a real model: the agent runs the
tool and asks again, and the script goes on from there.  A request made
beside a session's turn (`:ephemeral', as naming the session is) leaves
the turn's script alone."
  (let* ((on-event (plist-get request :on-event))
         (sid (or (plist-get (plist-get request :session) :id) "none"))
         (side (plist-get request :ephemeral))
         (rest (if (and (not side) (harness-media--continuing-p request))
                   (gethash sid harness-media--rest 'none)
                 'none))
         (script (if (eq rest 'none) (harness-media--script request) rest))
         (written 0) (reported nil) (cancelled nil) (timer nil))
    (unless side (remhash sid harness-media--rest))
    (cl-labels ((emit (event) (funcall on-event event))
                (finish (reason)
                  (unless reported (emit (harness-media--usage request written)))
                  (emit (list :type 'done :stop-reason reason)))
                (later () (setq timer (run-at-time harness-media-delay nil #'step)))
                (step ()
                  (unless cancelled
                    (let ((event (pop script)))
                      (pcase (plist-get event :type)
                        ('nil (finish 'end-turn))
                        ;; The rest is kept before the call goes out: a
                        ;; tool that ends the turn (hand_in) can cancel it
                        ;; while the call is emitted, and the cancel drops
                        ;; it, or the round after -- a task sent back --
                        ;; would replay an empty rest.
                        ('tool-call (puthash sid script harness-media--rest) (emit event) (finish 'tool-use))
                        ('hold nil)
                        ('usage (setq reported t) (emit event) (later))
                        (_ (setq written (+ written (length (or (plist-get event :delta) ""))))
                           (emit event)
                           (later)))))))
      (emit '(:type start))
      (later))
    (list :cancel (lambda ()
                    (setq cancelled t)
                    (when timer (cancel-timer timer))
                    ;; A turn a tool ended (hand_in cancels it) takes no
                    ;; more of its script: the next request -- a task sent
                    ;; back, say -- must not get the rest.
                    (unless side (remhash sid harness-media--rest))
                    (funcall on-event '(:type done :stop-reason cancelled))))))

(defun harness-media--claude-models ()
  "The model catalogue of the real Claude Code provider, read from its source."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/modules/harness-provider-claude.el" harness-media-root))
    (re-search-forward "^(defconst harness-provider-claude-models")
    (goto-char (match-beginning 0))
    (eval (nth 2 (read (current-buffer))) t)))

(defun harness-media--claude-quota (&optional _refresh)
  "The Max plan's quota, as the Claude Code provider reports it."
  (let ((now (float-time)))
    (harness-resolved
     (list :billing 'subscription :plan "max" :plan-label "Claude Max" :auth "claude.ai"
           :account (list :email "sam@acme.example")
           :available t :updated (- now 40)
           :windows (list (list :name "5h" :label "Current session (5 hours)" :used 0.23 :resets (+ now (* 161 60)))
                          (list :name "7d" :label "This week, all models" :used 0.41 :resets (+ now (* 2.6 86400)))
                          (list :name "7d Opus" :label "This week, Opus" :used 0.12 :resets (+ now (* 2.6 86400))))
           :extra (list :enabled nil :used 0.0 :limit 50.0 :currency "USD")))))

(defun harness-media--define-providers ()
  "Register the scripted stand-ins for Claude Code and OpenRouter."
  (harness-define-provider 'claude
    :label "Claude Code"
    :doc "Scripted stand-in for the Claude Code CLI, for screenshots."
    :models (let ((models (harness-media--claude-models))) (lambda () (harness-resolved models)))
    :complete #'harness-media--complete
    :quota #'harness-media--claude-quota
    :capabilities '(:vision t :thinking t :quota t :billing t))
  (harness-define-provider 'openrouter
    :label "OpenRouter"
    :doc "Scripted stand-in for OpenRouter, for screenshots."
    :models (lambda ()
              (harness-resolved
               '((:name "openai/gpt-5" :label "OpenAI: GPT-5" :context-window 400000
                  :input-modalities ("text" "image")
                  :pricing (:input 1.25 :output 10.0 :cache-read 0.125 :cache-write 1.25))
                 (:name "google/gemini-2.5-pro" :label "Google: Gemini 2.5 Pro" :context-window 1048576
                  :input-modalities ("text" "image")
                  :pricing (:input 1.25 :output 10.0 :cache-read 0.31 :cache-write 1.625)))))
    :complete #'harness-media--complete
    :capabilities '(:vision t))
  (harness-await (harness-as-promise (harness-call 'provider/models t)) 30)
  (harness-ui-refresh-models)
  (harness-ui-refresh-quotas))

;;;; Building the world

(defun harness-media--session (id)
  "Return session ID as the harness holds it."
  (harness-call 'session/get id))

(defun harness-media--status (id)
  "Return the status of session ID, a symbol."
  (let ((status (plist-get (harness-media--session id) :status)))
    (if (stringp status) (intern status) status)))

(defun harness-media--wait-status (id statuses &optional timeout)
  "Wait until session ID's status is one of STATUSES, at most TIMEOUT seconds."
  (harness-media--wait (lambda () (memq (harness-media--status id) statuses))
                       (or timeout 60) (format "session %s to be %s" id statuses)))

(defun harness-media--new-session (&rest plist)
  "Create a session from PLIST in the demo project; return its id."
  (plist-get (apply #'harness-call 'session/create
                    (append plist (list :cwd (or (plist-get plist :cwd) harness-media-project))))
             :id))

(defun harness-media--prompt (id text &optional statuses)
  "Send TEXT to session ID and wait until its status is one of STATUSES.
STATUSES defaults to idle."
  (harness-call 'agent/prompt id (list (list :type "text" :text text)))
  (harness-media--wait (lambda () (not (eq (harness-media--status id) 'idle))) 10
                       (format "session %s to start" id))
  (harness-media--wait-status id (or statuses '(idle))))

(defun harness-media--task (id)
  "Return task ID."
  (harness-call 'task/get id))

(defun harness-media--wait-task (id predicate what &optional timeout)
  "Wait until PREDICATE holds for task ID, described as WHAT.
Give up after TIMEOUT seconds (default 90)."
  (harness-media--wait (lambda () (funcall predicate (harness-media--task id)))
                       (or timeout 90) (format "task %s %s" id what)))

(defun harness-media--column (task)
  "Return the column of TASK, a string."
  (format "%s" (plist-get task :column)))

(defun harness-media--submit (prompt &rest opts)
  "Submit PROMPT as a task of the demo project with OPTS; return its id."
  (plist-get (harness-call 'task/submit harness-media-project prompt opts) :id))

(defconst harness-media--notes-command
  "for i in $(seq 1 40); do printf 'run %s of 40: ' \"$i\"; python3 -m unittest 2>&1 | tail -n 1; sleep 0.7; done"
  "What the notes picture's sub-agent runs: checks in a loop, long enough
to still be running while the picture is taken, a line each round.")

(defun harness-media--notes-script (_request)
  "The session of the notes picture: it sends a sub-agent to run the checks."
  (list (harness-media--say "The suite takes a while; I'll have a sub-agent run it and keep an eye on it.")
        (harness-media--tool "spawn_agent"
                             :prompt (concat "Run the project's check suite in a loop for a couple of minutes "
                                             "and report anything that fails.")
                             :name "check suite")
        (harness-media--say "The sub-agent is running the checks.")))

(defun harness-media--notes-child-script (_request)
  "The sub-agent of the notes picture: the check run, and its word on it."
  (list (harness-media--tool "bash" :command harness-media--notes-command)
        (harness-media--say "Every run passed.")))

(defun harness-media--hold-merge-queue ()
  "Keep the demo project's merge queue busy, so a verified branch waits in it.
The picture of the board then has a task in its merging section.  A
task's branch merges into the main checkout, which has no session to
keep busy (see harness-merge.el): the checkout's merge lock is taken
instead, by a merge that never ends."
  (puthash (harness-merge--key harness-media-project) "media-hold" harness-merge--locks))

(defun harness-media--build-tasks ()
  "Fill the task board: done, merging, in review, in progress, stuck and in the backlog."
  (let* ((constant (harness-media--submit "use hmac.compare_digest when checking API keys, so a key check takes the same time whatever the key"))
         (python (harness-media--submit "we deploy on 3.12 now: bump requires-python and list the versions we support in pyproject.toml")))
    (dolist (id (list constant python))
      (harness-media--wait-task id (lambda (task) (equal (harness-media--column task) "review")) "to wait for review"))
    (dolist (id (list constant python))
      (harness-call 'task/verify id)
      (harness-media--wait-task id (lambda (task) (equal (harness-media--column task) "done")) "to merge"))
    (let ((pagination (harness-media--submit "GET /orders returns every order at once. Add limit/offset query parameters (50 by default, at most 200) and return the total count"))
          (slow (harness-media--submit "log a warning with the method, the path and the duration of any request slower than 500 ms"))
          (health (harness-media--submit "add a /health endpoint for the load balancer" :non-interactive :false))
          (settings (harness-media--submit "move settings.py to a typed config object, so a bad environment variable fails at startup and not on first use"))
          (openapi (harness-media--submit "write an OpenAPI 3.1 schema for the /orders endpoints in docs/openapi.yaml"))
          (csv (harness-media--submit "csv export of orders for the finance team" :refine t))
          (retry (harness-media--submit "webhooks: retry failed deliveries with exponential backoff, give up after an hour" :refine t)))
      (dolist (id (list pagination slow))
        (harness-media--wait-task id (lambda (task) (equal (harness-media--column task) "review")) "to wait for review"))
      ;; With the merge queue busy, the verified branch waits in it.
      (harness-media--hold-merge-queue)
      (harness-call 'task/verify pagination)
      (harness-media--wait-task pagination (lambda (task) (equal (harness-media--column task) "merging"))
                                "to wait in the merge queue")
      ;; The words of a round are kept in the review as written by the
      ;; user, whose name the review shots below give their comments too.
      (let ((user-full-name "Noah Huppert") (user-mail-address "noah@acme.example"))
        (harness-call 'task/reject slow "Say which unit the threshold is in."))
      (harness-media--wait-task slow (lambda (task) (equal (harness-media--column task) "active")) "to go back to work")
      (harness-media--wait-task slow (lambda (task) (equal (harness-media--column task) "review")) "to come back for review")
      (harness-media--wait-task health (lambda (task) (equal (harness-media--column task) "needs-input")) "to ask its question")
      (dolist (id (list settings openapi))
        (harness-media--wait-task id (lambda (task)
                                       (let ((session (harness-ui-session (plist-get task :session))))
                                         (cl-some (lambda (todo) (equal (plist-get todo :status) "done"))
                                                  (plist-get session :todos))))
                                  "to get going"))
      (dolist (id (list csv retry))
        (harness-media--wait-task id (lambda (task) (plist-get task :refined)) "to be written up"))
      (setq harness-media--world
            (append (list :tasks (list :constant constant :python python :pagination pagination :slow slow
                                       :health health :settings settings :openapi openapi :csv csv :retry retry))
                    harness-media--world))
      (harness-media--seed-recaps (plist-get harness-media--world :tasks)))))

(defun harness-media--seed-recaps (tasks)
  "Give TASKS their recap subtitles, as the recap module would.
Every agent of the run is scripted, so the module is off (see
`harness-media--setup-harness') and the pictures get hand-written
recaps: the lines the model would have written by now."
  (let ((now (float-time)))
    (cl-loop for (key . recap)
             in `((:constant . "Switched the API key check to hmac.compare_digest; the timing test passes")
                  (:python . "Bumped requires-python to 3.12 and listed the supported versions in pyproject")
                  (:pagination . "Added limit/offset paging to GET /orders, 50 by default and at most 200, with the total count")
                  (:slow . "Logs method, path and duration for requests over 500 ms, and names the unit in the message")
                  (:health . "Added /health and its test; waiting on whether readiness should check the database")
                  (:settings . "Moved settings.py to a typed config object, so a bad environment variable fails at startup")
                  (:openapi . "Wrote the OpenAPI 3.1 schema for the /orders endpoints in docs/openapi.yaml"))
             for id = (plist-get tasks key)
             when id do (harness-tasks--set id :recap recap :recap-at now
                                            :recap-turns 3 :recap-tools 6))))

(defun harness-media--build-sessions ()
  "Run the conversations the chat pictures and the session list show."
  (let ((guide (harness-media--new-session :name "Write the API guide" :model "openrouter:openai/gpt-5"
                                           :permission-mode 'accept-edits))
        (flaky (harness-media--new-session :name "Fix the flaky order test" :model "claude:claude-sonnet-5")))
    (harness-media--prompt guide "Write docs/api.md: a short guide to every endpoint, with curl examples.")
    (harness-media--prompt flaky "test_creates_an_order fails about one time in ten on CI. Why?")
    (dolist (id (list guide flaky)) (harness-call 'session/deactivate id))
    (setq harness-media--world (append (list :guide guide :flaky flaky) harness-media--world)))
  (let ((ratelimit (harness-media--new-session :name "Rate-limit the orders API" :model "claude:claude-fable-5-1"
                                               :permission-mode 'auto :thinking "high")))
    (harness-media--prompt ratelimit "Rate-limit the orders API: 100 requests a minute per API key, with a small burst. Over the limit, answer 429 with a Retry-After header.")
    ;; A fork from where the agent had read the code, and a BTW.
    (let* ((nodes (harness-call 'session/nodes ratelimit))
           (head (plist-get (harness-media--session ratelimit) :head))
           (branch (plist-get (cl-find-if (lambda (n) (and (equal (format "%s" (plist-get n :kind)) "assistant")
                                                           (string-prefix-p "`application()`" (or (plist-get n :content) ""))))
                                          nodes)
                              :id)))
      (harness-call 'session/set-head ratelimit branch)
      (let ((fork (plist-get (harness-await (harness-as-promise
                                             (harness-call 'session/fork ratelimit :kind 'fork :name "Sliding-window limiter"))
                                            30)
                             :id)))
        (harness-call 'session/set-head ratelimit head)
        (harness-media--prompt fork "Try a sliding-window log instead, so a key can never make more than 100 requests in any 60 seconds.")
        (let ((btw (plist-get (harness-call 'session/btw ratelimit "What does a client see?") :id)))
          (harness-media--prompt btw "What does a client see when it hits the limit?")
          (setq harness-media--world (append (list :ratelimit ratelimit :fork fork :btw btw) harness-media--world))))))
  (let ((permission (harness-media--new-session :name "Pool the webhook connections" :model "claude:claude-sonnet-5"
                                                :permission-mode 'ask))
        (question (harness-media--new-session :name "Cache the product catalogue" :model "claude:claude-opus-5-5"
                                              :permission-mode 'accept-edits)))
    (harness-media--prompt permission "How do we tell subscribers about new orders?")
    (harness-media--prompt permission "The webhook sender times out under load. Switch it to httpx with one pooled client." '(blocked))
    (harness-media--prompt question "Which of our endpoints is the slowest, judging by the code?")
    (harness-media--prompt question "Cache the catalogue then; it changes a few times a day at most." '(blocked))
    (setq harness-media--world (append (list :permission permission :question question) harness-media--world))))

(defun harness-media--day-start (time)
  "Return the float time at which the local day of TIME starts."
  (let ((d (decode-time time)))
    (float-time (encode-time (list 0 0 0 (decoded-time-day d) (decoded-time-month d) (decoded-time-year d) nil -1 nil)))))

(defun harness-media--pick (weights)
  "Return a VALUE of WEIGHTS, an alist of (VALUE . WEIGHT), at random."
  (let ((n (random (apply #'+ (mapcar #'cdr weights)))))
    (cl-loop for (value . weight) in weights
             if (< n weight) return value
             else do (setq n (- n weight)))))

(defun harness-media--seed-usage ()
  "Record a month of model calls across three projects."
  (let ((now (float-time))
        (web (expand-file-name "~/src/acme-web/"))
        (infra (expand-file-name "~/src/infra/"))
        (count 0))
    (dotimes (day 31)
      (let* ((start (harness-media--day-start (- now (* day 86400))))
             (weekday (string-to-number (format-time-string "%u" start)))
             (scale (pcase weekday (6 0.3) (7 0.12) (_ (+ 0.75 (/ (random 50) 100.0)))))
             (calls (round (* scale 70))))
        (dotimes (_ calls)
          (let* ((ts (+ start (* 3600 8.5) (random (* 3600 10))))
                 (model (harness-media--pick '(("claude:claude-fable-5-1" . 52) ("claude:claude-opus-5-5" . 14)
                                               ("claude:claude-sonnet-5" . 20) ("claude:claude-haiku-4-5-20251001" . 5)
                                               ("openrouter:openai/gpt-5" . 9))))
                 (project (harness-media--pick (list (cons harness-media-project 60) (cons web 29) (cons infra 11))))
                 (api (string-prefix-p "openrouter:" model))
                 (context (+ 12000 (random 90000)))
                 (fresh (if api (+ 20000 (random 40000)) (+ 600 (random 3000))))
                 (tokens (list :input fresh :output (+ 150 (random (if api 6000 2400)))
                               :cache-read (max 0 (- context fresh)) :cache-write (if api 0 (+ 300 (random 2500)))))
                 (price (harness-call 'usage/price model tokens)))
            (when (< ts now)
              (cl-incf count)
              (harness-call 'usage/record
                            (append (list :ts ts :session (format "seed-%s-%d" (file-name-nondirectory (directory-file-name project)) (random 12))
                                          :project project :model model
                                          :cost (if api price 0.0) :list-cost price
                                          :billing (if api 'api 'subscription))
                                    tokens)))))))
    (harness-media--log "recorded %d model calls of usage history" count)))

(defun harness-media--seed-budgets ()
  "Add budgets, sized from the usage so their meters read well."
  (let* ((month (harness-call 'usage/set-budget (list :scope 'period :period 'month :amount 60.0 :days 'all
                                                      :label "Monthly API spend")))
         (week (harness-call 'usage/set-budget (list :scope 'period :period 'week :amount 50.0 :hard t
                                                     :days 'business)))
         (web (harness-call 'usage/set-budget (list :scope 'project :target (expand-file-name "~/src/acme-web/")
                                                    :amount 50.0)))
         (spent (lambda (b) (plist-get (harness-call 'usage/budget-status (plist-get b :id)) :spent))))
    ;; Spent this month outside the harness, set by hand.
    (harness-call 'usage/set-budget (append (list :baseline (max 0.0 (- 24.6 (funcall spent month)))) month))
    ;; A hard budget stops turns: it leaves room for the world's own,
    ;; early in the week too, when the seeded spend is still small.
    (harness-call 'usage/set-budget (append (list :amount (max 5.0 (fceiling (/ (funcall spent week) 0.42)))) week))
    ;; In half dollars: past 80%, where its meter turns to a warning.
    (harness-call 'usage/set-budget (append (list :amount (max 1.0 (/ (fceiling (* 2 (/ (funcall spent web) 0.86))) 2)))
                                            web))))

(defun harness-media--age ()
  "Move the times of tasks and sessions back, as if the day had gone by."
  (let* ((tasks (plist-get harness-media--world :tasks))
         ;; Minutes ago: created (and started), finished, verified, refined.
         (plan '((:constant 180 171 140) (:python 1560 1556 1540) (:pagination 35 21) (:slow 110 41)
                 (:health 26) (:settings 12) (:openapi 4) (:csv 1190 nil nil 1188) (:retry 2900 nil nil 2897))))
    (pcase-dolist (`(,key ,created ,finished ,verified ,refined) plan)
      (let* ((id (plist-get tasks key))
             (task (harness-media--task id))
             (started (and (plist-get task :started) created)))
        (apply #'harness-tasks--set id
               (append (list :created (harness-media--ago created))
                       (and started (list :started (harness-media--ago started)))
                       (and finished (list :finished (harness-media--ago finished)))
                       (and verified (list :verified-at (harness-media--ago verified)))
                       (and refined (list :refined (harness-media--ago refined)))))
        (when-let* ((sid (plist-get task :session)))
          (harness-media--set-times sid created (or finished verified refined 1)))))
    ;; The branch waiting in the merge queue joined it when its work finished,
    ;; so its card reads "queued 21m ago" rather than "just now".
    (harness-tasks--set (plist-get tasks :pagination) :merge-queued (harness-media--ago 21))
    ;; The task in review was sent back an hour ago and handed its work in
    ;; again when it finished, so its report says that time too.  The report
    ;; must stay newer than the feedback, or it would speak for the round
    ;; before (`harness-tasks--handed-in-p').
    (let* ((id (plist-get tasks :slow))
           (task (harness-media--task id))
           (feedback (plist-get task :feedback)))
      (harness-tasks--set id
                          :feedback (append (butlast feedback)
                                            (list (plist-put (copy-sequence (car (last feedback)))
                                                             :at (harness-media--ago 60))))
                          :report (plist-put (copy-sequence (plist-get task :report)) :at (harness-media--ago 41))
                          :report-at (harness-media--ago 41)))
    (pcase-dolist (`(,key ,created ,updated)
                   '((:guide 2900 2870) (:flaky 5800 5790) (:ratelimit 7 0.2) (:fork 3 2) (:btw 1 0.5)
                     (:permission 9 8) (:question 15 14)))
      (harness-media--set-times (plist-get harness-media--world key) created updated))
    (pcase-dolist (`(,key ,minutes) '((:ratelimit 5) (:fork 2) (:btw 0.6)))
      (harness-media--age-nodes (plist-get harness-media--world key) minutes))
    (harness-ui-refresh-sessions)))

(defun harness-media--age-nodes (id minutes)
  "Move the nodes session ID made back, its newest to MINUTES ago."
  (let* ((s (gethash id harness-sessions))
         (table (aref s (cl-struct-slot-offset 'harness-session 'nodes)))
         (own nil))
    (maphash (lambda (node-id node) (when (equal (plist-get node :session) id) (push (cons node-id node) own)))
             table)
    (when own
      (let ((shift (- (apply #'max (mapcar (lambda (e) (or (plist-get (cdr e) :ts) 0)) own))
                      (harness-media--ago minutes))))
        (pcase-dolist (`(,node-id . ,node) own)
          (puthash node-id (plist-put (copy-sequence node) :ts (- (or (plist-get node :ts) 0) shift)) table))))))

(defun harness-media--set-times (id created updated)
  "Say session ID was created CREATED and updated UPDATED minutes ago.
Its last message is as old as that."
  (when-let* ((s (gethash id harness-sessions)))
    (aset s (cl-struct-slot-offset 'harness-session 'created) (harness-media--ago created))
    (aset s (cl-struct-slot-offset 'harness-session 'updated) (harness-media--ago updated))
    (aset s (cl-struct-slot-offset 'harness-session 'last-message) (harness-media--ago updated))))

(defconst harness-media--rates
  '(("claude:claude-fable-5-1" . 48.0) ("claude:claude-opus-5-5" . 41.0)
    ("claude:claude-sonnet-5" . 74.0) ("openrouter:openai/gpt-5" . 96.0))
  "Tokens per second each model of the world writes at, for the Avg tok/s column.")

(defun harness-media--seed-rates ()
  "Give every session the output it streamed and the seconds that took.
Every agent of the run is scripted and replays its turns in a blink, so
the usage module measured next to nothing (on a busy machine, a call or
two that happened to take longer, at a rate no model has).  The
pictures get the totals a session would have kept had it written at its
model's pace (`:stream-output' and `:stream-seconds' of its usage):
nine tenths of its output, over the time that takes at the pace plus or
minus four tokens a second, picked from the output so the sessions of
one model differ a little.  They replace what was measured."
  (maphash (lambda (id s)
             (let* ((slot (cl-struct-slot-offset 'harness-session 'usage))
                    (session (harness-media--session id))
                    (pace (cdr (assoc (plist-get session :model) harness-media--rates)))
                    (output (plist-get (plist-get session :usage) :output)))
               (when (and pace output (> output 0))
                 (let* ((streamed (round (* 0.9 output)))
                        (rate (+ pace (- (mod output 9) 4)))
                        (usage (plist-put (copy-sequence (aref s slot)) :stream-output streamed)))
                   (aset s slot (plist-put usage :stream-seconds (/ streamed rate)))))))
           harness-sessions))

(defun harness-media--build-world ()
  "Make everything the pictures show."
  (harness-media--log "building the demo project")
  (harness-media--make-project)
  (harness-media--make-harness-repos)
  (harness-media--seed-usage)
  (harness-media--seed-budgets)
  (harness-media--log "running the tasks")
  (harness-media--build-tasks)
  (harness-media--log "running the conversations")
  (harness-media--build-sessions)
  (harness-media--seed-rates)
  (harness-media--age)
  (harness-media--settle 1))

;;;; Taking pictures

(defun harness-media--reset-layout ()
  "Show one window, in a frame of the full size, with nothing harness in it."
  (ignore-errors (transient-quit-all))
  (dolist (w (window-list nil 'nomini))
    (when (and (window-live-p w) (window-parameter w 'window-side))
      (ignore-errors (delete-window w))))
  (delete-other-windows)
  (clrhash harness-ui--position-buffers)
  ;; Its overview's window is gone: no fullscreen layout is left either.
  (clrhash harness-ui--fullscreen-layouts)
  (switch-to-buffer (get-buffer-create "*scratch*"))
  (set-frame-size nil harness-media-columns harness-media-lines)
  (harness-media--settle 0.2))

(defun harness-media--show-file (file &optional from)
  "Visit FILE of the demo project in the selected window.
Show it from its first line matching the regexp FROM, else from its start."
  (find-file (harness-media--path file))
  (display-line-numbers-mode 1)
  (goto-char (point-min))
  (when from (re-search-forward from) (forward-line 0))
  (set-window-start nil (point)))

(defun harness-media--open-chat (id &optional position)
  "Show the chat of session ID in POSITION and wait until it is drawn."
  (let ((buffer (harness-ui-display-session id (or position 'right))))
    (harness-media--wait (lambda () (with-current-buffer buffer
                                      (and (not harness-chat--loading) harness-chat--order)))
                         20 "the chat to load")
    (harness-media--settle 0.5)
    buffer))

(defun harness-media--expand (buffer tool)
  "Expand the newest call of TOOL in the chat BUFFER."
  (with-current-buffer buffer
    (let (found)
      (maphash (lambda (id block)
                 (when (equal (plist-get (harness-chat-block-node block) :tool) tool)
                   (push (cons id block) found)))
               harness-chat--blocks)
      (when-let* ((newest (car (sort found (lambda (a b) (string> (car a) (car b)))))))
        (when (harness-chat-block-collapsed (cdr newest))
          (harness-chat-toggle-block (car newest)))))))

(defun harness-media--to-bottom (buffer)
  "Scroll the windows of chat BUFFER to its compose box."
  (dolist (w (get-buffer-window-list buffer nil t))
    (with-selected-window w (harness-chat-scroll-to-bottom))))

(defun harness-media--visible-text (start end)
  "Return the text between START and END that is not invisible."
  (let ((pos start) (parts nil))
    (while (< pos end)
      (let ((next (next-single-char-property-change pos 'invisible nil end)))
        (unless (invisible-p pos)
          (push (buffer-substring-no-properties pos next) parts))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(defun harness-media--window-text (window)
  "Return what WINDOW shows, with its header and mode lines, as text."
  (with-current-buffer (window-buffer window)
    (concat (format "=== %s [%s] %s, %d lines, text from %s takes %d screen lines\n"
                    (buffer-name) major-mode (window-pixel-edges window) (window-body-height window)
                    (if (= (window-start window) (point-min)) "the top" "below the top")
                    (count-screen-lines (point-min) (point-max) nil window))
            (if header-line-format (format "--- header: %s\n" (format-mode-line header-line-format nil window)) "")
            (harness-media--visible-text (window-start window) (or (window-end window t) (point-max)))
            (format "\n--- mode line: %s\n\n" (format-mode-line mode-line-format nil window)))))

(defun harness-media--capture (name)
  "Write the frame to NAME.png, and its text to NAME.txt when dumping."
  (message nil)
  (harness-media--settle 0.6)
  (redisplay t)
  (let ((data (x-export-frames nil 'png))
        (coding-system-for-write 'binary))
    (with-temp-file (expand-file-name (concat name ".png") harness-media-output)
      (set-buffer-multibyte nil)
      (insert data)))
  (when harness-media-dumps
    (with-temp-file (expand-file-name (concat name ".txt") harness-media-dumps)
      (insert (format "%dx%d pixels, %dx%d characters\n\n" (frame-pixel-width) (frame-pixel-height)
                      (frame-width) (frame-height)))
      (dolist (w (window-list nil 'nomini))
        (insert (harness-media--window-text w)))))
  (harness-media--log "wrote %s.png" name))

(defun harness-media--code-layout (id)
  "Show acme/ratelimit.py on the left and the chat of session ID on the right."
  (harness-media--reset-layout)
  (harness-media--show-file "acme/ratelimit.py" "^class TokenBucket")
  (let ((buffer (harness-media--open-chat id 'right)))
    (harness-media--expand buffer "bash")
    (harness-media--to-bottom buffer)
    buffer))

(defun harness-media--fullscreen-layout (task)
  "Show the board in the fullscreen layout, the session of TASK beside it.
TASK is a key of the world's tasks.  As a user would, the board opens
in the `fullscreen' position (C-u C-c h a, then fullscreen) and RET on
the task's card opens its session beside the board.  The frame is
`harness-media-hero-columns' wide, and as high as the session's last
round needs: from the message that started it to the compose box.
Return the session's chat buffer."
  (harness-media--reset-layout)
  (set-frame-size nil harness-media-hero-columns harness-media-lines)
  (harness-media--settle 0.3)
  (let ((default-directory harness-media-project)
        (id (plist-get (plist-get harness-media--world :tasks) task)))
    (harness-tasks harness-media-project 'fullscreen)
    (harness-media--settle 1.5)
    (let ((board (selected-window)))
      (with-current-buffer (window-buffer board)
        (harness-media--wait (lambda () (ignore-errors (harness-media--goto-task-card id) t))
                             15 "the task's card")
        (harness-ui-tasks-open))
      (let* ((chat (selected-window))
             (buffer (window-buffer chat)))
        (when (eq chat board) (error "The session did not open beside the board"))
        (harness-media--wait (lambda () (with-current-buffer buffer
                                          (and (not harness-chat--loading) harness-chat--order)))
                             20 "the chat to load")
        (harness-media--settle 1)
        ;; The last round starts at the last message the session was sent.
        (harness-media--fit (with-current-buffer buffer
                              (count-screen-lines (save-excursion
                                                    (goto-char (point-max))
                                                    (re-search-backward "^You$"))
                                                  (point-max) nil chat)))
        (harness-media--to-bottom buffer)
        ;; The board from its top, point still on the card.
        (set-window-start board (with-current-buffer (window-buffer board) (point-min)))
        (harness-media--settle 0.5)
        buffer))))

(defun harness-media-shot-chat ()
  "The first picture: the board in the fullscreen layout, a task beside it.
The task is in review after it was sent back once: its session shows
the feedback, the work that answered it, the report handed in again
and the review banner."
  (harness-media--fullscreen-layout :slow)
  (harness-media--capture "chat"))

(defun harness-media-shot-chat-permission ()
  "A chat waiting for permission to run a command."
  (harness-media--chat-shot (plist-get harness-media--world :permission) "acme/webhooks.py")
  (harness-media--capture "chat-permission"))

(defun harness-media-shot-chat-question ()
  "A chat waiting for the answer to a question."
  (harness-media--chat-shot (plist-get harness-media--world :question) "acme/app.py")
  (harness-media--capture "chat-question"))

(defun harness-media-shot-chat-cowboy ()
  "A chat whose prompt cache went cold overnight, a message waiting on it.
The session talked pagination yesterday; today another session's agent
writes to it, and the message waits on what goes first.  The session is
made here and deleted after, so no other picture shows it, and the
picture is taken after every picture of usage, so its usage counts in
none of theirs."
  (let* ((id (harness-media--new-session :name "Paginate the orders list" :model "claude:claude-opus-5-5"
                                         :permission-mode 'accept-edits))
         (sender (harness-media--session (plist-get harness-media--world :ratelimit))))
    (dolist (node `((:kind user :content "GET /orders sends every order in one response, and the mobile app times out on big accounts. How should we paginate it?")
                    (:kind assistant :content ,(concat "Two ways fit `list_orders` in `acme/orders.py`:\n\n"
                                                       "- **Page numbers** (`?page=2&per_page=50`): simple, and a client can jump to a page, but an order created while someone reads shifts every page after it.\n"
                                                       "- **A cursor** (`?after=<id>&limit=50`): stable while orders arrive, since ids only grow, but no jumping.\n\n"
                                                       "`ORDERS` only ever grows, with increasing ids, so a cursor costs one comparison. I'd take the cursor."))
                    (:kind user :content "Let's sleep on it and pick it up tomorrow.")
                    (:kind assistant :content "Sure. Nothing is changed yet: say which when you're back, and I'll implement it with tests.")))
      (harness-call 'session/append id node))
    (harness-call 'session/usage-add id (list :input 200 :output 900 :cache-read 36000 :cache-write 2000 :context 38200
                                             :cache-at (harness-media--ago (* 60 27))))
    (harness-media--set-times id (* 60 28) (* 60 27))
    (harness-media--age-nodes id (* 60 27))
    (harness-call 'agent/prompt id
                  (format "[Message from session %s %S]\n\n%s" (plist-get sender :id) (plist-get sender :name)
                          (concat "Go with the cursor: my limiter counts GET /orders per key, and ?after=<id> lets a"
                                  " client walk every order without page drift. Can you implement it?"))
                  (list :from (harness-sender-session sender)))
    (harness-media--wait (lambda () (and (harness-call 'cowboy/asking id) (harness-ui-cowboy-waiting-p id)))
                         15 "the cold-cache question")
    (let ((buffer (harness-media--chat-shot id "acme/orders.py")))
      (harness-media--wait (lambda () (with-current-buffer buffer
                                        (text-property-not-all (point-min) (point-max) 'harness-ui-cowboy-panel nil)))
                           15 "the cold-cache panel")
      ;; Fitted again, the panel drawn.
      (harness-media--chat-shot id "acme/orders.py"))
    (harness-media--capture "chat-cowboy")
    (harness-call 'agent/cancel id)
    (harness-media--wait (lambda () (not (harness-call 'agent/running id))) 15 "the turn to end")
    (harness-call 'session/delete id)))

;;;; Lasting decisions

(defun harness-media--decisions-script (_request)
  "The turn of the decisions pictures' sessions: a command a rule may deny."
  (list (harness-media--say "The artefacts in build/ are from the last release; I'll clear them out first.\n")
        (harness-media--tool "bash" :command "rm -rf build/")
        (harness-media--say "That command is denied, so build/ stays as it is; the release script rebuilds it anyway.")))

(defun harness-media--step (name)
  "Take the picture NAME of a step between two pictures, when they are wanted.
They are when HARNESS_MEDIA_STEPS is set: a picture made of clicks then
shows each of them, for a reviewer, while `scripts/media.sh' keeps only
the one picture the docs show."
  (let ((wanted (getenv "HARNESS_MEDIA_STEPS")))
    (when (and wanted (not (string-empty-p wanted)))
      (harness-media--capture name))))

(defun harness-media--shows (buffer text)
  "Non-nil when BUFFER shows TEXT."
  (with-current-buffer buffer
    (save-excursion (goto-char (point-min)) (search-forward text nil t))))

(declare-function harness-chat-push "harness-ui-chat" ())

(defun harness-media--push (buffer label)
  "Push the last button LABEL of chat BUFFER, as a click there would."
  (with-current-buffer buffer
    (goto-char (point-max))
    (unless (search-backward label nil t)
      (error "No %s in %s" label (buffer-name)))
    (forward-char 1)
    (harness-chat-push))
  (harness-media--settle 0.5))

(defun harness-media--both (buffers text what)
  "Wait until every chat of BUFFERS shows TEXT, described as WHAT."
  (harness-media--wait (lambda () (cl-every (lambda (b) (harness-media--shows b text)) buffers)) 15 what)
  (harness-media--settle 0.5))

(defun harness-media--pair (left right)
  "Show the chats of sessions LEFT and RIGHT side by side, fitted; return them.
The value is the list of the two chat buffers."
  (harness-media--reset-layout)
  (let* ((lb (harness-media--notes-open left 'full "the left chat"))
         (rb (harness-media--notes-open right 'right "the right chat")))
    (harness-media--fit (max (harness-media--text-lines (get-buffer-window lb))
                             (harness-media--text-lines (get-buffer-window rb)))
                        24 40)
    (harness-media--to-bottom lb)
    (harness-media--to-bottom rb)
    (harness-media--settle 0.5)
    (list lb rb)))

(defun harness-media-shot-chat-decisions ()
  "A lasting permission answer in one chat, a call it denied in another.
The left session's agent asked to run a command and was answered
\"Always deny\": its note says so.  The right session's agent ran the
same command later, and the rule denied it: its call says which
answer decided it.  [Undo] was clicked on the right, so both offer
[Redo] now, the answer struck through, and the echo area says what the
undo did.  With HARNESS_MEDIA_STEPS, the pictures before the click and
after a [Redo] on the left are taken too.  The answer is undone and the
sessions are deleted after, so no other picture shows them."
  (let ((answered (harness-media--new-session :name "Prepare the 2.4 release" :model "claude:claude-sonnet-5"
                                              :permission-mode 'ask))
        (denied (harness-media--new-session :name "Tidy the repository" :model "claude:claude-sonnet-5"
                                            :permission-mode 'ask)))
    (harness-media--prompt answered "Clear out the old build before the release." '(blocked))
    (let ((request (car (harness-call 'permission/pending answered))))
      (harness-call 'permission/answer answered (plist-get request :id) "deny-always"))
    (harness-media--wait-status answered '(idle))
    (harness-media--prompt denied "The old build is stale: clear it out.")
    (pcase-let ((`(,lb ,rb) (harness-media--pair answered denied)))
      (harness-media--both (list lb rb) "[Undo]" "both chats to offer [Undo]")
      (harness-media--step "chat-decisions-before")
      (harness-media--push rb "[Undo]")
      (harness-media--both (list lb rb) "[Redo]" "both chats to offer [Redo]")
      (harness-media--capture "chat-decisions")
      (harness-media--push lb "[Redo]")
      (harness-media--both (list lb rb) "[Undo]" "both chats to offer [Undo] again")
      (harness-media--step "chat-decisions-redone"))
    ;; The rule goes with the pictures: the ones after run commands.
    (dolist (decision (harness-call 'decision/list :kind 'permission :state 'done))
      (harness-call 'decision/undo (plist-get decision :id)))
    (dolist (id (list answered denied)) (harness-call 'session/delete id))))

(defun harness-media--cold-session (name question answer)
  "Create session NAME whose prompt cache went cold half an hour ago.
It talked QUESTION and ANSWER before then."
  (let ((id (harness-media--new-session :name name :model "claude:claude-opus-5-5" :permission-mode 'accept-edits)))
    (harness-call 'session/append id (list :kind 'user :content question))
    (harness-call 'session/append id (list :kind 'assistant :content answer))
    (harness-call 'session/usage-add id (list :input 200 :output 900 :cache-read 36000 :cache-write 2000 :context 38200
                                             :cache-at (harness-media--ago (* 60 27))))
    (harness-media--set-times id (* 60 28) (* 60 27))
    (harness-media--age-nodes id (* 60 27))
    id))

(defun harness-media-shot-chat-decisions-cold ()
  "An \"always\" cold-cache answer in one chat, the default it set in another.
The left session's cache went cold and the question was answered
\"always\" start afresh: its note offers [Undo].  The right session's
cache went cold too, and nobody was asked: its note says the default
went first and which answer decided that, with the same [Undo].  With
HARNESS_MEDIA_STEPS, the pictures after an [Undo] on the right and a
[Redo] on the left are taken too.  The answer is undone after, asking
again with the brief summary the default, and the sessions are deleted."
  (let ((answered (harness-media--cold-session
                   "Paginate the orders list" "GET /orders sends every order at once. How should we paginate it?"
                   "A cursor (`?after=<id>&limit=50`) stays stable while orders arrive. Say when, and I'll implement it."))
        (unasked (harness-media--cold-session
                  "Export orders as CSV" "Finance wants the orders as CSV. Where should the export live?"
                  "A `GET /orders.csv` beside the JSON listing, streaming rows. I'll write it when you say.")))
    (harness-call 'agent/prompt answered "Go with the cursor, please.")
    (harness-media--wait (lambda () (harness-call 'cowboy/asking answered)) 15 "the cold-cache question")
    (harness-call 'question/answer answered (harness-call 'cowboy/asking answered) (list :answer "always start afresh"))
    (harness-media--wait-status answered '(idle))
    (harness-media--prompt unasked "Write the CSV export now.")
    (pcase-let ((`(,lb ,rb) (harness-media--pair answered unasked)))
      (harness-media--both (list lb rb) "[Undo]" "both chats to offer [Undo]")
      (harness-media--capture "chat-decisions-cold")
      (harness-media--push rb "[Undo]")
      (harness-media--both (list lb rb) "[Redo]" "both chats to offer [Redo]")
      (harness-media--step "chat-decisions-cold-undone")
      (harness-media--push lb "[Redo]")
      (harness-media--both (list lb rb) "[Undo]" "both chats to offer [Undo] again")
      (harness-media--step "chat-decisions-cold-redone"))
    (dolist (decision (harness-call 'decision/list :kind 'cowboy :state 'done))
      (harness-call 'decision/undo (plist-get decision :id)))
    (dolist (id (list answered unasked)) (harness-call 'session/delete id))))

;;;; The task slots page

(defconst harness-media--slot-queue
  '(("returns: add POST /orders/{id}/refund, refunding a paid order in full or in part" "high" 2.5)
    ("add an index on orders.customer_id: the customer page scans the whole table" "high" 1)
    ("add DELETE /orders/{id}, which cancels an order that has not shipped yet" "medium" 15)
    ("rename the created column of orders to created_at, with a migration" "low" 48))
  "The tasks of the slots picture that wait for a slot: (PROMPT PRIORITY MINUTES).
Each joined the queue MINUTES ago.")

(defconst harness-media--slot-waits
  '((:constant 180 0 "medium") (:python 1560 6 "medium") (:slow 110 9 "medium")
    (:pagination 35 5 "high") (:health 26 25 "low") (:settings 12 1 "high")
    (:openapi 4 16 "medium") (:compress 2 1 "high"))
  "How long the tasks of the slots picture waited for their slot.
Each is (KEY STARTED WAITED PRIORITY): the task of KEY started STARTED
minutes ago, as `harness-media--age' has it, after waiting WAITED
minutes at PRIORITY.  The times agree with the queue's: no task started
while one above it, or one older at its level, waited.")

(defun harness-media--slot-titles ()
  "Return the titles the scripted naming gives the slots picture's new tasks."
  (mapcar (lambda (prompt)
            (cdr (cl-find-if (lambda (entry) (string-match-p (car entry) prompt)) harness-media--titles)))
          (cons "gzip" (mapcar #'car harness-media--slot-queue))))

(defun harness-media--fill-slots ()
  "Give the demo project four slots, every one held, and four tasks waiting.
The three tasks at work hold three slots, a fourth task starts and takes
the last, and four more wait for one, at every priority
\(`harness-media--slot-queue').  Their times are moved back, and each
task that started gets the wait such a limit would have made it
\(`harness-media--slot-waits'), which the page sums by priority."
  (setq harness-tasks-max-running 4)
  (let* ((tasks (plist-get harness-media--world :tasks))
         (compress (harness-media--submit "gzip responses larger than 1 KB when the client accepts gzip"))
         (all (append (list :compress compress) tasks)))
    (harness-media--wait-task compress
                              (lambda (task)
                                (let ((session (harness-ui-session (plist-get task :session))))
                                  (cl-some (lambda (todo) (equal (plist-get todo :status) "done"))
                                           (plist-get session :todos))))
                              "to get going")
    (pcase-dolist (`(,prompt ,priority ,minutes) harness-media--slot-queue)
      (let ((id (harness-media--submit prompt :priority priority)))
        (harness-media--wait-task id (lambda (task) (equal (harness-media--column task) "pending"))
                                  "to wait for a slot")
        (harness-tasks--set id :created (harness-media--ago minutes) :queued-at (harness-media--ago minutes))))
    (pcase-dolist (`(,key ,started ,waited ,priority) harness-media--slot-waits)
      (let ((id (plist-get all key)))
        (when (eq key :compress)
          (harness-tasks--set id :created (harness-media--ago (+ started waited))
                              :started (harness-media--ago started)))
        (harness-tasks--set id :waits (list (list :at (harness-media--ago started)
                                                  :seconds (* 60.0 waited) :priority priority)))))
    ;; The tasks at work at three levels, set on their sessions.
    (pcase-dolist (`(,key ,priority) '((:settings "high") (:compress "high") (:health "low")))
      (harness-call 'priority/set (plist-get (harness-media--task (plist-get all key)) :session) priority))
    ;; Named as a task is while it waits, beside everything else.
    (let ((titles (harness-media--slot-titles)))
      (harness-media--wait (lambda ()
                             (let* ((slots (harness-call 'task/slots harness-media-project))
                                    (shown (mapcar (lambda (entry) (plist-get entry :title))
                                                   (append (plist-get slots :holders) (plist-get slots :queue)))))
                               (cl-every (lambda (title) (member title shown)) titles)))
                           30 "the new tasks to be named"))))

(defun harness-media-shot-slots ()
  "The task slots page: four slots held at three priorities, four tasks waiting."
  (harness-media--fill-slots)
  (harness-media--view (lambda () (harness-slots harness-media-project))
                       (lambda ()
                         (let ((buffer (current-buffer)))
                           (harness-media--wait (lambda () (buffer-local-value 'harness-ui-slots--data buffer))
                                                10 "the slots page to load"))
                         (goto-char (point-min))))
  (harness-media--capture "slots"))
(defun harness-media--denied-call (id)
  "Return the newest refused call of session ID, or nil.
That is its tool result whose `:meta' says `:denied', the node the
user's approval is written into and its handle, the call's id."
  (car (last (cl-remove-if-not
              (lambda (n) (and (equal (format "%s" (plist-get n :kind)) "tool-result")
                               (harness-json-true-p (plist-get (plist-get n :meta) :denied))))
              (harness-call 'session/nodes id)))))

(defun harness-media--chat-denied (approve)
  "Run the refused-command turn of a session and show its chat.
The session's own rule refuses commands, so its `python3 -m unittest'
call is denied and offers [Approve].  With APPROVE, the user approves
that call: the agent is told, reruns it unchanged with `rerun_approved',
and the chat shows the rerun under the call it was refused as.  Return
the chat buffer."
  (harness-media--reset-layout)
  (let* ((id (harness-media--new-session :name "Baseline the webhooks suite"
                                         :model "claude:claude-sonnet-5"
                                         :permission-mode 'ask))
         (buffer nil))
    ;; The picture's rule: this session does not run commands.
    (harness-perms-add-rule id '(:tool "bash" :behavior deny) 'session)
    (harness-media--prompt id "Before I change acme/webhooks.py, run the suite for a baseline; then install httpx and pool the connections.")
    (let ((denied (harness-media--denied-call id)))
      (unless denied (error "The session's command was not refused"))
      (setq buffer (harness-media--open-chat id 'full))
      (when approve
        (harness-call 'permission/approve-denied id (plist-get denied :call-id))
        (harness-media--wait (lambda () (not (eq (harness-media--status id) 'idle))) 15
                             "the rerun to start")
        (harness-media--wait-status id '(idle))))
    (harness-media--expand buffer "bash")
    (when approve (harness-media--expand buffer "rerun_approved"))
    (harness-media--to-bottom buffer)
    (harness-media--fit (harness-media--text-lines (selected-window)) 26)
    (harness-media--settle 1)
    buffer))

(defun harness-media-shot-chat-denied ()
  "A call the harness refuses, with the [Approve] that lets it run anyway.
The session's rule refuses commands; the denial names the handle and the
chat offers the user's approval, which no permission mode, rule or
judge can deny.  Taken last: its session would count in the usage
pictures."
  (harness-media--chat-denied nil)
  (harness-media--capture "chat-denied"))

(defun harness-media-shot-chat-denied-approved ()
  "That call after the user approved it: rerun exactly as it was refused.
The chat shows the call marked user-approved, the agent's
`rerun_approved' call under it with what the command printed, and the
handle linking the two."
  (harness-media--chat-denied t)
  (harness-media--capture "chat-denied-approved"))

;;;; The access view

(defconst harness-media--access-prompt
  "Audit how API keys are checked, offline: read acme/auth.py and the key rotation notes in ~/src/acme-ops, then run the auth tests under strace to see which files they open."
  "What the access picture's session is asked.")

(defconst harness-media--rotation-notes "# Rotating API keys

1. Add the new key to `ACME_API_KEYS`, beside the old one.
2. Deploy, and move the clients over.
3. Drop the old key and deploy again.
"
  "The ops notes the access picture's session may read but not write.")

(defun harness-media--access-ops ()
  "Return the ops directory the access picture's session may only read."
  (expand-file-name "~/src/acme-ops/"))

(defun harness-media--access-script (_request)
  "The turn of the access picture's session: an audit kept to its jail.
It gives the network up itself (`drop_access'), reads the project and
the ops notes it may only read, is refused the web it gave up and the
sub-agents the user turned off, and waits for the user on the test run,
which it traces with the capability the user gave its commands."
  (list
   (harness-media--think "An audit of the key checks needs nothing from the network, so I give it up first: what I read cannot leave this machine.")
   (harness-media--tool "drop_access" :attribute "network" :reason "an audit of the key checks needs no network")
   (harness-media--tool "read_file" :path "acme/auth.py")
   ;; As a model writes it: no path of this machine's in the picture.
   (harness-media--tool "read_file" :path "~/src/acme-ops/rotation.md")
   (harness-media--tool "web_fetch" :url "https://docs.python.org/3/library/hmac.html")
   (harness-media--say "The key check compares with `==`. A sub-agent could time it while I read on.")
   (harness-media--tool "spawn_agent" :prompt "Time acme/auth.py's key check for keys that differ early and late."
                        :name "time the key check")
   (harness-media--say "Sub-agents are off for this session, so I run the auth tests myself, traced.")
   (harness-media--tool "bash" :command "strace -f -e trace=openat python3 -m unittest tests.test_auth")))

(defun harness-media--access-session ()
  "Make the access picture's session, set up as a jail, and run its turn.
The user lets it read the ops notes, not write them, turns its
sub-agents off and gives its commands the capability to trace
processes (CAP_SYS_PTRACE), as the view's buttons do; the turn stops on
the test run, waiting for the user.  Where the sandbox cannot pass a
capability on, the capability is left out and the view says none.
Return the session's id."
  (let ((id (harness-media--new-session :name "Audit the API key checks"
                                        :model "claude:claude-sonnet-5"
                                        :permission-mode 'ask))
        (ops (harness-media--access-ops)))
    (make-directory ops t)
    (with-temp-file (expand-file-name "rotation.md" ops) (insert harness-media--rotation-notes))
    (harness-call 'access/add-read-dir id ops)
    (harness-call 'access/set-tool id "spawn_agent" :false)
    ;; What the jail cannot enforce (no bwrap here, a macOS) is no error of the picture.
    (condition-case err
        (harness-call 'access/set-capability id "CAP_SYS_PTRACE" t)
      (error (message "media: no capability for the access picture: %s" (harness-error-message err))))
    ;; Idle too: where no sandbox confines bash, the network given up
    ;; takes it away, and the turn ends refused instead of waiting.
    (harness-media--prompt id harness-media--access-prompt '(blocked idle))
    id))

(defun harness-media--access-view (id)
  "Show the access view of session ID in the whole frame; return its buffer."
  (harness-media--view (lambda () (harness-access id))
                       (lambda ()
                         (let ((buffer (current-buffer)))
                           (harness-media--wait
                            (lambda () (with-current-buffer buffer
                                         (and harness-ui-access--describe harness-ui-access--judgements
                                              (harness-ui-access--find-anchor '(section . judgements)))))
                            15 "the access view to load"))))
  (window-buffer))

(defun harness-media--access-shot (name judgements)
  "Take picture NAME of the access view of a session kept to a jail.
With JUDGEMENTS the view is scrolled to the judgements of its calls, the
agent's own drop_access unfolded; else it shows from the top.  The
session is made here and deleted after, so no other picture shows it.
The view names the harness's own code, which every session may read: it
is taken for straight's build of it in the scratch HOME and the clone
that build links to, as in the version picture, so no path of this
machine's shows.  Only those directories are taken for others:
`harness-directory' stays, which the tools are read from."
  (let ((id (harness-media--access-session)))
    (cl-letf* (((symbol-function 'harness-perms--harness-code-dirs)
                (lambda () (let ((paths (harness-media--harness-paths)))
                             (list (plist-get paths :build) (plist-get paths :clone)))))
               (buffer (harness-media--access-view id)))
      (when judgements (harness-media--expand buffer "drop_access"))
      (with-current-buffer buffer
        (let ((pos (if judgements (harness-ui-access--find-anchor '(section . judgements)) (point-min))))
          (goto-char pos)
          (set-window-start (selected-window) pos)))
      (harness-media--capture name)
      (harness-call 'agent/cancel id)
      (harness-media--wait (lambda () (not (harness-call 'agent/running id))) 15 "the turn to end")
      (harness-call 'session/delete id)
      ;; Gone with its session: the next picture's view takes its name.
      (kill-buffer buffer))))

(defun harness-media-shot-access ()
  "The access view of a session kept to a jail, from the top.
The sandbox and mode, the network the agent gave up, the capability the
user gave its commands, the directories (the ops notes read-only), the
tools (the web gone with the network the agent gave up, sub-agents
turned off by the user), the rules and the request waiting on the user."
  (harness-media--access-shot "access" nil))

(defun harness-media-shot-access-judgements ()
  "The judgements of that session's calls, in its access view.
Each call drawn as the chat draws it, under what was decided, by whom and
its handle; the refused ones offer [Approve], and the agent's own
drop_access is unfolded."
  (harness-media--access-shot "access-judgements" t))

(defun harness-media--notes-child (parent)
  "Return the sub-agent session PARENT sent to run the checks, once it exists."
  (harness-media--wait
   (lambda ()
     ;; The permission judge's verdicts on the parent's calls are internal
     ;; sessions with the same parent (`session/internal-start'): not it.
     (let ((session (cl-find-if-not
                     (lambda (s) (equal (format "%s" (plist-get s :kind)) "internal"))
                     (harness-call 'session/list (list :parent-id parent)))))
       (and session (plist-get session :id))))
   30 "the sub-agent session"))

(defun harness-media--notes-call (session-id)
  "Return the note under the running call of SESSION-ID, or nil.
That is what the call says of itself (`tools/note'), as the chat draws
it under the call's block, rather than what a watcher of the session
makes of it."
  (let ((activity (harness-tools-session-activity session-id)))
    (cl-some (lambda (call) (and (stringp (plist-get call :note)) (plist-get call :note)))
             (plist-get activity :calls))))

(defun harness-media--notes-recap (child recap)
  "Give CHILD the recap RECAP its note shows, as the recap module would.
The module is off for the run (see `harness-media--setup-harness'), so
the picture's recap is hand written, as the tasks' are."
  (require 'harness-recap)
  (puthash child (list :recap recap :recap-at (float-time) :recap-turns 3 :recap-tools 6
                       :started (float-time))
           harness-recap--sessions))

(defun harness-media--notes-open (id position what)
  "Show session ID's chat in POSITION, waiting for it to load, as WHAT."
  (let ((buffer (harness-ui-display-session id position)))
    (harness-media--wait (lambda () (with-current-buffer buffer
                                      (and (not harness-chat--loading) harness-chat--order)))
                         20 (format "%s's chat to load" what))
    (harness-media--settle 0.5)
    buffer))

(defun harness-media-shot-notes ()
  "The sub-agents panel of a chat, and the note under its child's call.
A session sends a sub-agent to run the check suite in a loop, still at
it when the picture is taken.  The session's chat lists the child in
the panel above its compose box -- its name as a link, how long its
turn has gone on and what it does now -- and the child's chat beside it
shows the note under its own `bash' call: still running, the lines it
has written and the latest of them.  The note of the `spawn_agent' call
itself is not in the picture: that call returned as soon as the child
started, and a note goes with its call."
  (harness-media--reset-layout)
  (let* ((parent (harness-media--new-session :name "Check the orders suite"
                                             :model "claude:claude-opus-5-5"
                                             ;; The judge allows the sub-agent and
                                             ;; the child's command; nothing waits.
                                             :permission-mode 'auto)))
    (harness-media--prompt parent "How are the checks looking? Let a sub-agent run them and tell me." '(running))
    (let* ((child (harness-media--notes-child parent))
           (pbuf (harness-media--notes-open parent 'full "the session"))
           (cbuf (harness-media--notes-open child 'right "the sub-agent")))
      (harness-media--notes-recap child "Running the check suite in a loop; every run has passed so far")
      (harness-media--wait
       (lambda ()
         (and (string-match-p "recap:" (or (harness-tools-session-note child (list :recap t)) ""))
              (string-match-p "lines so far" (or (harness-media--notes-call child) ""))
              ;; The panel the session's chat pins above its compose box.
              (with-current-buffer pbuf
                (string-match-p "Sub-agents  1 running" (buffer-string)))))
       60 "the notes under the calls and the sub-agents panel")
      ;; Fitted to what the two chats show, the panel drawn.
      (harness-media--fit (max (harness-media--text-lines (get-buffer-window pbuf))
                               (harness-media--text-lines (get-buffer-window cbuf)))
                          nil 40)
      (harness-media--to-bottom pbuf)
      (harness-media--to-bottom cbuf)
      (harness-media--settle 1)
      (harness-media--capture "notes"))))

;;;; Answering a reply inline

(defconst harness-media--quote-question
  "Failed webhooks are dropped after one try. How should we retry them?"
  "What the quote-reply picture's session is asked; its script answers it.")

(defun harness-media--quote-script (_request)
  "The reply the quote-reply picture answers inline: three paragraphs.
The first is short, the second long enough to elide the middle of, the
third a question for the user."
  (list
   (harness-media--say "Yes, and the request path can stay as it is: `notify()` already returns the URLs that failed, so `create_order()` can keep those deliveries and try them again later, each time a little further apart.

Keep each failed delivery in a `webhook_retries` table: the order, the URL, how many attempts it had and when the next one is due. A background thread, started with the application, wakes every ten seconds, takes the rows that are due and posts them again with the same 5 second timeout, waiting 1, 2, 4, 8 minutes and so on between attempts. Once an hour has passed since the order was placed, a delivery that still fails is marked as given up, so a subscriber that is gone for good costs a row, not a thread.

One decision is yours: should a delivery that gave up be reported somewhere, or only logged?")))

(defun harness-media--keys (keys)
  "Press KEYS, a `kbd' string, in the selected window, as a user would.
They go through the command loop, so the keymaps, the minor modes and
their hooks act as they do for a user at the keyboard."
  (execute-kbd-macro (kbd keys))
  (harness-media--settle 0.2))

(defun harness-media--type (text)
  "Type TEXT in the selected window, a key a character."
  (execute-kbd-macro text)
  (harness-media--settle 0.2))

(defun harness-media--box-goto (regexp &optional end)
  "Move point to where REGEXP matches in the compose box, or to its END.
Signal an error naming the box's text when it does not match: the keys
before did not do what the picture needs."
  (goto-char harness-compose-start)
  (unless (re-search-forward regexp harness-compose-end t)
    (error "The compose box does not match %S: %S" regexp (harness-compose-text)))
  (goto-char (if end (match-end 0) (match-beginning 0))))

(defun harness-media--box-expect (regexp)
  "Signal an error unless the text of the compose box matches REGEXP."
  (unless (string-match-p regexp (harness-compose-text))
    (error "The compose box does not match %S: %S" regexp (harness-compose-text))))

(defun harness-media-shot-quote-reply ()
  "A reply of the agent's quoted in the compose box and answered inline.
The session is asked how to retry failed webhooks and answers in three
paragraphs.  Then, with the keys a user presses in the box: C-c > quotes
the whole reply; C-SPC at the start of the long paragraph's middle and
C-c [ at its end elide it as [...], keeping the front and the end of
that paragraph for context; M-RET splits the quote after the paragraph,
for an answer typed under what is above; and the last paragraph, the
question, is answered under it.  Point ends in the box, after the second
answer.  The session is made here and deleted after, so no other
picture shows it."
  (let ((id (harness-media--new-session :name "Design the webhook retries"
                                        :model "claude:claude-opus-5-5"
                                        :permission-mode 'accept-edits)))
    (harness-media--prompt id harness-media--quote-question)
    (let* ((buffer (harness-media--chat-shot id "acme/webhooks.py"))
           (chat (get-buffer-window buffer))
           (code (car (delq chat (window-list nil 'nomini)))))
      (select-window chat)
      (with-current-buffer buffer
        ;; From the box, C-c > quotes the agent's last reply, whole.
        (goto-char harness-compose-end)
        (harness-media--keys "C-c >")
        (harness-media--box-expect "\\`> Yes, and the request path")
        ;; The middle of the long paragraph: from "A background thread"
        ;; through "between attempts."  The region is the user's, from
        ;; C-SPC to where point is.
        (harness-media--box-goto "A background thread")
        (harness-media--keys "C-SPC")
        (harness-media--box-goto "between attempts\\." t)
        (unless (region-active-p) (error "C-SPC did not start a region"))
        (harness-media--keys "C-c [")
        (harness-media--box-expect "is due\\. \\[\\.\\.\\.\\] Once an hour")
        ;; M-RET at the end of that paragraph splits the quote there: the
        ;; question stays a quote of its own, and point is on the empty
        ;; line between them.
        (harness-media--box-goto "not a thread\\." t)
        (harness-media--keys "M-RET")
        (harness-media--box-expect "not a thread\\.\n\n\n\n> One decision is yours")
        (harness-media--type "Agreed, but give up after six hours, not one: our partners' maintenance windows are long.")
        ;; The question, answered under it.
        (goto-char harness-compose-end)
        (harness-media--type "Only logged for now. One warning when a delivery gives up is enough.")
        (harness-media--box-expect "long\\.\n\n> One decision is yours.*\n\nOnly logged for now\\."))
      ;; The box has grown: the frame fits the chat as it stands.
      (harness-media--fit (max (harness-media--text-lines chat) (harness-media--text-lines code)) 30)
      (harness-media--to-bottom buffer)
      (harness-media--capture "quote-reply"))
    (harness-call 'session/delete id)))

(defun harness-media-shot-quote-thread ()
  "A reply quoted in the compose box with the thread it answers.
The session is a short exchange about webhooks: the agent says a failed
delivery is retried once, the user answers both parts of that inline,
and the agent answers that it changed them.  From the box, C-c > quotes
the agent's answer, and under it the reply it answers, one level
deeper: what that reply quoted is deeper still, so the thread's replies
quote each other and it reads back in order.  The agent's line is split
with M-RET there and the user's answer typed under it.  Point ends in
the box, after the answer.  The session is made here and deleted after,
so no other picture shows it."
  (let ((id (harness-media--new-session :name "Retry failed webhooks"
                                        :model "claude:claude-opus-5-5"
                                        :permission-mode 'accept-edits)))
    (harness-call 'session/append id
                  (list :kind 'user :content "How long do we wait before retrying a failed webhook?"))
    (harness-call 'session/append id
                  (list :kind 'assistant :content "A failed delivery is retried once, 30 seconds later.\n\nIf it fails again it is logged and dropped."))
    (harness-call 'session/append id
                  (list :kind 'user :content "> A failed delivery is retried once, 30 seconds later.\n\nMake it three tries.\n\n> If it fails again it is logged and dropped.\n\nLog the URL too."))
    (harness-call 'session/append id
                  (list :kind 'assistant :content "Changed: three tries, 30 seconds apart, and the URL is in the log line."))
    (let* ((buffer (harness-media--chat-shot id "acme/webhooks.py"))
           (chat (get-buffer-window buffer))
           (code (car (delq chat (window-list nil 'nomini)))))
      (select-window chat)
      (with-current-buffer buffer
        ;; From the box, C-c > quotes the agent's last reply and, under
        ;; it, the inline reply it answers, the agent's message that
        ;; reply quoted under that.
        (goto-char harness-compose-end)
        (harness-media--keys "C-c >")
        (harness-media--box-expect "\\`> Changed: three tries")
        (harness-media--box-expect "> > > A failed delivery is retried once, 30 seconds later\\.")
        (harness-media--box-expect "> > Log the URL too\\.")
        ;; The agent's line answered: M-RET splits the quote there, and
        ;; the answer goes on the empty line under it.
        (harness-media--box-goto "Changed: three tries[^\n]*" t)
        (harness-media--keys "M-RET")
        (harness-media--box-expect "log line\\.\n\n\n\n> > > A failed delivery")
        (harness-media--type "Good. Ship it with the release.")
        (harness-media--box-expect "log line\\.\n\nGood\\. Ship it with the release\\."))
      ;; The box has grown: the frame fits the chat as it stands.
      (harness-media--fit (max (harness-media--text-lines chat) (harness-media--text-lines code)) 30)
      (harness-media--to-bottom buffer)
      ;; Scrolling put point at the box's end; the picture has it after
      ;; the answer typed under the agent's line.
      (with-current-buffer buffer
        (harness-media--box-goto "Good\\. Ship it with the release\\." t))
      (harness-media--capture "quote-thread"))
    (harness-call 'session/delete id)))

(defun harness-media--text-lines (window)
  "Return how many lines the text of WINDOW's buffer takes in WINDOW.
Images taller than a line count as they are drawn; the padding that
keeps a compose box at the bottom of a window does not count."
  (harness-compose-repad window)
  (with-current-buffer (window-buffer window)
    (ceiling (cdr (window-text-pixel-size window (point-min) (point-max) nil 100000))
             (frame-char-height))))

(defun harness-media--fit (lines &optional least most)
  "Make the frame LINES of text high, plus its header, mode and echo lines.
A line to spare holds the empty line a chat keeps under its compose box.
Keep it between LEAST (default 12) and MOST (default
`harness-media-lines') lines.  The frame keeps its width."
  (set-frame-size nil (frame-width)
                  (min (or most harness-media-lines) (max (or least 12) (+ lines 5))))
  (harness-media--settle 0.5))

(defun harness-media--view (open &optional then most)
  "Call OPEN, which shows a view, with the view taking the whole frame.
THEN, when given, runs next in the view's buffer.  The frame is then
made as high as the view's text, up to MOST lines."
  (harness-media--reset-layout)
  (let ((default-directory harness-media-project)
        (harness-ui-default-position 'full))
    (funcall open))
  (harness-media--settle 1.5)
  (delete-other-windows)
  (when then
    (with-current-buffer (window-buffer) (funcall then))
    (harness-media--settle 0.5))
  (harness-media--fit (harness-media--text-lines (selected-window)) nil most)
  (set-window-start nil (with-current-buffer (window-buffer) (point-min)))
  (harness-media--settle 0.5))

(defun harness-media--chat-shot (id file)
  "Show FILE of the demo project beside the chat of session ID, fitted.
Return the chat's buffer."
  (harness-media--reset-layout)
  (harness-media--show-file file)
  (let* ((code (selected-window))
         (buffer (harness-media--open-chat id 'right))
         (chat (get-buffer-window buffer)))
    (harness-media--fit (max (harness-media--text-lines chat) (harness-media--text-lines code)) 30)
    (harness-media--to-bottom buffer)
    buffer))

(defun harness-media-shot-tasks ()
  "The task board, with a task being written in its compose box."
  (harness-media--view (lambda () (harness-tasks harness-media-project 'full)))
  (let ((window (selected-window)))
    (with-current-buffer (window-buffer window)
      (harness-compose-set "Add DELETE /orders/{id}, which cancels an order that has not shipped yet")
      (set-window-point window (point-max))
      ;; The box's padding is sized for the frame as it is now; then the
      ;; whole board shows, the box under it.
      (harness-media--settle 1)
      (set-window-start window (point-min))))
  (harness-media--capture "tasks"))

(defconst harness-media--done-titles
  '("add a DELETE /orders/{id} endpoint"
    "return 409 when an order already shipped"
    "keep the order tests off the network"
    "log the request id with every order line"
    "make the invoice total an int in cents"
    "retry a failed webhook once before giving up"
    "rate-limit the login endpoint"
    "validate the coupon code before applying it"
    "document the pagination parameters"
    "drop the unused legacy_price column"
    "send a receipt email after checkout"
    "cache the product catalogue for five minutes")
  "Titles of the pretend completed tasks of the long board picture.")

(defun harness-media--add-done-tasks (n)
  "Put N completed tasks of the demo project on the board.
The picture is about a long board -- one grown by weeks of merged work
-- and running N tasks through the scripted providers would take
minutes: the board draws the same cards from its own task list."
  (setq harness-ui-tasks--tasks
        (append harness-ui-tasks--tasks
                (cl-loop for i below n
                         for title = (nth (mod i (length harness-media--done-titles))
                                          harness-media--done-titles)
                         for age = (* 7200 (1+ i))
                         for created = (- (float-time) age)
                         collect (list :id (format "t-media%03d" i)
                                       :project harness-media-project
                                       :cwd harness-media-project
                                       :prompt title
                                       :state "done" :column "done" :merged t
                                       :created created
                                       :started (+ created 600)
                                       :finished (+ created 1200)
                                       :verified-at (+ created 1300))))))

(defun harness-media-shot-tasks-long ()
  "A board grown long by merged work, still fitting its window.
53 completed tasks and every other column filled: the board holds the
least urgent cards back, a capped section saying \"... N more  [Show
all]\", so the compose box stays at the bottom of the window with the
task being written in it.  The frame is a fixed height, the same as the
before picture's: a board that does not fit would push the box below
the last line."
  (harness-media--view (lambda () (harness-tasks harness-media-project 'full)))
  (set-frame-size nil harness-media-columns 40)
  (let ((window (selected-window)))
    (with-current-buffer (window-buffer window)
      (harness-media--add-done-tasks 53)
      (harness-compose-set "Add DELETE /orders/{id}, which cancels an order that has not shipped yet")
      (set-window-point window (point-max))
      ;; The frame is the picture's size now: lay the board out for it
      ;; once more, as a tick does when a window changes size.
      (harness-ui-tasks--render))
    (harness-media--settle 1)
    (set-window-start window (point-min))
    (harness-media--settle 1))
  (harness-media--capture "tasks-long"))

(defun harness-media-shot-tasks-message ()
  "The task board writing a message to the session of a task at work.
The compose box wears the message colours and names the session it
sends to, so it cannot be taken for the one that writes a new task.
After the picture the box describes a new task again, as [cancel]
leaves it: the board is the same buffer in the shots that follow, and
the report pictures would show it still writing to that session."
  (harness-media--view (lambda () (harness-tasks harness-media-project 'full)))
  (let* ((id (plist-get (plist-get harness-media--world :tasks) :settings))
         (window (selected-window))
         (board (window-buffer window)))
    (with-current-buffer board
      ;; The board draws its cards as they arrive and the shared helper
      ;; errors on a card that is not there yet.
      (harness-media--wait (lambda () (ignore-errors (harness-media--goto-task-card id) t))
                           15 "the task's card")
      (harness-ui-tasks-reply)
      (unless (eq 'reply (car harness-ui-tasks--target))
        (error "The board did not open a message box (target %S)" harness-ui-tasks--target))
      (harness-compose-set "Keep the old settings module as a thin wrapper for one release, so the deploy can roll back.")
      (set-window-point window (point-max))
      (harness-media--settle 1)
      (set-window-start window (point-min)))
    (harness-media--capture "tasks-message")
    (with-current-buffer board
      (harness-ui-tasks-compose-reset))))

(defun harness-media--report-layout ()
  "Show the board the whole frame high, the pagination task's report over it.
Return the report's popout buffer."
  (harness-media--view (lambda () (harness-tasks harness-media-project 'full)))
  ;; The whole height: the report grows to most of it, for its chart.
  (set-frame-size nil harness-media-columns harness-media-lines)
  (harness-media--settle 0.5)
  (let* ((id (plist-get (plist-get harness-media--world :tasks) :pagination))
         (task (with-current-buffer (window-buffer (selected-window)) (harness-ui-tasks--find id))))
    (harness-ui-report-popout task)
    (harness-media--settle 1)
    (harness-ui-popout-buffer (list 'report id))))

(defun harness-media-shot-report ()
  "A task's report popped out of the board, at its end: its chart, large,
the test run it quotes, then the banner and the box that verify the task
or send it back."
  (let ((popout (harness-media--report-layout)))
    (with-selected-window (get-buffer-window popout)
      (goto-char (point-max))
      (recenter -1))
    (harness-media--capture "report")))

(defun harness-media-shot-report-image ()
  "That chart shown larger, in a popout of its own: RET on it in the report."
  (let ((popout (harness-media--report-layout)))
    (with-selected-window (get-buffer-window popout)
      (goto-char (point-min))
      (let ((match (text-property-search-forward 'display nil (lambda (_ value) (eq 'image (car-safe value))))))
        (unless match (error "The report shows no image"))
        (goto-char (prop-match-beginning match))
        (call-interactively (key-binding (kbd "RET")))))
    (harness-media--settle 1)
    (harness-media--capture "report-image")))

(defun harness-media-shot-tasks-search ()
  "The task board searched in words, typed in the board's own compose box.
/ turns the box into a search box, in colours of its own; the query is
typed there and RET sends it.  The scripted model answers a query about
the slow-request warning: the board shows that task under the banner,
archives it (the banner says so) and offers [Undo].  / once more opens
the box for the next search, so the picture shows the board's box as a
search box, under what the last search found.  After the picture the
search closes and the task is put back, so the shots that follow see the
board every other picture shows."
  (harness-media--view
   (lambda () (harness-tasks harness-media-project 'full))
   (lambda ()
     (call-interactively #'harness-ui-tasks-search)
     (unless (harness-ui-tasks--searching-p)
       (error "The board's box did not turn into a search box"))
     (harness-compose-set "get rid of the slow request warning")
     (harness-quick-search-box-submit)
     (harness-media--wait (lambda () (plist-get harness-ui-tasks-search--state :results))
                          20 "the search to act")
     (call-interactively #'harness-ui-tasks-search)
     (unless (harness-ui-tasks--searching-p)
       (error "The board's box did not open for the next search"))
     (harness-media--settle 0.6)))
  (harness-media--capture "tasks-search")
  ;; Leave the world as the other shots expect it: C-g closes the search
  ;; box, a second one shows every task again.
  (with-current-buffer (window-buffer (selected-window))
    (harness-ui-tasks-compose-quit)
    (harness-ui-tasks-compose-quit))
  (let* ((id (plist-get (plist-get harness-media--world :tasks) :slow))
         (sid (plist-get (harness-media--task id) :session)))
    (ignore-errors (harness-call 'task/archive id t))
    ;; Archived, its session was closed, and restored it stays closed:
    ;; open it again, with the times `harness-media--age' gave it.
    (when sid
      (ignore-errors (harness-call 'session/resume sid))
      (harness-media--set-times sid 110 41)
      (harness-ui-refresh-sessions))))

(defconst harness-media--quick-search-line "how do I attach the API guide?"
  "What the quick search picture asks.")

(defconst harness-media--quick-search-lines 40
  "How many lines high the quick search picture is.
The popout takes what its answer needs, about 25 with the answer in
words, and the chat and the code beside it the rest.")

(defun harness-media-shot-quick-search ()
  "The quick search, opened from a chat: a question answered in words.
C-c h / in the rate-limit session's chat, `acme/ratelimit.py' beside
it, opens the search's popout at the bottom of the frame; the line is
typed in its box and RET sends it.  The scripted model looks in the
sessions' transcripts for the guide, then answers how to attach it in
words and names the command that attaches a file and the session that
wrote it (see `harness-media--search-answer'), so the popout shows the
answer, whole, rendered as Markdown, then lists a command with [Run]
and [Describe] and, under Sessions with its [All matches], a session
with [Open] and the passage the session search found in it.  The
popout closes after the picture."
  (let ((buffer (harness-media--code-layout (plist-get harness-media--world :ratelimit))))
    (set-frame-size nil harness-media-columns harness-media--quick-search-lines)
    (harness-media--settle 0.5)
    (harness-media--to-bottom buffer)
    (select-window (get-buffer-window buffer))
    (call-interactively #'harness-quick-search)
    (let ((popout (harness-ui-popout-buffer '(quick-search))))
      (unless popout (error "The quick search did not open"))
      (with-current-buffer popout
        (harness-compose-set harness-media--quick-search-line)
        (harness-quick-search-box-submit)
        (harness-media--wait (lambda () (eq 'done (plist-get harness-quick-search--state :status)))
                             20 "the search to answer"))
      (harness-media--settle 0.5)
      (harness-media--to-bottom buffer)
      (harness-media--capture "quick-search")
      (harness-ui-popout-close '(quick-search) t))))

(defun harness-media-shot-sessions ()
  "The session list, in a frame wide enough for its last column, the project.
Its columns take about 156 of `harness-media-columns'; the first
picture's width, `harness-media-hero-columns', shows the project too."
  (harness-media--view (lambda ()
                         (set-frame-size nil harness-media-hero-columns (frame-height))
                         (harness-sessions))
                       ;; Point on the first row, whatever row the loads left it on.
                       (lambda () (goto-char (point-min))))
  (harness-media--capture "sessions"))

(defun harness-media--goto-session-row (id)
  "Move point to the session list row of session ID and show it."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id)))
    (forward-line 1))
  (unless (equal (tabulated-list-get-id) id) (error "No row for session %s" id))
  (recenter 4))

(defun harness-media--goto-task-card (id)
  "Move point to the card of task ID on the board and show it."
  (goto-char (point-min))
  (let ((match (text-property-search-forward 'harness-task-id id #'equal)))
    (unless match (error "No card for task %s" id))
    (goto-char (prop-match-beginning match))
    (recenter 4)))

(defun harness-media--fit-popout-shot (most &optional columns spare)
  "Size the frame for a view with a popout under it, at most MOST lines.
The frame is fitted to the text of every window, so the view and the
popout both show; the popout is a side window and keeps its height,
which is more than its text needs.  SPARE lines more make up for that
when the view must show whole.  It is COLUMNS wide, by default
`harness-media-columns'."
  (set-frame-size nil (or columns harness-media-columns)
                  (min (or most harness-media-lines)
                       (max 24 (+ 6 (or spare 0)
                                  (cl-loop for w in (window-list nil 'nomini)
                                           sum (harness-media--text-lines w))))))
  (harness-media--settle 1))

(defun harness-media-shot-popout-permission ()
  "The session list, with the permission a blocked session waits for popped out.
The frame is as wide as the session list's own picture, which its last
column, the project, needs."
  (harness-media--view #'harness-sessions)
  (harness-media--goto-session-row (plist-get harness-media--world :permission))
  (harness-ui-sessions-requests)
  ;; The whole list shows over the popout: four lines more than the
  ;; text of the two windows, which the popout's own height eats.
  (harness-media--fit-popout-shot 36 harness-media-hero-columns 4)
  (harness-media--capture "popout-permission"))

(defun harness-media-shot-popout-question ()
  "The task board, with the question a task's session waits on popped out."
  (harness-media--view (lambda () (harness-tasks harness-media-project 'full)))
  (harness-media--goto-task-card (plist-get (plist-get harness-media--world :tasks) :health))
  (harness-ui-tasks-requests)
  (harness-media--fit-popout-shot 32)
  (harness-media--capture "popout-question"))

(defun harness-media-shot-tree ()
  "The conversation tree of the rate-limit session."
  (harness-media--view (lambda () (harness-tree (plist-get harness-media--world :ratelimit))))
  (harness-media--capture "tree"))

(defun harness-media-shot-usage ()
  "The usage dashboard over 30 days, by model, with the fallback list."
  (setq harness-fallback-models '("claude" "openrouter:openai/gpt-5"))
  (harness-media--view #'harness-usage
                       (lambda ()
                         (harness-ui-usage-set-period 'month)
                         (harness-ui-usage-set-group 'model)
                         (harness-media--settle 1.5)))
  (harness-media--capture "usage"))

(defun harness-media--usage-by-project (unfold)
  "Show the usage dashboard over 30 days by project, worktrees shown when UNFOLD.
Every project starts folded, whatever an earlier shot unfolded."
  (harness-media--view #'harness-usage
                       (lambda ()
                         (setq harness-ui-usage--unfolded nil)
                         (harness-ui-usage-set-period '30d)
                         (harness-ui-usage-set-group 'project)
                         (harness-media--settle 1.5)
                         (when unfold (harness-ui-usage-toggle-worktrees))
                         (goto-char (point-min)))))

(defun harness-media-shot-usage-projects ()
  "The usage dashboard by project, the tasks' worktrees folded under theirs."
  (harness-media--usage-by-project nil)
  (harness-media--capture "usage-projects"))

(defun harness-media-shot-usage-worktrees ()
  "The usage dashboard by project, the demo project's worktrees unfolded."
  (harness-media--usage-by-project t)
  (harness-media--capture "usage-worktrees"))

;;;; The Insights report

;; The report reads the transcripts on disk, where the world's sessions
;; are all from today: a month of earlier chats is written for it, in
;; the three projects the usage history covers, on working days and
;; hours, with the permission decisions their tool calls took.  They are
;; made when the first Insights picture is taken, after the others, so
;; the session list and the other pictures do not show them.

(defconst harness-media--history
  '((api "Add an index on orders.created_at" "Listing orders by date scans the whole table; add an index and a migration.")
    (web "Fix the checkout form validation" "The checkout form accepts a quantity of 0. Validate it on the client and show why.")
    (api "Why is the catalogue endpoint slow?" "GET /products takes 900 ms with 2,000 products. Why?")
    (infra "Nightly database backups" "Back the orders database up to S3 every night and keep 30 days.")
    (api "Validate order quantities" "Reject orders with a quantity under 1 or over 500, with a 422 and the field.")
    (web "Order history page" "Add an order history page: the customer's orders, newest first, 20 a page.")
    (api "Review the auth module" "Read acme/auth.py and tell me what you would change.")
    (infra "Cache pip in CI" "CI spends two minutes installing packages. Cache them between runs.")
    (api "Return 404 for unknown products" "GET /products/999 raises a KeyError and answers 500. Answer 404.")
    (web "Dark mode for the dashboard" "Give the admin dashboard a dark mode that follows the system setting.")
    (api "Test the webhook sender" "Write tests for acme/webhooks.py: a subscriber that times out, one that answers 500.")
    (infra "Terraform for the staging database" "Plan a staging copy of the orders database in Terraform, smaller than production.")
    (api "Explain the orders schema" "Explain the orders tables to someone joining the team.")
    (web "Bundle size went up" "The JavaScript bundle grew by 300 kB last week. Find out why.")
    (api "Soft-delete orders" "Deleting an order should keep it for accounting: add deleted_at and filter on it.")
    (api "Move to SQLAlchemy 2" "Upgrade SQLAlchemy to 2.0 and fix what breaks.")
    (web "Format prices in the customer's locale" "Prices show as 1234.5; format them for the customer's locale and currency.")
    (infra "Alert on 5xx rates" "Alert when more than 1% of requests answer 5xx over five minutes.")
    (api "Idempotency keys for POST /orders" "A retried POST /orders makes a second order. Accept an Idempotency-Key header.")
    (api "Profile the order listing" "Profile GET /orders with 10,000 orders and say where the time goes.")
    (web "Flaky Cypress login test" "The login test fails one run in five on CI. Make it reliable.")
    (api "Typed responses" "Describe the JSON our endpoints answer with dataclasses, and use them.")
    (infra "Rotate the database password" "Rotate the database password without downtime.")
    (api "Clean up the settings module" "settings.py reads the environment in three places; read it in one."))
  "Chats of the month before: (PROJECT NAME PROMPT).")

(defconst harness-media--history-tools
  '((api ("read_file" . 30) ("grep" . 14) ("edit_file" . 22) ("bash" . 24) ("write_file" . 6) ("glob" . 4))
    (web ("read_file" . 28) ("edit_file" . 24) ("bash" . 22) ("grep" . 12) ("web_fetch" . 6) ("emacs_buffer" . 8))
    (infra ("read_file" . 24) ("bash" . 36) ("edit_file" . 20) ("web_search" . 10) ("write_file" . 10)))
  "The tools the chats of each project call, weighted.")

(defconst harness-media--history-failing
  '(("bash" . 17) ("edit_file" . 6) ("web_fetch" . 10) ("glob" . 0) ("grep" . 2))
  "Percent of the calls of each tool that fail; 3 when not named.")

(defconst harness-media--insights-summary
  '(:summary "A month of steady work on the Acme orders API, with a quieter stream of front-end and infrastructure changes beside it. Chats carried the questions and the investigations, tasks the changes that were clear from the start; nearly every task was accepted the first time, and the one sent back was missing a unit."
    :themes ["Rate limiting for the orders API: token buckets, then a sliding-window log tried in a fork"
             "Paging, profiling and timing GET /orders, and the catalogue endpoint's slowness"
             "Webhooks: telling subscribers about new orders, testing the sender and pooling its connections"
             "acme-web: checkout validation, the order history page and a flaky login test"
             "infra: backups, CI caching and alerts on 5xx rates"]
    :patterns ["You start most work mid-morning and again after lunch, rarely at weekends."
               "Open questions go to chats and clear changes to tasks; a design with two good answers gets a fork."]
    :friction ["bash fails more than any other tool, mostly test runs: the flaky order and login tests account for many of them."
               "One task was sent back to say which unit its threshold was in; its prompt left it open."]
    :suggestions ["Say units and limits in task prompts, as in \"500 ms\" or \"50 by default, at most 200\": the task sent back lacked one."
                  "Fix the flaky test_creates_an_order once: it is behind a good share of the failed bash calls."
                  "Put the project's habits, such as how to run the tests, in its instructions file, so every session starts with them."])
  "The summary the scripted model writes for the Insights report.")

(defun harness-media--history-project (key)
  "Return the directory of history project KEY."
  (pcase key
    ('api harness-media-project)
    ('web (expand-file-name "~/src/acme-web/"))
    (_ (expand-file-name "~/src/infra/"))))

(defun harness-media--history-input (tool project)
  "Return a plausible input of a TOOL call in PROJECT, a history key."
  (pcase tool
    ("bash" (list :command (pcase project
                             ('api "python -m pytest -q") ('web "npm test -- --run")
                             (_ "terraform plan -out plan.tfplan"))))
    ((or "grep" "glob") (list :pattern "orders"))
    ((or "web_fetch" "web_search") (list :query "release notes"))
    ("emacs_buffer" (list :name "*compilation*"))
    (_ (list :path (pcase project ('api "acme/orders.py") ('web "src/checkout.ts") (_ "main.tf"))))))

(defun harness-media--history-chat (entry day-start)
  "Write the chat ENTRY, (PROJECT NAME PROMPT), as held on the day at DAY-START.
Its tool calls are logged with the permission decisions they took."
  (pcase-let* ((`(,project ,name ,prompt) entry)
               (id (harness-media--new-session :name name :cwd (harness-media--history-project project)
                                               :model (harness-media--pick '(("claude:claude-fable-5-1" . 6)
                                                                             ("claude:claude-sonnet-5" . 3)
                                                                             ("openrouter:openai/gpt-5" . 1)))))
               (tools (cdr (assq project harness-media--history-tools)))
               (ts (+ day-start (* 3600 (harness-media--pick '((9 . 3) (10 . 6) (11 . 5) (12 . 1) (13 . 2) (14 . 5)
                                                               (15 . 5) (16 . 4) (17 . 2) (20 . 1) (21 . 1))))
                      (* 60 (random 50))))
               (created ts)
               (turns (harness-media--pick '((1 . 3) (2 . 4) (3 . 3) (4 . 1)))))
    (dotimes (turn turns)
      (harness-call 'session/append id (list :kind 'user :ts ts
                                             :content (if (zerop turn) prompt "Good. Now the tests for it, please.")))
      (dotimes (_ (+ 2 (random (if (zerop turn) 6 3))))
        (cl-incf ts (+ 8 (random 50)))
        (let* ((tool (harness-media--pick tools))
               (call-id (format "history-%d" (cl-incf harness-media--call-count)))
               (asked (and (member tool '("bash" "write_file" "web_fetch")) (< (random 100) 45)))
               (denied (and (equal tool "bash") (< (random 100) 6)))
               (failed (and (not denied)
                            (< (random 100) (or (cdr (assoc tool harness-media--history-failing)) 3))))
               (took (if (equal tool "bash") (+ 4 (random 70)) (+ 1 (random 3)))))
          (harness-call 'session/append id (list :kind 'tool-call :ts ts :tool tool :call-id call-id
                                                 :input (harness-media--history-input tool project)))
          (harness-call 'store/append (harness-insights--permissions-name ts)
                        (list :ts ts :session id :tool tool :behavior (if denied "deny" "allow")
                              :asked (if (or asked denied) t :false)))
          (cl-incf ts took)
          (harness-call 'session/append id (append (list :kind 'tool-result :ts ts :call-id call-id
                                                         :output (cond (denied "The user denied this call.")
                                                                       (failed "Exit status 1")
                                                                       (t "ok")))
                                                   (and (or denied failed) (list :is-error t))
                                                   (list :meta (if denied (list :denied t :duration 0)
                                                                 (list :duration took)))))))
      (cl-incf ts (+ 20 (random 90)))
      (harness-call 'session/append id (list :kind 'assistant :ts ts :content "Done: the change and its tests."))
      (cl-incf ts (* 60 (+ 3 (random 25)))))
    (harness-call 'session/deactivate id)
    (when-let* ((s (gethash id harness-sessions)))
      (aset s (cl-struct-slot-offset 'harness-session 'created) created)
      (aset s (cl-struct-slot-offset 'harness-session 'updated) ts))))

(defun harness-media--seed-history ()
  "Write the month of chats before the pictures, once."
  (unless (plist-get harness-media--world :history)
    ;; The same month whichever pictures were taken before.
    (random "harness-media-history")
    (let ((entries harness-media--history)
          (count 0))
      ;; From yesterday back, as long as there are chats.
      (cl-loop for days-ago from 1 to 29
               for start = (harness-media--day-start (- (float-time) (* days-ago 86400)))
               for weekday = (string-to-number (format-time-string "%u" start))
               for chats = (pcase weekday (6 (if (zerop (random 3)) 1 0)) (7 0) (_ (if (zerop (random 4)) 2 1)))
               do (dotimes (_ chats)
                    (when entries
                      (harness-media--history-chat (pop entries) start)
                      (cl-incf count))))
      (harness-ui-refresh-sessions)
      (setq harness-media--world (append (list :history count) harness-media--world))
      (harness-media--log "wrote %d chats of history" count))))

(defun harness-media--insights ()
  "Show the Insights report over 30 days, of every project, its summary written."
  (harness-media--seed-history)
  (harness-media--view #'harness-insights
                       (lambda ()
                         (harness-media--wait (lambda () (and harness-ui-insights--data
                                                              (not harness-ui-insights--loading)
                                                              (not harness-ui-insights--writing)))
                                              90 "the Insights report")
                         (harness-media--settle 1)
                         (goto-char (point-min)))))

(defun harness-media-shot-insights ()
  "The Insights report: the figures, the summary the model wrote and the usage."
  (harness-media--insights)
  (harness-media--capture "insights"))

(defun harness-media-shot-insights-activity ()
  "The Insights report further down: sessions, tools, tasks and activity."
  (harness-media--insights)
  (let ((window (get-buffer-window harness-ui-insights--buffer-name)))
    (with-current-buffer harness-ui-insights--buffer-name
      (goto-char (point-min))
      (re-search-forward "^ Sessions")
      (set-window-start window (line-beginning-position 0))
      (set-window-point window (point))))
  (harness-media--settle 0.5)
  (harness-media--capture "insights-activity"))

(declare-function harness-ui-worktree-assume "harness-ui-worktree")
(declare-function worktree-assume-reset "worktree-assume" (&optional project))
(declare-function worktree-assume-mode "worktree-assume" (&optional arg))

(defun harness-media-shot-worktrees ()
  "The worktrees of the demo project, one of a task's assumed as the project.
`a' on the row of the second worktree, as a user does to look at a task's
files: the row says `assumed', the mode line offers [r reset] and names
the worktree, and until the picture is taken `project-find-file' would
list its files.  Nothing stays assumed afterwards: the pictures that
follow are of the project as it is."
  (harness-media--view (lambda () (harness-worktrees harness-media-project)))
  (unwind-protect
      (progn
        (with-current-buffer (window-buffer)
          (goto-char (point-min))
          (forward-line 1)
          (harness-ui-worktree-assume))
        (harness-media--settle 0.5)
        (harness-media--capture "worktrees"))
    (worktree-assume-reset 'all)
    (worktree-assume-mode -1)))

(defun harness-media-shot-settings ()
  "The settings page, for the demo project, which overrides two settings."
  (harness-media--write ".dir-locals.el"
                        "((nil . ((harness-permission-mode . accept-edits)\n         (harness-thinking . \"high\"))))\n")
  (harness-media--view (lambda () (harness-settings harness-media-project 'project)) nil 42)
  (harness-media--capture "settings"))

(defvar harness-policy-file)
(declare-function harness-policy-load "harness-policy")
(declare-function harness-policy-apply "harness-policy" (&optional final))
(declare-function harness-policy-clear "harness-policy")

(defconst harness-media--policy
  ";; The harness policy of this machine, deployed by IT.
((harness-corporate-mode . t)
 (harness-permission-mode . ask)
 (harness-sandbox-policy . required)
 (harness-allowed-models . (\"claude:*\")))
"
  "The policy the settings-policy picture is taken under: what a company fixes.")

(defun harness-media-shot-settings-policy ()
  "The settings page under an administrator's policy: four settings locked.
The policy is a file of the scratch HOME, read and applied as
`harness-reload' does; the page names it /etc/harness/policy.el, where
an administrator puts it (`directory-abbrev-alist').  The policy is
lifted again afterwards, and the settings it fixed get their values back."
  (let* ((dir (expand-file-name "~/policy/"))
         (harness-policy-file (expand-file-name "policy.el" dir))
         (directory-abbrev-alist (cons (cons (concat "\\`" (regexp-quote dir)) "/etc/harness/")
                                       directory-abbrev-alist)))
    (make-directory dir t)
    (with-temp-file harness-policy-file (insert harness-media--policy))
    (unwind-protect
        (progn
          (harness-policy-load)
          (harness-policy-apply t)
          (harness-media--view (lambda () (harness-settings harness-media-project 'global)) nil 46)
          (harness-media--capture "settings-policy"))
      (delete-file harness-policy-file)
      (harness-policy-clear))))

(defun harness-media-shot-btw ()
  "A BTW side conversation under the rate-limit session's chat."
  (harness-media--code-layout (plist-get harness-media--world :ratelimit))
  (harness-media--to-bottom (harness-media--open-chat (plist-get harness-media--world :btw) 'bottom))
  (harness-media--capture "btw"))

(defun harness-media-shot-menu ()
  "The harness menu, opened from the rate-limit session's chat."
  (let ((buffer (harness-media--code-layout (plist-get harness-media--world :ratelimit))))
    (select-window (get-buffer-window buffer))
    (harness-menu)
    (harness-media--settle 1)
    (harness-media--capture "menu")
    (ignore-errors (transient-quit-all))))

(defvar harness-acp-remote-host)
(defvar harness-acp-remote-port)
(defvar harness-acp-remote-address)
(declare-function harness-acp-remote--mint "harness-acp-remote")
(declare-function harness-acp-remote--request-approval "harness-acp-remote")
(declare-function harness-acp-remote--approval-over "harness-acp-remote")
(defvar harness-acp-remote--approvals)

(defun harness-media-shot-remote ()
  "The remote control page: serving, a device that asks to sign in, devices signed in."
  ;; Loopback only, on the usual port when it is free; the page shows
  ;; a local network address, as on a laptop at home.
  (setq harness-acp-remote-host "127.0.0.1"
        harness-acp-remote-address "192.168.1.150"
        ;; An authentik provider set up for the harness, so the page
        ;; shows the link a browser signs in with there.
        harness-acp-remote-oidc-issuer "https://auth.example.com/application/o/harness/"
        harness-acp-remote-oidc-client-id "harness"
        harness-acp-remote-oidc-allowed '("harness-users"))
  (condition-case nil
      (let ((harness-acp-remote-port 4276)) (harness-call 'acp/remote-start))
    (error (let ((harness-acp-remote-port 0)) (harness-call 'acp/remote-start))))
  ;; Signed in: a phone's ACP client that was approved (its session is its
  ;; connection's alone), a laptop that signed in with OpenID Connect, and
  ;; a tablet that was given a token.
  (harness-acp-remote--mint
   "ACP UI 0.9.1 · Android · Chrome"
   "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/131.0 Mobile Safari/537.36"
   "192.168.1.23" "approval" nil t)
  (harness-acp-remote--mint
   "me@example.com · Mac · Safari" "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
   "192.168.1.40" "oidc" "u-1")
  (harness-acp-remote--mint "Tablet" nil "192.168.1.31" "token")
  ;; And an iPhone that is asking now: a socket that carries nothing, and
  ;; the request its `authenticate' makes.
  (let* ((socket (make-pipe-process :name "media-remote-socket" :noquery t))
         (client (harness-acp-add-client
                  'websocket :process socket :writer #'ignore
                  :remote (list :transport "websocket" :address "192.168.1.52"
                                :agent "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"))))
    (harness-acp--client-set client 'hello '(:name "acp-ui" :title "ACP UI" :version "0.9.1"))
    (harness-acp-remote--request-approval client)
    (harness-media--view #'harness-remote-control
                         (lambda ()
                           (harness-media--settle 1)
                           (goto-char (point-min))))
    (harness-media--capture "remote")
    (dolist (approval (copy-sequence harness-acp-remote--approvals))
      (harness-acp-remote--approval-over approval "The shot is over"))
    (harness-acp-drop-client client)
    (when (process-live-p socket) (delete-process socket)))
  (harness-call 'acp/remote-stop))

(defun harness-media--attachments-make-media ()
  "Make the picture and the video the attachments shot sends.
They go in the demo project; return (PNG MP4), or nil without ffmpeg."
  (let ((png (harness-media--path "docs/screenshot.png"))
        (mp4 (harness-media--path "docs/walkthrough.mp4"))
        (ffmpeg (executable-find "ffmpeg")))
    (when ffmpeg
      (make-directory (file-name-directory png) t)
      (unless (file-exists-p png)
        (call-process ffmpeg nil nil nil "-loglevel" "error" "-y" "-f" "lavfi"
                      "-i" "testsrc2=size=960x540" "-frames:v" "1" png))
      (unless (file-exists-p mp4)
        (call-process ffmpeg nil nil nil "-loglevel" "error" "-y" "-f" "lavfi"
                      "-i" "testsrc=duration=3:size=960x540:rate=25"
                      "-c:v" "libx264" "-pix_fmt" "yuv420p" mp4))
      (list png mp4))))

(defun harness-media--attachments-downloading ()
  "Put a link that is still downloading in the current compose box.
Nothing is fetched: the chip reads the bytes of a partly written file
against the size the server said, which is what a real one shows."
  (let* ((dir (harness-ensure-directory (expand-file-name "downloads/" harness-state-directory)))
         (partial (expand-file-name "walkthrough.mp4.part" dir))
         (total 12400000)
         (received (round (* 0.41 total)))
         (coding-system-for-write 'binary))
    (with-temp-file partial
      (set-buffer-multibyte nil)
      (insert-char ?x received))
    (setq harness-compose-attachments
          (append harness-compose-attachments
                  (list (list :pending t :id "shot" :name "walkthrough.mp4"
                              :url "https://acme.example/docs/walkthrough.mp4"
                              :download (harness-http--make-download
                                         :url "https://acme.example/docs/walkthrough.mp4"
                                         :file partial :total total
                                         :name "walkthrough.mp4" :mime "video/mp4")))))))

(defun harness-media--attachments-wait-for-thumbnails (files)
  "Wait until the video in FILES has its thumbnail, or give up."
  (let ((deadline (+ (float-time) 30)))
    (while (and (< (float-time) deadline)
                (not (file-exists-p (harness-ui-media-thumbnail-path (cadr files)))))
      (harness-media--settle 0.5))
    (harness-media--settle 0.5)))

(defun harness-media-shot-attachments ()
  "The compose box of a chat: a picture and a video attached, both with
their thumbnails in the chips, and a link still downloading with its
progress."
  (let* ((buffer (harness-media--open-chat (plist-get harness-media--world :ratelimit) 'full))
         (files (harness-media--attachments-make-media)))
    (harness-media--settle 1)
    (with-current-buffer buffer
      (dolist (file files) (harness-compose-add-attachment file))
      (harness-media--attachments-downloading)
      (harness-compose-redraw))
    (when files (harness-media--attachments-wait-for-thumbnails files))
    (harness-media--fit (harness-media--text-lines (selected-window)) 30)
    (harness-media--to-bottom buffer)
    (harness-media--capture "attachments")))

;;;; The compose box: its references, the queue, the region

(defvar harness-chat--queue)
(defvar harness-compose-attachments)
(defvar harness-compose-start)

(defun harness-media-shot-compose-chips ()
  "The compose box of a chat whose message names what it attaches.
An image, a file of the project and a task, each by its reference in
the text, and every reference the same chip: the image's thumbnail, or
the icon of the file or the task, then its name as a link.  The lines
above the box list them too.  The box gets back what it held, for the
pictures that show it after this one."
  (harness-media--reset-layout)
  (let* ((buffer (harness-media--open-chat (plist-get harness-media--world :ratelimit) 'full))
         (png (car (harness-media--attachments-make-media)))
         (task (plist-get (plist-get harness-media--world :tasks) :slow))
         (saved (with-current-buffer buffer (cons (harness-compose-text) harness-compose-attachments))))
    (harness-media--settle 1)
    (with-current-buffer buffer
      (setq harness-compose-attachments nil)
      (harness-compose-set
       (format (concat "Over the limit a client gets the page in  and no Retry-After header. "
                       "The limiter is @acme/ratelimit.py: log each 429 the way @task:%s did, "
                       "and send the header.")
               task))
      ;; The image's token goes where point is, as when it is pasted there.
      (when png
        (goto-char harness-compose-start)
        (search-forward "the page in ")
        (harness-compose-add-attachment png))
      ;; The text names the file and the task already: they keep those references.
      (harness-compose-add-attachment (harness-media--path "acme/ratelimit.py"))
      (harness-compose-attach-task task)
      (harness-media--wait (lambda () (harness-compose--attached-p (concat "task:" task))) 15 "the task to attach")
      (harness-compose-redraw))
    (harness-media--settle 1)
    (harness-media--fit 22 22 26)
    (harness-media--to-bottom buffer)
    (harness-media--capture "compose-chips")
    (with-current-buffer buffer
      (harness-compose-set (car saved))
      (setq harness-compose-attachments (cdr saved))
      (harness-compose-redraw))))

(defun harness-media--queue-steered (_request)
  "The queue picture's turn once the message that steers it reached the model.
It thinks on that message, then holds: the turn runs while the picture is
taken, so a message sent next waits for a step that never comes."
  (list (harness-media--think "Rows keep their `sqlite3.Row` factory, so `query` returns `list[sqlite3.Row]`; `connect` returns the connection. Now the signatures.")
        (list :type 'hold)))

(defun harness-media--queue-script (request)
  "The session of the queue picture: the checks first, then on, held.
The message sent right after the first one reaches the model at the
step after the checks, or with the first request when that has not gone
out yet (`harness-media--queue-steered' answers it then); either way
REQUEST's turn holds once it has it."
  (append (list (harness-media--think "A baseline first: what the tests pass to `query` tells me its types.")
                (harness-media--tool "bash" :command "python3 -m unittest -v 2>&1 | tail -n 3"))
          (harness-media--queue-steered request)))

(defun harness-media--delivered-p (id text)
  "Non-nil when TEXT, a message steering session ID's turn, reached the model."
  (cl-some (lambda (n) (and (eq (plist-get n :kind) 'user)
                            (equal (plist-get n :content) text)
                            (plist-get (plist-get n :meta) :delivered-after)))
           (harness-call 'session/nodes id)))

(defun harness-media-shot-chat-queue ()
  "A chat whose turn runs, with messages in every state of their sending.
One sent while the checks ran steered the turn at its next step: the
model has it, and it reads as any message, with nothing beside the name.
One sent since waits for the next step, and says \"queued\", with its
[edit] and [delete] and the key of each, and the line telling how to press
them from the box.  Two more are queued for the next turn, each drawn as
a message of the user's, a dim \"queued\" and its [send now], [edit] and
[delete] beside the name, above the line saying what the turn does.  The
session is made here and deleted after, so no other picture shows it,
and it comes after the usage pictures, which would count its usage."
  (let ((id (harness-media--new-session :name "Type the database module" :model "claude:claude-opus-5-5"
                                        :permission-mode 'auto))
        (steer "Keep the sqlite3.Row factory: the handlers index rows by column name."))
    (harness-call 'agent/prompt id "Add type hints to acme/db.py, then run mypy and the tests.")
    ;; Sent while the turn runs, it steers it: the model gets it at its next step.
    (harness-call 'agent/prompt id steer)
    (harness-media--wait (lambda () (harness-media--delivered-p id steer)) 20 "the message to reach the model")
    ;; The turn holds once it has it; a message sent now waits.
    (harness-media--settle 1)
    (harness-call 'agent/prompt id "And no new dependencies, please.")
    (harness-call 'agent/prompt id "Then do the same for acme/products.py." '(:queue t))
    (harness-call 'agent/prompt id "Write the commit message in the imperative." '(:queue t))
    (let ((buffer (harness-media--chat-shot id "acme/db.py")))
      (harness-media--wait (lambda () (with-current-buffer buffer (= (length harness-chat--queue) 2)))
                           10 "the queue to show")
      (harness-media--expand buffer "bash"))
    ;; Fitted again, the queue drawn and the checks' output shown.
    (harness-media--chat-shot id "acme/db.py")
    (harness-media--capture "chat-queue")
    (harness-call 'agent/cancel id)
    (harness-media--wait (lambda () (not (harness-call 'agent/running id))) 15 "the turn to end")
    (harness-call 'session/delete id)))

(defun harness-media-shot-prompt-region ()
  "Code selected in a file, and C-c h > on it (`harness-prompt-region').
The newest session of the project, made for the picture, gets it in its
box: where it comes from, the file and its lines, then the code in a
fenced block, point under it for the request.  The selection shows still,
for the picture.  The session is deleted after."
  (let ((id (harness-media--new-session :name "Explain the token bucket" :model "claude:claude-opus-5-5"
                                        :permission-mode 'accept-edits)))
    (harness-media--reset-layout)
    (harness-media--show-file "acme/ratelimit.py" "^class TokenBucket")
    (let ((listed nil))
      (harness-ui-refresh-sessions (lambda (_) (setq listed t)))
      (harness-media--wait (lambda () listed) 10 "the session list"))
    (let* ((code (selected-window))
           (file (window-buffer code))
           (beg (progn (goto-char (point-min)) (re-search-forward "^    def take") (line-beginning-position)))
           (end (progn (re-search-forward "^        return max.*$") (point))))
      (set-mark beg)
      (goto-char end)
      (activate-mark)
      (harness-prompt-region)
      (let ((buffer (harness-media--wait
                     (lambda ()
                       (let ((chat (harness-chat--buffer-for id)))
                         (and (buffer-live-p chat)
                              (with-current-buffer chat
                                (and harness-compose-start (string-search "```python" (harness-compose-text))))
                              chat)))
                     20 "the region in the session's box")))
        (harness-media--settle 1)
        ;; The selection, as it was, beside the box that got it.
        (with-current-buffer file
          (set-marker (mark-marker) beg)
          (setq mark-active t))
        (set-window-point code end)
        (setq highlight-nonselected-windows t)
        (harness-media--fit 26 26 30)
        (harness-media--to-bottom buffer)
        (harness-media--capture "prompt-region")
        (setq highlight-nonselected-windows nil)
        (with-current-buffer file (deactivate-mark))))
    (harness-call 'session/delete id)))

(defvar harness-directory)
(defvar harness-ui-version--report)
(defvar harness-ui-version--checking)
(declare-function harness-version "harness-ui-version")
(declare-function harness-revision-note-loaded "harness-revision")
(declare-function harness-promise-settled-p "harness-core")
(declare-function harness-promise-value "harness-core")

(defun harness-media-shot-version ()
  "The version page of a harness installed with straight.el, two days behind.
For the picture the harness was loaded two days ago from straight's
clone of GitHub (see `harness-media--make-harness-repos'), so the page
sees the development checkout and GitHub ten commits ahead and says to
pull with straight.  The harness counts as loaded from its checkout again
afterwards."
  (let ((harness-directory (plist-get (harness-media--harness-paths) :build)))
    (let ((loaded (harness-revision-note-loaded)))
      (harness-media--wait (lambda () (harness-promise-settled-p loaded)) 20 "the revision loaded")
      (plist-put (harness-promise-value loaded) :loaded (harness-media--ago (* 49 60))))
    (setq harness-ui-version--report nil)
    (harness-media--view #'harness-version
                         (lambda ()
                           (harness-media--wait (lambda () (and harness-ui-version--report
                                                                (not harness-ui-version--checking)))
                                                30 "the version check")
                           (harness-media--settle 0.5)))
    (harness-media--capture "version"))
  (harness-revision-note-loaded))

;;;; Reviewing a task's changes with threads

(defvar harness-ui-patch-review--reviews)
(declare-function harness-ui-patch-review--r-files "harness-ui-patch-review")
(declare-function harness-ui-patch-review--r-set "harness-ui-patch-review")
(declare-function harness-ui-patch-review--r-tip "harness-ui-patch-review")
(declare-function harness-ui-patch-review--r-popout "harness-ui-patch-review")
(declare-function harness-ui-patch-review--r-ediff "harness-ui-patch-review")
(declare-function harness-ui-patch-review--location "harness-ui-patch-review")
(declare-function harness-ui-patch-review-ediff "harness-ui-patch-review")
(declare-function harness-ui-patch-review-select-diff "harness-ui-patch-review")
(declare-function harness-ui-patch-review--r-loading "harness-ui-patch-review")
(declare-function harness-ui-patch-review--r-placing "harness-ui-patch-review")
(declare-function harness-ui-patch-review--r-shown-selector "harness-ui-patch-review")
(declare-function change-review-user "change-review")
(declare-function change-review-agent "change-review")
(declare-function change-review-comment "change-review")
(declare-function change-review-reply "change-review")
(declare-function change-review-close "change-review")
(declare-function change-review-ui-set-fold "change-review-ui")
(declare-function change-review-ui-flush "change-review-ui")
(declare-function change-review-set-threads "change-review")
(declare-function change-review-open-threads "change-review-ui")
(declare-function change-review-ui-set-filter "change-review-ui")
(declare-function change-review-ui-show-origin "change-review-ui")
(declare-function harness-ui-patch-review--approve "harness-ui-patch-review")
(declare-function harness-ui-patch-review--refresh "harness-ui-patch-review")
(defvar harness-chat--transcript-end)

(defvar harness-media--review nil
  "The review the review pictures show, once its threads are made.")

(defun harness-media--review-line (text file)
  "Return the number of the first line of FILE, in the slow task's worktree, matching TEXT."
  (let ((worktree (plist-get (harness-media--task (plist-get (plist-get harness-media--world :tasks) :slow))
                             :worktree)))
    (with-temp-buffer
      (insert-file-contents (expand-file-name file worktree))
      (goto-char (point-min))
      (unless (re-search-forward text nil t) (error "No %s in %s" text file))
      (line-number-at-pos (match-beginning 0)))))

(defun harness-media--review-prepare ()
  "Put a second file on the slow-request task's branch, for the review pictures.
The agent wired the timing middleware in the app: acme/app.py changes
beside acme/timing.py.  Done once."
  (let* ((id (plist-get (plist-get harness-media--world :tasks) :slow))
         (worktree (plist-get (harness-media--task id) :worktree))
         (app (expand-file-name "acme/app.py" worktree)))
    (unless (with-temp-buffer (insert-file-contents app) (search-forward "timed(" nil t))
      (let ((text (with-temp-buffer (insert-file-contents app) (buffer-string))))
        (with-temp-file app
          (insert (replace-regexp-in-string
                   "def application(environ, start_response):"
                   "def _application(environ, start_response):"
                   (replace-regexp-in-string
                    "from acme.auth import authenticate\n"
                    "from acme.auth import authenticate\nfrom acme.timing import timed\n"
                    text t t)
                   t t))
          (insert "\n\napplication = timed(_application)\n")))
      (harness-media--git-in worktree "add" "-A")
      (harness-media--git-in worktree "commit" "-q" "-m" "Time the requests the application serves"))))

(defun harness-media--review-layout ()
  "Show the board the whole frame high, the slow-request task's report over it.
Return the report's popout buffer, once it shows its changes."
  (harness-media--review-prepare)
  (harness-media--view (lambda () (harness-tasks harness-media-project 'full)))
  (set-frame-size nil harness-media-columns harness-media-lines)
  (harness-media--settle 0.5)
  (let* ((id (plist-get (plist-get harness-media--world :tasks) :slow))
         (task (with-current-buffer (window-buffer (selected-window)) (harness-ui-tasks--find id))))
    (harness-ui-report-popout task)
    (let ((review (harness-media--wait
                   (lambda ()
                     (let ((review (gethash id harness-ui-patch-review--reviews)))
                       ;; Both files: an earlier picture's session read the
                       ;; branch before the second commit.
                       (and review (harness-ui-patch-review--r-tip review)
                            (= 2 (length (harness-ui-patch-review--r-files review))) review)))
                   30 "the review to read the branch")))
      (harness-media--review-threads review id))
    (harness-media--settle 1)
    (harness-ui-popout-buffer (list 'report id))))

(defun harness-media--review-threads (review id)
  "Give REVIEW, that of task ID, the threads the pictures show, once."
  (unless harness-media--review
    (setq user-full-name "Noah Huppert" user-mail-address "noah@acme.example")
    (let* ((set (harness-ui-patch-review--r-set review))
           (worktree (plist-get (harness-media--task id) :worktree))
           (sid (plist-get (harness-media--task id) :session))
           ;; The commit the first round handed in: the first of the branch.
           (first-tip (car (split-string (harness-media--git-in worktree "rev-list" "--reverse" "main..HEAD"))))
           (call (cl-loop for node in (harness-call 'session/nodes sid)
                          when (and (eq (plist-get node :kind) 'tool-call)
                                    (equal (plist-get node :tool) "edit_file"))
                          return (plist-get node :call-id)))
           (agent (change-review-agent "Claude (Fable 5.1)" :session sid :tool-call call))
           (you (change-review-user "Noah Huppert" "noah@acme.example"))
           (file (lambda (path) (cl-find path (harness-ui-patch-review--r-files review)
                                         :key #'change-review-file-path :test #'equal)))
           (where (lambda (path text &optional side)
                    (harness-ui-patch-review--location
                     (funcall file path) (cons (or side :new) (harness-media--review-line text path)))))
           (threshold (change-review-comment
                       set "Is **half a second** the right threshold? The dashboards alert at `400 ms`."
                       :author you :time (harness-media--ago 95) :sent (harness-media--ago 94)
                       :revision first-tip :location (funcall where "acme/timing.py" "SLOW_SECONDS = ")))
           (resolution (change-review-comment
                        set "Is whole-millisecond resolution enough for the log line?"
                        :author you :time (harness-media--ago 93) :sent (harness-media--ago 92)
                        :revision first-tip :location (funcall where "acme/timing.py" "elapsed \\* 1000"))))
      (change-review-reply set threshold
                           (concat "Half a second is the objective in `docs/slo.md`, so I:\n\n"
                                   "- made it a named constant, `SLOW_SECONDS`\n"
                                   "- said in a comment that it is in seconds")
                           :author agent :time (harness-media--ago 50) :sent (harness-media--ago 50))
      (change-review-reply set threshold "Fine, but please **link** the document in the comment."
                           :author you :time (harness-media--ago 3))
      (change-review-reply set resolution "At a `500 ms` threshold whole milliseconds are enough."
                           :author agent :time (harness-media--ago 50) :sent (harness-media--ago 50))
      (change-review-close set (change-review-comment-thread resolution)
                           :author you :time (harness-media--ago 40))
      ;; Two threads the agent answered and closed: they wait for the
      ;; reviewer to look (the one `resolution' the user closed does not).
      (let ((rename (change-review-comment
                     set "Why rename `application`? The WSGI server imports it by that name."
                     :author you :time (harness-media--ago 88) :sent (harness-media--ago 87)
                     :revision first-tip :location (funcall where "acme/app.py" "def _application")))
            (clock (change-review-comment
                    set "Why time.monotonic() and not time.time()?"
                    :author you :time (harness-media--ago 91) :sent (harness-media--ago 90)
                    :revision first-tip :location (funcall where "acme/timing.py" "started = time.monotonic"))))
        (change-review-reply set rename
                             (concat "It still exists: the last line of the module binds it to the timed one, "
                                     "so imports keep working:\n\n"
                                     "```python\napplication = timed(_application)\n```")
                             :author agent :time (harness-media--ago 50) :sent (harness-media--ago 50))
        (change-review-close set (change-review-comment-thread rename)
                             :author agent :time (harness-media--ago 49))
        (change-review-reply set clock "The wall clock can step while a request runs, and the log would show a negative or a huge time. The monotonic one only goes forward."
                             :author agent :time (harness-media--ago 50) :sent (harness-media--ago 50))
        (change-review-close set (change-review-comment-thread clock)
                             :author agent :time (harness-media--ago 49)))
      ;; Closed by the agent and reviewed already, the thread the Ediff
      ;; picture leaves as one line.
      (let ((auth (change-review-comment
                   set "Is the authentication inside the time that is logged? A slow key lookup would count."
                   :author you :time (harness-media--ago 86) :sent (harness-media--ago 85)
                   :revision first-tip :location (funcall where "acme/app.py" "key = authenticate"))))
        (change-review-reply set auth "Yes, on purpose: the middleware wraps the whole application, so a slow lookup is what the log shows."
                             :author agent :time (harness-media--ago 50) :sent (harness-media--ago 50))
        (change-review-close set (change-review-comment-thread auth)
                             :author agent :time (harness-media--ago 49))
        (change-review-mark-reviewed set (change-review-comment-thread auth) :time (harness-media--ago 40)))
      (change-review-comment set "Should the health check be timed too? A slow probe would fill the log."
                             :author you :time (harness-media--ago 2)
                             :location (funcall where "acme/app.py" "application = timed"))
      (harness-media--settle 1.5)
      (setq harness-media--review review))))

(defun harness-media-shot-review ()
  "A task in review, its report at the changes: the files as a tree, the threads below.
The threads are the library's, kept by the harness: the user's comments,
the agent's answers, a draft, and the round of feedback from before
there were threads, closed.  They are a section under the files, in the
same buffer."
  (let ((popout (harness-media--review-layout)))
    (with-selected-window (get-buffer-window popout)
      (goto-char (point-min))
      (re-search-forward "^Changes (")
      (beginning-of-line)
      (recenter 0))
    (harness-media--fit-popout-shot 42)
    (with-selected-window (get-buffer-window popout)
      (goto-char (point-min))
      (re-search-forward "^Changes (")
      (beginning-of-line)
      (recenter 0))
    (harness-media--capture "review")))

(defun harness-media-shot-review-threads ()
  "The threads of that review, a section of its report below the files: each message with who, when and its place.
The filter shows them all, the closed one too; where one comment was made
shows under it, with the lines of the diff it was made on; the agent's
answer links to the conversation it came from."
  (let ((popout (harness-media--review-layout)))
    (with-selected-window (get-buffer-window popout)
      (change-review-ui-set-filter 'all)
      (harness-media--settle 0.5)
      (goto-char (point-min))
      (search-forward "Is half a second")
      (call-interactively #'change-review-ui-show-origin)
      (goto-char (point-min))
      (re-search-forward "^Threads ")
      (beginning-of-line))
    (harness-media--fit-popout-shot 56)
    (with-selected-window (get-buffer-window popout)
      (goto-char (point-min))
      (re-search-forward "^Threads ")
      (beginning-of-line)
      (recenter 0))
    (harness-media--capture "review-threads")))

(defun harness-media-shot-review-banner ()
  "The session of the task in review, its banner showing the changes: the files as a tree, the threads below.
The work is looked over where it was handed in, with no click on
[Review Changes]: the tree has the marks of the files already looked at
and approved, the threads the user's comments and the agent's answers,
and [Verify] and [Send back] are under them."
  (harness-media--review-prepare)
  (harness-media--reset-layout)
  (set-frame-size nil harness-media-columns harness-media-lines)
  (harness-media--settle 0.5)
  (let* ((id (plist-get (plist-get harness-media--world :tasks) :slow))
         (sid (plist-get (harness-media--task id) :session))
         (buffer (harness-media--open-chat sid 'full))
         (review (harness-media--wait
                  (lambda ()
                    (let ((review (gethash id harness-ui-patch-review--reviews)))
                      (and review (harness-ui-patch-review--r-tip review)
                           (= 2 (length (harness-ui-patch-review--r-files review))) review)))
                  30 "the banner to read the branch")))
    (harness-media--review-threads review id)
    ;; The first file was looked at and approved, the second not.
    (let ((file (car (harness-ui-patch-review--r-files review))))
      (harness-ui-patch-review--approve review file t t))
    (harness-ui-patch-review--refresh review t)
    (harness-media--settle 1.5)
    (let ((window (get-buffer-window buffer)))
      ;; The banner from its changes to the box, in a window as high as that.
      (with-current-buffer buffer
        (goto-char harness-chat--transcript-end)
        (re-search-forward "^Changes (")
        (beginning-of-line)
        (let ((lines (count-screen-lines (point) (point-max) nil window)))
          (set-frame-size nil harness-media-columns (min harness-media-lines (+ 4 lines)))))
      (harness-media--settle 1)
      (with-selected-window window
        (goto-char harness-chat--transcript-end)
        (re-search-forward "^Changes (")
        (beginning-of-line)
        (set-window-start window (point))
        (goto-char (point-max))))
    (harness-media--settle 0.5)
    (harness-media--capture "review-banner")))

(defun harness-media-shot-review-ediff ()
  "Ediff on a file of that review: the files as a tree beside it, the threads under their lines, the box under it.
The tree on the left has the marks of the files and the file compared
highlighted, the threads below it; the version on the branch shows the
threads of acme/app.py at the line each is on now, drawn to the width of
the window: a closed thread is one line, the one the agent closed, and
the one the reviewer closed is opened to its conversation (TAB); the
control panel offers to comment, reply, fold a thread and go to the
threads, and its settings skip the files approved and approve those gone
through."
  (let ((popout (harness-media--review-layout)))
    (ignore popout)
    (let* ((review harness-media--review)
           (files (harness-ui-patch-review--r-files review))
           (index (cl-position "acme/app.py" files :key #'change-review-file-path :test #'equal))
           (set (harness-ui-patch-review--r-set review))
           (rename (cl-find-if (lambda (thread)
                                 (string-search "Why rename application"
                                                (change-review-comment-body (change-review-thread-root thread))))
                               (change-review-set-threads set))))
      (harness-ui-patch-review-ediff review index
                                     (cons :new (harness-media--review-line "def _application" "acme/app.py")))
      (harness-media--wait (lambda () (let ((state (harness-ui-patch-review--r-ediff review)))
                                        (and (buffer-live-p (plist-get state :control))
                                             (get-buffer-window (plist-get state :control)))))
                           30 "Ediff to show")
      (harness-media--settle 1)
      ;; Closed threads are one line; the reviewer opens the one to read.
      (change-review-ui-set-fold set rename 'expanded)
      (change-review-ui-flush)
      (let ((window (get-buffer-window (plist-get (harness-ui-patch-review--r-ediff review) :b))))
        (with-selected-window window
          (goto-char (point-min))
          (forward-line (1- (harness-media--review-line "def _application" "acme/app.py")))
          (recenter 1)))
      (harness-media--settle 1.5)
      (harness-media--capture "review-ediff")
      ;; Back to the report, as q gives it.
      (with-current-buffer (plist-get (harness-ui-patch-review--r-ediff review) :control)
        (call-interactively #'harness-ui-patch-review-ediff-quit))
      (harness-media--settle 0.5))))

(defun harness-media-shot-review-to-review ()
  "The threads view on its filter `to review': what the agent closed, and its answers.
The reviewer has not looked at these two threads yet, so they wait for
them; the one the reviewer closed themselves is not here."
  (let ((popout (harness-media--review-layout)))
    (ignore popout)
    (harness-media--reset-layout)
    (let ((buffer (change-review-open-threads
                   (harness-ui-patch-review--r-set harness-media--review) 'unreviewed)))
      (delete-other-windows)
      (with-current-buffer buffer
        (goto-char (point-min))
        (search-forward "It still exists")
        (beginning-of-line))
      (harness-media--settle 1)
      (harness-media--fit (harness-media--text-lines (selected-window)) nil 60)
      (set-window-start nil (point-min))
      (harness-media--settle 0.5))
    (harness-media--capture "review-to-review")))

(defun harness-media--review-diff-read-p (review selector)
  "Non-nil when REVIEW shows the diff SELECTOR, read and its threads placed."
  (and (not (harness-ui-patch-review--r-loading review))
       (not (harness-ui-patch-review--r-placing review))
       (equal selector (harness-ui-patch-review--r-shown-selector review))))

(defun harness-media-shot-review-diff ()
  "That report with the diff chosen since the last review: only what the work changed since.
The Diff line marks the choice.  The files are those the diff changes, each
with its threads; the threads of the files it leaves out are among the
other threads, each with its file.  Taken after the other review pictures:
it puts the report back at the branch against main when it is done."
  (let* ((popout (harness-media--review-layout))
         (review harness-media--review)
         (heading (lambda ()
                    (with-selected-window (get-buffer-window popout)
                      (goto-char (point-min))
                      (re-search-forward "^Changes (")
                      (beginning-of-line)
                      (recenter 0)))))
    (harness-ui-patch-review-select-diff 'since-review review)
    (harness-media--wait (lambda () (harness-media--review-diff-read-p review 'since-review))
                         30 "the diff since the last review")
    (harness-media--settle 1.5)
    (funcall heading)
    (harness-media--fit-popout-shot 42)
    (funcall heading)
    (harness-media--capture "review-diff")
    (harness-ui-patch-review-select-diff 'base review)
    (harness-media--wait (lambda () (harness-media--review-diff-read-p review nil))
                         30 "the branch against main again")
    (harness-media--settle 0.5)))
;;;; Quoting a comment of the review

(declare-function change-review-ui-mouse-select "change-review-ui")
(declare-function change-review-ui--overlay-selection "change-review-ui")

(defun harness-media--overlay-xy (window overlay text &optional after)
  "Return (X . Y), pixels in WINDOW over TEXT of the string OVERLAY shows.
AFTER counts characters into TEXT.  OVERLAY is a thread drawn under a line
in WINDOW's buffer; Y is the middle of the row TEXT is on.  The overlay's
position is the end of the line its text follows, shown after its last
row, which says where the rows are."
  (let* ((string (overlay-get overlay 'after-string))
         (index (+ (or (string-search text string) (error "No %S under the line" text)) (or after 0)))
         (rows (1+ (cl-count ?\n string)))
         (row (cl-count ?\n (substring string 0 index)))
         (start (let ((newline (cl-position ?\n string :end index :from-end t)))
                  (if newline (1+ newline) 0)))
         (height (frame-char-height (window-frame window)))
         (width (frame-char-width (window-frame window)))
         (last (cdr (posn-x-y (posn-at-point (overlay-start overlay) window)))))
    (cons (+ (* (- index start) width) (/ width 2))
          (+ (- last (* (- rows 1 row) height)) (/ height 2)))))

(defun harness-media--drag (window from to)
  "Press the mouse in WINDOW at FROM, (X . Y) pixels, drag it to TO and let go.
The events are those the display gives the command a press runs, made here
for pixels of the frame, so the text the mouse is over is the text a user's
would be."
  (let ((start (posn-at-x-y (car from) (cdr from) window))
        (end (posn-at-x-y (car to) (cdr to) window)))
    (setq unread-command-events
          (list (list 'mouse-movement end) (list 'drag-mouse-1 start end)))
    (let ((this-command 'change-review-ui-mouse-select))
      (change-review-ui-mouse-select (list 'down-mouse-1 start)))
    (harness-media--settle 0.3)))

(defun harness-media-shot-review-quote ()
  "A part of the agent's answer in the review, selected with the mouse and quoted.
Ediff on acme/app.py, the thread on the renamed function under its line in
the branch's version.  The mouse is dragged over the end of the agent's
answer, which a region could not hold, the thread being a string an
overlay shows: the selection is marked (`review-select').  Then C-c >:
the reply opens in a buffer of its own with the part quoted, point under
it, and an answer is typed (`review-quote')."
  (let ((popout (harness-media--review-layout)))
    (ignore popout)
    (let* ((review harness-media--review)
           (files (harness-ui-patch-review--r-files review))
           (index (cl-position "acme/app.py" files :key #'change-review-file-path :test #'equal)))
      (harness-ui-patch-review-ediff review index
                                     (cons :new (harness-media--review-line "def _application" "acme/app.py")))
      (harness-media--wait (lambda () (let ((state (harness-ui-patch-review--r-ediff review)))
                                        (and (buffer-live-p (plist-get state :control))
                                             (get-buffer-window (plist-get state :control)))))
                           30 "Ediff to show")
      (harness-media--settle 1.5)
      (let* ((state (harness-ui-patch-review--r-ediff review))
             (version (plist-get state :b))
             (window (get-buffer-window version))
             (overlay (with-current-buffer version
                        (cl-find-if (lambda (o) (and (overlay-get o 'change-review-thread)
                                                     (string-search "Why rename application"
                                                                    (or (overlay-get o 'after-string) ""))))
                                    (overlays-in (point-min) (point-max))))))
        (unless overlay (error "The thread on the renamed function is not drawn"))
        ;; The version is given room, from the merge base's window above it,
        ;; so that the thread is in sight whole with the reply opened under
        ;; it; and the line the thread is under is at its top.
        (ignore-errors (window-resize window 8))
        (with-current-buffer version
          (goto-char (overlay-start overlay))
          (set-window-point window (point))
          (set-window-start window (line-beginning-position 0)))
        (harness-media--settle 0.5)
        ;; From where the answer says what the line is, to where it ends.
        (harness-media--drag window
                             (harness-media--overlay-xy window overlay "the last line of the module")
                             (harness-media--overlay-xy window overlay "so imports keep working" 23))
        (with-current-buffer version
          (unless (change-review-ui--overlay-selection) (error "The drag selected nothing")))
        (harness-media--capture "review-select")
        ;; C-c > from the version, where the mouse selected.
        (select-window window)
        (let ((this-command 'change-review-ui-mouse-select))
          (harness-media--keys "C-c >"))
        (harness-media--type "Then say so in a comment above the line, so the next reader does not ask.")
        (harness-media--capture "review-quote")
        ;; Give the reply up, and Ediff, as the other pictures leave them.
        (harness-media--keys "C-c C-k")
        (with-current-buffer (plist-get (harness-ui-patch-review--r-ediff review) :control)
          (call-interactively #'harness-ui-patch-review-ediff-quit))
        (harness-media--settle 0.5)))))

(defconst harness-media-shots
  '(("chat" . harness-media-shot-chat)
    ("chat-permission" . harness-media-shot-chat-permission)
    ("chat-question" . harness-media-shot-chat-question)
    ("attachments" . harness-media-shot-attachments)
    ("compose-chips" . harness-media-shot-compose-chips)
    ("tasks" . harness-media-shot-tasks)
    ("tasks-search" . harness-media-shot-tasks-search)
    ("quick-search" . harness-media-shot-quick-search)
    ("tasks-long" . harness-media-shot-tasks-long)
    ("tasks-message" . harness-media-shot-tasks-message)
    ("report" . harness-media-shot-report)
    ("report-image" . harness-media-shot-report-image)
    ("sessions" . harness-media-shot-sessions)
    ("popout-permission" . harness-media-shot-popout-permission)
    ("popout-question" . harness-media-shot-popout-question)
    ("tree" . harness-media-shot-tree)
    ("usage" . harness-media-shot-usage)
    ("usage-projects" . harness-media-shot-usage-projects)
    ("usage-worktrees" . harness-media-shot-usage-worktrees)
    ("worktrees" . harness-media-shot-worktrees)
    ("settings" . harness-media-shot-settings)
    ("settings-policy" . harness-media-shot-settings-policy)
    ("btw" . harness-media-shot-btw)
    ("menu" . harness-media-shot-menu)
    ("remote" . harness-media-shot-remote)
    ("version" . harness-media-shot-version)
    ;; Last: they write a month of chats the other pictures must not show.
    ("insights" . harness-media-shot-insights)
    ("insights-activity" . harness-media-shot-insights-activity)
    ;; A live sub-agent and the long command it runs: after the usage
    ;; pictures, whose numbers its session would join.
    ("notes" . harness-media-shot-notes)
    ;; Sessions of their own too, made and deleted for the picture.
    ("chat-queue" . harness-media-shot-chat-queue)
    ("prompt-region" . harness-media-shot-prompt-region)
    ;; After every picture of usage: its session's usage would count there.
    ("chat-cowboy" . harness-media-shot-chat-cowboy)
    ;; Last: an "Always deny" and an "always" cold-cache answer, both
    ;; undone again after, but taken last all the same.
    ("chat-decisions" . harness-media-shot-chat-decisions)
    ("chat-decisions-cold" . harness-media-shot-chat-decisions-cold)
    ;; Last: it sets a limit, starts a task and queues four, which every
    ;; board picture would show, and their usage would count.
    ("slots" . harness-media-shot-slots)
    ;; And after that one: these make sessions of their own, whose usage
    ;; would count in the usage pictures' totals.
    ("chat-denied" . harness-media-shot-chat-denied)
    ("chat-denied-approved" . harness-media-shot-chat-denied-approved)
    ;; Likewise: they ask a session of their own, deleted after the picture.
    ("quote-reply" . harness-media-shot-quote-reply)
    ("quote-thread" . harness-media-shot-quote-thread)
    ("access" . harness-media-shot-access)
    ("access-judgements" . harness-media-shot-access-judgements)
    ;; Last: they add a commit to the slow-request task's branch and the
    ;; threads of its review, which no other picture shows.
    ("review" . harness-media-shot-review)
    ("review-threads" . harness-media-shot-review-threads)
    ("review-banner" . harness-media-shot-review-banner)
    ("review-ediff" . harness-media-shot-review-ediff)
    ("review-to-review" . harness-media-shot-review-to-review)
    ;; After them: it chooses another diff, and puts the first back.
    ("review-diff" . harness-media-shot-review-diff)
    ;; It takes review-select on the way.
    ("review-quote" . harness-media-shot-review-quote))
  "Every picture, as (NAME . FUNCTION), in the order they are taken.")

;;;; Entry point

(defun harness-media--setup-look ()
  "Dress the frame for the pictures."
  (setq inhibit-startup-screen t
        ring-bell-function #'ignore
        use-dialog-box nil
        ;; The demo project sits under this checkout (the scratch HOME is
        ;; in scripts/.dev/media), so visiting its files finds the
        ;; checkout's .dir-locals.el, and Emacs would ask whether to trust
        ;; its entries, on a display nobody watches, until the run timed out.
        enable-local-variables :safe
        frame-inhibit-implied-resize t
        cursor-in-non-selected-windows nil
        confirm-kill-processes nil
        make-backup-files nil
        auto-save-default nil
        create-lockfiles nil)
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (blink-cursor-mode -1)
  (tooltip-mode -1)
  (load-theme harness-media-theme t)
  (when (member harness-media-font (font-family-list))
    (set-face-attribute 'default nil :family harness-media-font))
  (set-face-attribute 'default nil :height harness-media-font-height)
  (set-frame-size nil harness-media-columns harness-media-lines))

(defun harness-media--setup-harness ()
  "Start the harness of this checkout, isolated, with the scripted providers."
  (dolist (pair harness-media-identity)
    (setenv (car pair) (cdr pair)))
  (add-to-list 'load-path harness-media-root)
  (setq harness-state-directory (expand-file-name "~/.emacs.d/harness/")
        ;; No policy of this machine's (/etc/harness/policy.el) reaches the
        ;; pictures; the settings-policy picture brings its own.
        harness-policy-file nil
        harness-process nil
        ;; The pictures show every feature.
        harness-enabled-modules t
        ;; Every agent is scripted, so recaps are seeded for the pictures
        ;; instead (`harness-media--seed-recaps').  A busy machine --
        ;; this run's own, or whatever else it is doing -- would have
        ;; `tool-slots-load' note "Tool slots reduced from 18 to 5" in
        ;; every active chat, and push the top of a picture off, and
        ;; pin "Tool slots limited to 5 of 18" above every compose box:
        ;; the pictures do not depend on the machine's load.
        harness-disabled-modules '(provider-claude provider-copilot provider-openai provider-bedrock provider-demo
                                                   recap tool-slots-load))
  (harness-media--harness-origins)
  (require 'harness)
  (unless (harness-start) (error "The harness did not start cleanly"))
  ;; The scripted turns read and write the prompt cache, and a cache that
  ;; lapsed puts a panel above the box: however long the run takes, no
  ;; picture shows one by chance.
  (setq harness-cache-ttl 86400)
  ;; Chats take half the frame: the code beside them keeps 80 columns.
  (setf (alist-get 'right harness-ui-positions) '((side . right) (slot . 0) (window-width . 0.5)))
  ;; The pictures show hands-on sessions -- the scripted turns write
  ;; files and run commands themselves -- so nothing in this world
  ;; supervises.  Without this a new session supervises by default and
  ;; is offered no write tools, and every task and chat picture is taken
  ;; over work no script could do.
  (setq harness-supervisor nil
        harness-supervisor-tasks nil)
  (harness-media--define-providers)
  (harness-media--settle 1))

(defun harness-media-run ()
  "Build the world, take the pictures and exit."
  (condition-case err
      (progn
        (harness-media--setup-look)
        (harness-media--setup-harness)
        (harness-media--build-world)
        (dolist (shot harness-media-shots)
          (when (or (null harness-media-only) (member (car shot) harness-media-only))
            (condition-case err
                (funcall (cdr shot))
              (error (push (cons (car shot) err) harness-media-failures)
                     (harness-media--log "%s failed: %s" (car shot) (error-message-string err)))))))
    (error (push (cons "world" err) harness-media-failures)
           (harness-media--log "failed: %s" (error-message-string err))))
  (kill-emacs (if harness-media-failures 1 0)))

(defun harness-media-main ()
  "Take the README pictures, as `scripts/media.sh' asks; then exit Emacs.
The work starts once Emacs has finished starting up."
  (condition-case err
      (progn
        (setq harness-media-output (file-name-as-directory
                                    (or (getenv "HARNESS_MEDIA_OUT")
                                        (expand-file-name "docs/media" harness-media-root)))
              harness-media-dumps (let ((d (getenv "HARNESS_MEDIA_DUMPS")))
                                    (and d (not (string-empty-p d)) (file-name-as-directory d)))
              harness-media-only (split-string (or (getenv "HARNESS_MEDIA_SHOTS") "") "[ ,]+" t)
              harness-media-project (expand-file-name "~/src/acme-api/"))
        (unless (display-graphic-p) (error "The pictures need a graphical display"))
        ;; Nobody moves the pointer, so what happens to lie under it must
        ;; not light up in a picture as if hovered.
        (setq mouse-highlight nil)
        (dolist (name harness-media-only)
          (unless (assoc name harness-media-shots) (error "No picture is called %s" name)))
        (make-directory harness-media-output t)
        (when harness-media-dumps (make-directory harness-media-dumps t))
        ;; The same ids and history on every run.
        (random "harness-media")
        (run-with-timer 0.5 nil #'harness-media-run))
    (error (harness-media--log "%s" (error-message-string err))
           (kill-emacs 1))))

(provide 'harness-media)
;;; harness-media.el ends here
