#!/usr/bin/env python3
'''Read-only usage queries against a running harness, over its local ACP socket.

WHY THIS EXISTS
---------------
The harness keeps its usage ledger in <harness-state-directory>/usage.db (SQLite)
and its session records in <harness-state-directory>/sessions/.  Neither is visible
to a sandboxed bash: the sandbox exposes only the session's working directory, its
temporary directory and the harness's tool-output directory.  The harness process
itself can read them, and it serves the numbers as read-only bus methods over its
ACP socket:

  _harness/usage/summary   aggregate rows; group-by is project, model, day,
                           session, hour or billing; filters since, until
                           (floats, until exclusive), session, project, model,
                           billing
  _harness/usage/totals    one aggregate, the same filters
  _harness/usage/series    continuous buckets, bucket day|hour
  _harness/session/list    session records (model, usage, billing, ...)

This script is a thin JSON-RPC client for those methods.  It writes nothing and
calls no mutating method; the only non-query request it sends is authenticate,
which the server requires before it answers at all.  The address is the one
<state>/acp-address holds and the token is $HARNESS_SERVER_TOKEN, as
scripts/harness-acp-stdio reads them.  The token is never printed.

USAGE
-----
  # every subscription-billed session active overnight, biggest first
  scripts/analysis/chatgpt-quota-query.py --address 127.0.0.1:45203 summary \
      --group-by session --billing subscription --since 1794546000 --until 1794560400

  # one aggregate over a window
  scripts/analysis/chatgpt-quota-query.py --address 127.0.0.1:45203 totals \
      --since 1794546000 --until 1794560400

  # hourly shape, to find where the activity actually is
  scripts/analysis/chatgpt-quota-query.py --address 127.0.0.1:45203 series \
      --bucket hour --since 1794373200 --until 1794582000

  # the session records themselves (no internal helper sessions)
  scripts/analysis/chatgpt-quota-query.py --address 127.0.0.1:45203 sessions

--json prints the raw reply.  --selftest checks the request builder and the
filter mapping, and needs no harness.

TOKEN CONVENTIONS (they matter for every percentage in the report)
-----------------------------------------------------------------
input is the prompt the provider counted.  For the ChatGPT-plan route
(lisp/modules/harness-provider-responses.el) the cached tokens are a PART of
input_tokens, and the OpenAI-compatible route records the same way
(harness-provider-openai.el sums prompt_tokens into :input for DeepSeek).  So the
cache-hit ratio is cache-read / input, never cache-read / (input + cache-read).
An absent cache-read means unknown, not zero.
'''

from __future__ import annotations

import argparse
import json
import os
import socket
import sys

AUTH_ID = 'chatgpt-quota-query-auth'
REQ_ID = 'chatgpt-quota-query-1'

#: The only methods this client may call.  All are read-only bus queries, so a
#: typo cannot turn a report into a mutation.
READ_ONLY = {
    'authenticate',
    '_harness/usage/summary',
    '_harness/usage/totals',
    '_harness/usage/series',
    '_harness/session/list',
}

FILTERS = ('since', 'until', 'session', 'project', 'model', 'billing')


def build(method, params):
    """Return one JSON-RPC request line for METHOD with PARAMS."""
    if method not in READ_ONLY:
        raise SystemExit('refusing to call %r: not a read-only query' % method)
    return json.dumps({'jsonrpc': '2.0', 'id': REQ_ID, 'method': method,
                       'params': params}, separators=(',', ':')) + '\n'


def query(address, token, method, params, timeout=120.0):
    """Send METHOD/PARAMS and return the result of the reply."""
    host, _, port = address.rpartition(':')
    if not host:
        raise SystemExit('address %r is not HOST:PORT' % address)
    sock = socket.create_connection((host, int(port)), timeout=timeout)
    try:
        if token:
            sock.sendall(json.dumps({'jsonrpc': '2.0', 'id': AUTH_ID,
                                     'method': 'authenticate',
                                     'params': {'token': token}},
                                    separators=(',', ':')).encode() + b'\n')
        sock.sendall(build(method, params).encode())
        buf = b''
        authed = not token
        while True:
            chunk = sock.recv(1 << 20)
            if not chunk:
                raise SystemExit('the server closed the connection')
            buf += chunk
            while b'\n' in buf:
                line, _, buf = buf.partition(b'\n')
                if not line.strip():
                    continue
                msg = json.loads(line)
                if msg.get('id') == AUTH_ID and not authed:
                    if msg.get('error'):
                        raise SystemExit('authentication failed: %s'
                                         % msg['error'].get('message'))
                    authed = True
                    continue
                if msg.get('id') != REQ_ID:
                    continue        # an event or notification, not our answer
                if msg.get('error'):
                    raise SystemExit('the harness refused the query: %s'
                                     % msg['error'].get('message'))
                return msg.get('result')
    finally:
        sock.close()


def filters(args):
    """Return the query filters named on the command line."""
    out = {}
    for key in FILTERS:
        value = getattr(args, key, None)
        if value is not None:
            out[key] = value
    return out


def ints(n):
    return '{:,}'.format(int(n)) if isinstance(n, (int, float)) else '-'


def money(x):
    return '${:,.4f}'.format(x) if isinstance(x, (int, float)) else '-'


def show(rows):
    """Print aggregate rows as an aligned table."""
    if not rows:
        print('(no rows)')
        return
    head = ('key', 'input', 'output', 'cache-read', 'cache%', 'cost', 'calls')
    body = []
    for r in rows:
        i = r.get('input') or 0
        c = r.get('cache-read') or 0
        body.append([str(r.get('key', '')), ints(i), ints(r.get('output')),
                     ints(c), '{:.1f}%'.format(100.0 * c / i) if i else '-',
                     money(r.get('cost')), ints(r.get('calls'))])
    widths = [max(len(str(x)) for x in col) for col in zip(head, *body)]
    for row in (head,) + tuple(body):
        print('  '.join(str(cell).rjust(w) if i else str(cell).ljust(w)
                        for i, (cell, w) in enumerate(zip(row, widths))))


def selftest():
    """Check the request builder and the filter mapping."""
    line = build('_harness/usage/summary', {'group-by': 'session'})
    assert json.loads(line)['method'] == '_harness/usage/summary'
    try:
        build('session/delete', {})
    except SystemExit:
        pass
    else:
        raise AssertionError('a mutating method was not refused')
    ns = argparse.Namespace(since=1.0, until=2.0, session='s', project=None,
                            model=None, billing='subscription')
    assert filters(ns) == {'since': 1.0, 'until': 2.0, 'session': 's',
                           'billing': 'subscription'}, filters(ns)
    print('selftest ok')
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--address', default=os.environ.get('HARNESS_ACP_ADDRESS'),
                    help='HOST:PORT of the harness ACP socket (acp-address)')
    ap.add_argument('--json', action='store_true', help='print the raw reply')
    ap.add_argument('--selftest', action='store_true')
    sub = ap.add_subparsers(dest='what')
    for name in ('summary', 'totals', 'series'):
        p = sub.add_parser(name)
        if name == 'summary':
            p.add_argument('--group-by', dest='group_by', default='session')
        if name == 'series':
            p.add_argument('--bucket', default='hour')
        for key in FILTERS:
            p.add_argument('--' + key,
                           type=float if key in ('since', 'until') else str)
    sub.add_parser('sessions')

    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if not args.what:
        ap.error('choose a query: summary, totals, series or sessions')
    if not args.address:
        raise SystemExit('no --address and no HARNESS_ACP_ADDRESS')
    token = os.environ.get('HARNESS_SERVER_TOKEN')

    if args.what == 'sessions':
        result = query(args.address, token, '_harness/session/list', {})
    else:
        params = filters(args)
        if args.what == 'summary':
            params['group-by'] = args.group_by
        if args.what == 'series':
            params['bucket'] = args.bucket
        result = query(args.address, token,
                       '_harness/usage/' + args.what, params)

    if args.json:
        json.dump(result, sys.stdout, indent=1, sort_keys=True)
        sys.stdout.write('\n')
    elif args.what == 'totals':
        show([result] if isinstance(result, dict) else result)
    else:
        show(result if isinstance(result, list) else [result])
    return 0


if __name__ == '__main__':
    sys.exit(main())
