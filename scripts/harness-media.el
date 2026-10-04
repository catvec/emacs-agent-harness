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
(defconst harness-media-lines 54 "Frame height in lines, unless a shot asks for another.")
(defconst harness-media-delay 0.02 "Seconds between the events of a scripted turn.")

(defconst harness-media-identity
  '(("GIT_AUTHOR_NAME" . "Sam Rivera") ("GIT_AUTHOR_EMAIL" . "sam@acme.example")
    ("GIT_COMMITTER_NAME" . "Sam Rivera") ("GIT_COMMITTER_EMAIL" . "sam@acme.example"))
  "Who commits in the demo project, tasks and merges included.")

(defvar harness-media-project nil "Root of the demo project.")
(defvar harness-media-failures nil "Shots that failed, as (NAME . ERROR).")
(defvar harness-media--world nil "Plist naming the sessions and tasks of the world.")

;; Harness variables set or read here.
(defvar harness-state-directory)
(defvar harness-process)
(defvar harness-disabled-modules)
(defvar harness-ui-positions)
(defvar harness-ui-default-position)
(defvar harness-ui--position-buffers)
(defvar harness-ui-tasks--target)
(defvar harness-chat--blocks)
(defvar harness-chat--loading)
(defvar harness-chat--order)
(defvar harness-sessions)
(defvar harness-ui-tasks--tasks)

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
(declare-function harness-chat-block-node "harness-ui-chat")
(declare-function harness-chat-block-collapsed "harness-ui-chat")
(declare-function harness-compose-set "harness-ui-compose")
(declare-function harness-compose-repad "harness-ui-compose")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-ui-tasks-requests "harness-ui-tasks")
(declare-function harness-ui-tasks-reply "harness-ui-tasks")
(declare-function harness-ui-tasks--find "harness-ui-tasks")
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
(declare-function harness-worktrees "harness-ui-worktree")
(declare-function harness-settings "harness-ui-config")
(declare-function harness-tasks--set "harness-tasks")
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

(defun harness-media--hero-script (_request)
  "The turn of the hero picture: rate limiting, from reading to tests."
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
  "The turn of the fork in the hero's tree."
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
  "The answer of the BTW over the hero."
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

(defun harness-media--task-script (todos changes message summary &optional hold evidence)
  "A task's turn: TODOS, CHANGES (tool calls), a commit as MESSAGE, SUMMARY.
TODOS are the item texts.  With HOLD the turn stops working half way
and never ends, so the task stays in progress, and nothing is committed.
With EVIDENCE, hand_in's evidence items, the turn hands its work in
with SUMMARY rather than saying it."
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
                        (harness-media--tool "hand_in" :summary summary :evidence evidence))
                (list (harness-media--say summary)))))))

(defun harness-media--task-constant-time (_request)
  "Task: constant-time key checks."
  (harness-media--task-script
   '("Find where keys are compared" "Compare them with hmac.compare_digest")
   (list (harness-media--tool "read_file" :path "acme/auth.py")
         (harness-media--tool "write_file" :path "acme/auth.py" :content harness-media--auth-constant-time))
   "Compare API keys in constant time"
   "`authenticate()` now compares the key with every known key through `hmac.compare_digest`."))

(defun harness-media--task-python (_request)
  "Task: require Python 3.12."
  (harness-media--task-script
   '("Raise requires-python" "List the supported versions")
   (list (harness-media--tool "read_file" :path "pyproject.toml")
         (harness-media--tool "edit_file" :path "pyproject.toml"
                              :old_string "requires-python = \">=3.11\"\n"
                              :new_string "requires-python = \">=3.12\"\nclassifiers = [\n    \"Programming Language :: Python :: 3.12\",\n    \"Programming Language :: Python :: 3.13\",\n]\n"))
   "Require Python 3.12"
   "pyproject.toml requires Python 3.12 and lists 3.12 and 3.13."))

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
           (list :tool_call (plist-get tests :id) :caption "The tests pass, the total included.")))))

(defun harness-media--task-slow (_request)
  "Task: log slow requests."
  (harness-media--task-script
   '("Time every request" "Log the slow ones")
   (list (harness-media--tool "read_file" :path "acme/app.py")
         (harness-media--tool "write_file" :path "acme/timing.py" :content harness-media--timing))
   "Log slow requests"
   "`acme.timing.timed()` wraps the app and logs every request slower than 500 ms."))

(defun harness-media--task-slow-again (_request)
  "Task: log slow requests, after review."
  (list (harness-media--tool "edit_file" :path "acme/timing.py"
                             :old_string "SLOW_SECONDS = 0.5" :new_string "SLOW_SECONDS = 0.5  # seconds")
        (harness-media--git-commit "Say the threshold is in seconds")
        (harness-media--say "The threshold says it is in seconds now.")))

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

(defconst harness-media--titles
  '(("hmac" . "Constant-time API key checks")
    ("requires-python" . "Require Python 3.12")
    ("limit/offset" . "Paginate GET /orders")
    ("slower than" . "Log slow requests")
    ("typed config" . "Validate settings at startup")
    ("OpenAPI" . "Write the OpenAPI schema")
    ("/health" . "Add a /health endpoint")
    ("csv" . "Export orders as CSV")
    ("retry" . "Retry failed webhooks"))
  "Titles the scripted naming gives, by a regexp of the first message.")

(defconst harness-media--scripts
  '(("Rate-limit the orders API" . harness-media--hero-script)
    ("sliding-window" . harness-media--fork-script)
    ("hits the limit" . harness-media--btw-script)
    ("tell subscribers" . harness-media--webhooks-script)
    ("webhook sender" . harness-media--permission-script)
    ("slowest" . harness-media--slowest-script)
    ("Cache the catalogue" . harness-media--question-script)
    ("docs/api.md" . harness-media--api-guide-script)
    ("one time in ten" . harness-media--flaky-script)
    ("reviewed your work" . harness-media--task-slow-again)
    ("hmac" . harness-media--task-constant-time)
    ("requires-python" . harness-media--task-python)
    ("limit/offset" . harness-media--task-pagination)
    ("slower than" . harness-media--task-slow)
    ("typed config" . harness-media--task-settings)
    ("OpenAPI" . harness-media--task-openapi)
    ("Hold this turn" . harness-media--hold-script)
    ("/health" . harness-media--task-health))
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
tool and asks again, and the script goes on from there."
  (let* ((on-event (plist-get request :on-event))
         (sid (or (plist-get (plist-get request :session) :id) "none"))
         (rest (if (harness-media--continuing-p request) (gethash sid harness-media--rest 'none) 'none))
         (script (if (eq rest 'none) (harness-media--script request) rest))
         (written 0) (reported nil) (cancelled nil) (timer nil))
    (remhash sid harness-media--rest)
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
                        ('tool-call (emit event) (puthash sid script harness-media--rest) (finish 'tool-use))
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
                    ;; more of its script: the next request -- naming the
                    ;; session, say -- must not get the rest.
                    (remhash sid harness-media--rest)
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

(defun harness-media--hold-script (_request)
  "A turn that never ends: the merge queue's parent, kept busy for the board picture."
  (list (list :type 'hold)))

(defun harness-media--hold-merge-session ()
  "Keep the task project's merge session busy, so a merged branch waits in the queue.
The picture of the board then has a task in its merging section."
  (let ((merger (cl-find "Task merges" (harness-call 'session/list)
                         :key (lambda (s) (plist-get s :name)) :test #'equal)))
    (when merger
      (harness-media--prompt (plist-get merger :id) "Hold this turn while the picture is taken." '(running)))))

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
      ;; With the merge session busy, the verified branch waits in the queue.
      (harness-media--hold-merge-session)
      (harness-call 'task/verify pagination)
      (harness-media--wait-task pagination (lambda (task) (equal (harness-media--column task) "merging"))
                                "to wait in the merge queue")
      (harness-call 'task/reject slow "Say which unit the threshold is in.")
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
  (let ((hero (harness-media--new-session :name "Rate-limit the orders API" :model "claude:claude-fable-5-1"
                                          :permission-mode 'auto :thinking "high")))
    (harness-media--prompt hero "Rate-limit the orders API: 100 requests a minute per API key, with a small burst. Over the limit, answer 429 with a Retry-After header.")
    ;; A fork from where the agent had read the code, and a BTW.
    (let* ((nodes (harness-call 'session/nodes hero))
           (head (plist-get (harness-media--session hero) :head))
           (branch (plist-get (cl-find-if (lambda (n) (and (equal (format "%s" (plist-get n :kind)) "assistant")
                                                           (string-prefix-p "`application()`" (or (plist-get n :content) ""))))
                                          nodes)
                              :id)))
      (harness-call 'session/set-head hero branch)
      (let ((fork (plist-get (harness-await (harness-as-promise
                                             (harness-call 'session/fork hero :kind 'fork :name "Sliding-window limiter"))
                                            30)
                             :id)))
        (harness-call 'session/set-head hero head)
        (harness-media--prompt fork "Try a sliding-window log instead, so a key can never make more than 100 requests in any 60 seconds.")
        (let ((btw (plist-get (harness-call 'session/btw hero "What does a client see?") :id)))
          (harness-media--prompt btw "What does a client see when it hits the limit?")
          (setq harness-media--world (append (list :hero hero :fork fork :btw btw) harness-media--world))))))
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
    (harness-call 'usage/set-budget (append (list :amount (max 1.0 (fceiling (/ (funcall spent week) 0.42)))) week))
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
    (pcase-dolist (`(,key ,created ,updated)
                   '((:guide 2900 2870) (:flaky 5800 5790) (:hero 7 0.2) (:fork 3 2) (:btw 1 0.5)
                     (:permission 9 8) (:question 15 14)))
      (harness-media--set-times (plist-get harness-media--world key) created updated))
    (pcase-dolist (`(,key ,minutes) '((:hero 5) (:fork 2) (:btw 0.6)))
      (harness-media--age-nodes (plist-get harness-media--world key) minutes))
    ;; The session tasks merge into, made by the first merge.
    (maphash (lambda (id _session)
               (when (equal (plist-get (harness-media--session id) :name) "Task merges")
                 (harness-media--set-times id 1560 140)))
             harness-sessions)
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
  "Say session ID was created CREATED and updated UPDATED minutes ago."
  (when-let* ((s (gethash id harness-sessions)))
    (aset s (cl-struct-slot-offset 'harness-session 'created) (harness-media--ago created))
    (aset s (cl-struct-slot-offset 'harness-session 'updated) (harness-media--ago updated))))

(defun harness-media--build-world ()
  "Make everything the pictures show."
  (harness-media--log "building the demo project")
  (harness-media--make-project)
  (harness-media--seed-usage)
  (harness-media--seed-budgets)
  (harness-media--log "running the tasks")
  (harness-media--build-tasks)
  (harness-media--log "running the conversations")
  (harness-media--build-sessions)
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

(defun harness-media--hero-layout (id)
  "Show acme/ratelimit.py on the left and the chat of session ID on the right."
  (harness-media--reset-layout)
  (harness-media--show-file "acme/ratelimit.py" "^class TokenBucket")
  (let ((buffer (harness-media--open-chat id 'right)))
    (harness-media--expand buffer "bash")
    (harness-media--to-bottom buffer)
    buffer))

(defun harness-media-shot-chat ()
  "The hero: code on the left, a finished turn on the right."
  (harness-media--hero-layout (plist-get harness-media--world :hero))
  (harness-media--capture "chat"))

(defun harness-media-shot-chat-permission ()
  "A chat waiting for permission to run a command."
  (harness-media--chat-shot (plist-get harness-media--world :permission) "acme/webhooks.py")
  (harness-media--capture "chat-permission"))

(defun harness-media-shot-chat-question ()
  "A chat waiting for the answer to a question."
  (harness-media--chat-shot (plist-get harness-media--world :question) "acme/app.py")
  (harness-media--capture "chat-question"))

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
`harness-media-lines') lines."
  (set-frame-size nil harness-media-columns
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
sends to, so it cannot be taken for the one that writes a new task."
  (harness-media--view (lambda () (harness-tasks harness-media-project 'full)))
  (let* ((id (plist-get (plist-get harness-media--world :tasks) :settings))
         (window (selected-window)))
    (with-current-buffer (window-buffer window)
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
      (set-window-start window (point-min))))
  (harness-media--capture "tasks-message"))

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

(defun harness-media-shot-sessions ()
  "The session list."
  (harness-media--view #'harness-sessions)
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

(defun harness-media--fit-popout-shot (most)
  "Size the frame for a view with a popout under it, at most MOST lines.
The frame is fitted to the text of every window, so the view and the
popout both show; the popout is a side window and keeps its height."
  (set-frame-size nil harness-media-columns
                  (min (or most harness-media-lines)
                       (max 24 (+ 6 (cl-loop for w in (window-list nil 'nomini)
                                             sum (harness-media--text-lines w))))))
  (harness-media--settle 1))

(defun harness-media-shot-popout-permission ()
  "The session list, with the permission a blocked session waits for popped out."
  (harness-media--view #'harness-sessions)
  (harness-media--goto-session-row (plist-get harness-media--world :permission))
  (harness-ui-sessions-requests)
  (harness-media--fit-popout-shot 32)
  (harness-media--capture "popout-permission"))

(defun harness-media-shot-popout-question ()
  "The task board, with the question a task's session waits on popped out."
  (harness-media--view (lambda () (harness-tasks harness-media-project 'full)))
  (harness-media--goto-task-card (plist-get (plist-get harness-media--world :tasks) :health))
  (harness-ui-tasks-requests)
  (harness-media--fit-popout-shot 32)
  (harness-media--capture "popout-question"))

(defun harness-media-shot-tree ()
  "The conversation tree of the hero's session."
  (harness-media--view (lambda () (harness-tree (plist-get harness-media--world :hero))))
  (harness-media--capture "tree"))

(defun harness-media-shot-usage ()
  "The usage dashboard over 30 days, by model."
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

(defun harness-media-shot-worktrees ()
  "The worktrees of the demo project."
  (harness-media--view (lambda () (harness-worktrees harness-media-project)))
  (harness-media--capture "worktrees"))

(defun harness-media-shot-settings ()
  "The settings page, for the demo project, which overrides two settings."
  (harness-media--write ".dir-locals.el"
                        "((nil . ((harness-permission-mode . accept-edits)\n         (harness-thinking . \"high\"))))\n")
  (harness-media--view (lambda () (harness-settings harness-media-project 'project)) nil 42)
  (harness-media--capture "settings"))

(defun harness-media-shot-btw ()
  "A BTW side conversation under the hero's chat."
  (harness-media--hero-layout (plist-get harness-media--world :hero))
  (harness-media--to-bottom (harness-media--open-chat (plist-get harness-media--world :btw) 'bottom))
  (harness-media--capture "btw"))

(defun harness-media-shot-menu ()
  "The harness menu, opened from the hero's chat."
  (let ((buffer (harness-media--hero-layout (plist-get harness-media--world :hero))))
    (select-window (get-buffer-window buffer))
    (harness-menu)
    (harness-media--settle 1)
    (harness-media--capture "menu")
    (ignore-errors (transient-quit-all))))

(defvar harness-acp-remote-host)
(defvar harness-acp-remote-port)
(defvar harness-acp-remote-address)
(declare-function harness-acp-remote--grant "harness-acp-remote")
(declare-function harness-ui-remote-toggle-qr "harness-ui-remote")

(defun harness-media-shot-remote ()
  "The remote control page: serving, a paired phone, the QR code unfolded."
  ;; Loopback only, on the usual port when it is free; the page shows
  ;; a local network address, as on a laptop at home.
  (setq harness-acp-remote-host "127.0.0.1"
        harness-acp-remote-address "192.168.1.150")
  (condition-case nil
      (let ((harness-acp-remote-port 4276)) (harness-call 'acp/remote-start))
    (error (let ((harness-acp-remote-port 0)) (harness-call 'acp/remote-start))))
  (harness-acp-remote--grant
   "192.168.1.23" "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/131.0 Mobile Safari/537.36")
  (harness-media--view #'harness-remote-control
                       (lambda ()
                         (harness-media--settle 0.5)
                         (harness-ui-remote-toggle-qr)
                         (harness-media--settle 1)
                         (goto-char (point-min))))
  (harness-media--capture "remote")
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
  (let* ((buffer (harness-media--open-chat (plist-get harness-media--world :hero) 'full))
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

(defconst harness-media-shots
  '(("chat" . harness-media-shot-chat)
    ("chat-permission" . harness-media-shot-chat-permission)
    ("chat-question" . harness-media-shot-chat-question)
    ("attachments" . harness-media-shot-attachments)
    ("tasks" . harness-media-shot-tasks)
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
    ("btw" . harness-media-shot-btw)
    ("menu" . harness-media-shot-menu)
    ("remote" . harness-media-shot-remote))
  "Every picture, as (NAME . FUNCTION), in the order they are taken.")

;;;; Entry point

(defun harness-media--setup-look ()
  "Dress the frame for the pictures."
  (setq inhibit-startup-screen t
        ring-bell-function #'ignore
        use-dialog-box nil
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
        harness-process nil
        ;; Every agent is scripted, so recaps are seeded for the pictures
        ;; instead (`harness-media--seed-recaps').
        harness-disabled-modules '(provider-claude provider-copilot provider-openai provider-bedrock provider-demo
                                                   recap))
  (require 'harness)
  (unless (harness-start) (error "The harness did not start cleanly"))
  ;; Chats take half the frame: the code beside them keeps 80 columns.
  (setf (alist-get 'right harness-ui-positions) '((side . right) (slot . 0) (window-width . 0.5)))
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
