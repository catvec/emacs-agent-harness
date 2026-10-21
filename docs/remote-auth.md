# Remote access: how a device signs in

A phone, a laptop or a browser tab that drives the harness over the network
is a client of the Agent Client Protocol (ACP) on another machine.  This page
says what ACP itself offers for signing it in, what the clients that exist
really do, which of it the harness uses and why, and how it all works.  The
research was done on 2026-10-20 and 2026-10-21 from the protocol's own pages
and the clients' own sources; every claim below names where it comes from.

## In short

- ACP has **one native way for a client to sign its user in**: the agent lists
  `authMethods` in its answer to `initialize`, the client shows them to its
  user, the user picks one, and the client calls `authenticate` with its id;
  the agent "handles authentication itself" and answers when it has.  There is
  no field for a password or a token in that request (only a method id and
  `_meta`), so what the method does is the agent's own: it can ask the person
  at its machine, as the harness does.  ACP UI does exactly this, in its own
  dialog, without the user leaving the app.
- Everything else people reach for is **not ACP**: a QR code, a pairing page in
  a browser, OAuth or OpenID Connect.  ACP's URL-mode elicitation says it "is
  not a substitute for authorizing the Client's access to the Agent".  They can
  only be ways the *agent* signs its user in, behind `authenticate`.
- Not every client calls `authenticate`.  Agmente (iOS) reads `authMethods` and
  never uses them: it sends a configured bearer token.  What every client that
  reaches a remote agent can do is present a **bearer secret when it opens the
  WebSocket**: ACP UI, Agmente and the official SDK all do (a header, or for a
  browser the subprotocol `bearer.SECRET`).
- So the harness does both, and nothing in between.  A device **signs in from
  its own ACP client** with `authenticate`: "Approve in Emacs" (no typing, no
  copying: the person at Emacs compares a code and presses Approve), or a login
  at the identity provider (authentik, ...) when one is set up.  A device that
  can keep a **session secret** (256 random bits, only its hash stored) is
  handed one and presents it on every later connection, so it signs in once; a
  client that cannot gets a session of its connection alone, or a token made in
  Emacs for its settings.
- A connection that has no session may only `initialize` and `authenticate`;
  it hears nothing of the harness; every other request is ACP's `auth_required`.
  A device's network address is shown and **trusted with nothing**: that was the
  flaw of the earlier design, which let in any request from an address whose
  browser had opened a pairing page.

| | |
|---|---|
| Native ACP sign-in | `authMethods` in `initialize`, then `authenticate`, shown by the client in its own UI |
| Methods | "Approve in Emacs" (a code compared, Approve pressed in Emacs); a login at the provider (OpenID Connect); `token` for plain TCP and clients that keep secrets |
| Credential on a later connection | the session secret `hs1_…` (`Authorization: Bearer`, subprotocol `bearer.SECRET`, or `?token=`) |
| Answers without a session | `initialize` (what any agent says of itself, and the methods) and `authenticate`; nothing else |
| Checked | at the WebSocket upgrade, on every HTTP request, on every ACP message; what the harness sends goes only to signed-in connections |
| Stored | SHA-256 of each kept secret, `acp-remote-sessions.eld`, mode 0600 |
| Ends | when revoked (page, `logout`, `DELETE /session`), after 30 idle days, 90 days after its secret was issued; a connection's own session when it closes |
| Encrypted | no: use a VPN or a TLS proxy (`harness-acp-remote-public-url`) |

## What ACP defines

All of it from <https://agentclientprotocol.com> as it stands in October 2026
(protocol version 1 is stable, version 2 is a published draft).

**Authentication** ([v1](https://agentclientprotocol.com/protocol/v1/authentication),
[schema](https://agentclientprotocol.com/protocol/v1/schema)).  "ACP
authentication is negotiated during initialization": the agent lists
`authMethods`, each with an `id`, a `name`, an optional `description` and a
`type`.

- `agent` (the default): "the Agent handles authentication itself".  The client
  calls `authenticate` with `{"methodId": ...}` (and may add `_meta`) and gets
  `{}` back (with an optional `_meta`).  **There is no field for a password, a
  token or a code**, and the answer comes when the agent decides: it may take as
  long as the person it asks.  When authentication is required, `session/new`
  and the like fail with `auth_required` (-32000), "Authentication is required
  before this operation can be performed".  (Version 2 renames the request
  `auth/login` and keeps the shape.)
- `terminal`: "run the configured Agent program interactively", then reconnect.
  The [Terminal Authentication RFD](https://agentclientprotocol.com/rfds/auth-methods)
  says a client "connected to an Agent over a remote transport must omit the
  capability unless it can launch that same Agent program in the Agent's
  execution environment".  A phone cannot.
- `env_var` existed in drafts and was removed in July 2026 because "that model
  assumes the Client owns the Agent process and does not generalize to remote
  transports".
- `logout` (`agentCapabilities.auth.logout`, stable) ends the authenticated
  state.

**Extending it** ([Extensibility](https://agentclientprotocol.com/protocol/v1/extensibility)).
"Implementations MUST NOT add any custom fields at the root of a type that's
part of the specification"; what is extra goes in `_meta`, with keys of the
implementation's own.  The harness hands a client its session secret in the
`_meta` of the `authenticate` answer, and names the page a browser opens in the
`_meta` of an auth method.

**Elicitation** ([v1](https://agentclientprotocol.com/protocol/v1/elicitation),
stable since July 2026) has a *URL mode* for out-of-band flows such as OAuth,
and says: "URL mode is not a substitute for authorizing the Client's access to
the Agent.  Agents MUST NOT send credentials or tokens obtained through URL mode
back over ACP".  Its *form mode* "MUST NOT be used to request secrets or
credentials".  So neither is a way to sign a client in; the harness uses
neither.

**Remote transports.**  The v1 and v2 [Transports](https://agentclientprotocol.com/protocol/v1/transports)
pages define stdio and list Streamable HTTP as a "draft proposal in progress".
The [Streamable HTTP & WebSocket Transport RFD](https://agentclientprotocol.com/rfds/streamable-http-websocket-transport)
(active since July 2026) proposes `ws://HOST/acp` and HTTP/2 with SSE, requires
clients to support WebSocket ("servers may support only WebSocket"), and answers
how authentication fits in: "ACP authentication is orthogonal and layered on top
via HTTP headers, query parameters, or WebSocket subprotocols.  `Acp-Connection-Id`
and `Acp-Session-Id` are transport-level identifiers, not auth tokens."

**What is not there:** a way to send a credential in `authenticate`; OAuth or
OpenID Connect; QR codes or pairing; API keys; client certificates.  Those are
left to the transport or to each product.

## What clients do

| Client | Platforms | Sign-in it offers | What it can present |
|---|---|---|---|
| [ACP UI](https://github.com/formulahendry/acp-ui) | Windows, macOS, Linux, Android (APK), iOS (build it), web | **The ACP flow** (`src/stores/session.ts`): after `initialize`, `session/new`; when that fails with "authentication required" or -32000 and `authMethods` is not empty, it opens a dialog listing each method's `name` and `description` (`AuthMethodDialog.vue`), calls `authenticate` with the one chosen (the request times out after 60 s, "increased for auth flows") and retries; the same for `session/load`.  It does not reconnect by itself | a header `Authorization: Bearer TOKEN`, sent as the WebSocket subprotocol `bearer.TOKEN` ("because browser/WebView WebSocket APIs cannot set custom HTTP headers", `src/lib/transport/websocket.ts`) beside `acp.v1`; it sends a `$/ping` notification every 25 s |
| [Agmente](https://github.com/rebornix/Agmente) | iOS | none: `InitializeParsing.swift` reads `authMethods` and nothing in its sources calls `authenticate` | a bearer token; Cloudflare Access service-token headers (README, `docs/remote-agent.md`) |
| [Ferngeist](https://github.com/arafatamim/Ferngeist) | Android | its own gateway's pairing code | no credential field is mentioned for a direct `ws://` address |
| [Official TypeScript SDK](https://github.com/agentclientprotocol/typescript-sdk) (`createWebSocketStream`) | Node, browsers | `authenticate` is in its API for a client to call | `headers` ("Browser WebSocket constructors ignore custom headers"), `protocols`; its cookie store is "meant for ACP routing affinity across reconnects, not authentication or authorization" |
| [Qwen Code `serve`](https://github.com/QwenLM/qwen-code/issues/4782) (a server) | | | a bearer token on the upgrade; "our trust model is bearer-token, not session-cookie" |
| Aptove, Runmote, AgentDeck, Chrome ACP, Ferngeist's gateway | iOS, Android, web | their own bridge or relay with their own QR or 8-digit pairing, end-to-end encrypted relays, URLs with embedded tokens: **a product's own protocol, not ACP** | |
| Editors: Zed, JetBrains, agent-shell, VS Code extensions | | they launch the agent as a subprocess (stdio); nothing remote: "every target client (Zed/Goose/JetBrains) today spawns its ACP agent locally over stdio" (a Qwen Code maintainer, June 2026).  They reach a harness through `scripts/harness-acp-stdio`, which reads the local `acp-token` | |
| The harness's own app (`harness_client/`) | iOS, Android, macOS, Linux, Windows, web | **The ACP flow**, shown on its connect screen; it opens the provider's page itself | the same `bearer.SECRET` subprotocol; keeps the secret it is handed |

Support is uneven even among those that call `authenticate`: some clients only
handle method ids they know (a [client that calls it only for two ids](https://github.com/get-bb/bb/issues/5706)
is one report of many).  So the harness does not depend on a client's dialog
alone: a device with a secret, handed one or given one, signs in without it.

What this says: **the one sign-in ACP itself defines, and the one a mainstream
client (ACP UI) really has, is `authMethods` with `authenticate`**, so that is
the way in; and the one credential **natively supported in ACP's transport
layer by a client on every platform** is a bearer secret presented as the
connection opens, so that is how a device that holds one signs in again.  A QR
code or a login in a browser is not a thing a generic client does: it can only
be a way the *agent* signs its user in, behind `authenticate`.

## What the harness accepts, and what it refuses

| Mechanism | Verdict | Why |
|---|---|---|
| `authenticate` with a method of the harness | **the way in** | it is what ACP defines; the client shows the method and its user chooses it, nothing is typed |
| "Approve in Emacs" | **offered to every client** | the person at the harness's Emacs approves, comparing a code: authentication by presence at the trusted machine, with nothing to type or copy |
| A login at the identity provider (OpenID Connect) | **offered when set up** | ACP has none; as one more method it signs the waiting connection in, the browser being left only for the provider's page |
| `Authorization: Bearer SECRET` | **accepted** | native clients; for a device that holds a secret |
| WebSocket subprotocol `bearer.SECRET` | **accepted** | browsers, web views, ACP UI; the server answers `acp.v1` when the client offers it, which they all do (a client that offers only `bearer.SECRET` gets that back, as a browser insists on a chosen subprotocol) |
| `?token=SECRET` in the address | **accepted** | one paste sets up any client that takes a URL; a proxy in front may log it, so a client with a header or subprotocol should use that |
| A secret that is no session's | the connection signs in like any other | it counts against its address (5 in 60 s) and the client is shown the methods, not a 401 |
| Cookies | refused | ACP and its SDK use them for affinity only; a browser would send one on a cross-site WebSocket (hijacking) |
| HTTP Basic, client certificates | not built in | a TLS proxy in front can require either |
| The device's network address | **never** | it names a machine, not an app: every program on a phone shares it |
| `harness-acp-token` as a bearer | refused; traded | it is a long-lived shared secret; `authenticate` with the method `token` trades it for a session secret |
| QR code, pairing page, one-time codes | **removed** | they moved a URL through a browser and the ACP client took no part in signing in |
| URL or form elicitation | not used | ACP says neither may authorize the client |

## How it works

```
 the device's ACP client                    the harness listener              Emacs
 ───────────────────────                    ────────────────────              ─────
 WebSocket, subprotocol acp.v1  ──────────▶ a connection with no session
 initialize ──────────────────────────────▶ what any agent says + authMethods
                                            [emacs-approval: "…the code 4719…"]
 session/new ─────────────────────────────▶ auth_required (-32000) + the methods
 (the client shows its dialog; the user taps "Approve in Emacs")
 authenticate {methodId} ─────────────────▶ held …              ───asks───▶  mode line "?1", a
                                                                              desktop notification,
                                                                              the page: ACP UI ·
                                                                              Android  code 4719
                                                                              [approve] [deny]
                                            session minted     ◀──Approve──  (compares the code)
 ◀──────────────────────── {}  (+ _meta.harness.session.token, for a client that keeps one)
 session/new ─────────────────────────────▶ ok: every later message is checked
```

**A connection with no session.**  A WebSocket (or plain TCP connection) that
holds no live session secret is let in, so that its client can do what ACP
says: `initialize` and `authenticate`.  It is answered `initialize` with what
any ACP agent says of itself (a client decides on those, such as whether it may
load a session) and the methods, but not the harness's version, methods or
events.  Every other request is ACP's `auth_required` with the methods in its
`data`.  What the harness sends its clients (session updates, events) and what
it asks of them (permission requests, questions) goes **only** to connections
that signed in: a connection with no session can neither read nor answer for
the harness.  Such connections are few (16, 4 per address) and short: a frame
may be 64 KB, and one that does nothing to sign in is closed after two minutes.

**Approve in Emacs.**  `initialize` gives the connection a code of four digits,
in the description of the method, and `authenticate` with it asks the person at
this Emacs: the mode line shows a count, a desktop notification arrives (and a
Gotify push, if set up), and the remote control page (`C-c h P`) lists the
device with the name its client gave (ACP UI 0.9.1 · Android · Chrome), its
address, the web page it comes from if it is one, and the code.  The person
compares it with the one on the device, and presses Approve (`C-c h y`) or
Deny.  It waits 50 seconds (`harness-acp-remote-approval-timeout`; ACP UI gives
up on a request after 60).  A request that is refused or runs out says so in its
error; an address may ask six times a minute (a refusal counts), five devices
may wait, and a connection may wait on one request.  Only the Emacs on this
machine can approve.  It proves the person is at the machine and means the
device; it does not stop someone on the path from relaying the connection, which
only encryption does.

**What the client is given.**  A client that says in `initialize` that it can
keep a session secret (`clientCapabilities._harness.sessionRefresh`, which the
harness's own app does) is handed one in the `_meta` of the `authenticate`
answer, shows it nowhere, and presents it as the connection opens next time:
no dialog.  Any other client gets a session that is its connection's alone,
which ends when the connection closes (nothing is stored or listed for good), so
it signs in again each time; give it a token (below) to skip that.

**The secret.**  `hs1_` and 43 base64url characters, from `/dev/urandom` (256
bits; OpenSSL's generator where a system has no such device).  The harness keeps
the SHA-256 of it, the device's name, how it signed in, when it was made and last
used, in `acp-remote-sessions.eld` in the state directory, written atomically
with mode 0600.  Nothing that is a secret is on disk, in a log or in a status
answer, and every comparison takes the same time wherever two secrets differ.
The `hs1_` prefix lets secret scanners and people recognise one.

**Every request.**  A WebSocket upgrade, an HTTP request or an ACP message that
does not belong to a live session is answered `401` (HTTP) or `auth_required`
(ACP), and nothing about the harness is said.  A connection that signed in is
checked again on **every ACP message** (`harness-acp-authorize-functions` is
asked each time for a client on another device), so revoking or expiring a
session stops its device at once, not at its next reconnect.  The only HTTP
routes that answer without a session secret are `/login` and `/oidc/callback`,
and each does nothing without a sign-in at the provider.

**A token for a client that cannot sign in.**  A client with a place for a
secret and no dialog (Agmente) is given one made in Emacs: `t` on the remote
control page, or `_harness/acp/remote-create-token` over the local connection.
The page shows the address and the secret once, to put in its settings (ACP UI:
the address and a header `Authorization: Bearer TOKEN`; Agmente: "Bearer
token"; any client that takes one address: the address with `?token=`); only the
hash is kept.  The device is then signed in by its secret and asked nothing.

**The shared secret.**  `harness-acp-token`, when set and at least 16 characters,
is traded by `authenticate` with the method `token` (plain TCP, or a client that
keeps secrets) for a session secret of its own, never used as one itself: a
headless harness can sign a device in without anyone at its Emacs.

**OpenID Connect.**  With `harness-acp-remote-oidc-issuer`,
`harness-acp-remote-oidc-client-id` and `harness-acp-remote-oidc-allowed` set,
`initialize` also lists "Sign in with HOST", whose description names
`PUBLIC-URL/login?c=CODE`, the page a browser opens (the harness's own app opens
it by itself).  The browser is first told which device it signs in and asked to
continue (a button only that page has, and a cookie only that browser has, so a
link someone else made cannot do it for the person), and is then sent to the
provider: the authorization code flow with PKCE (S256), a random `state` bound
to the browser by a cookie, and a `nonce`.  `/oidc/callback` checks the cookie,
spends the `state` (once, even when it fails), exchanges the code at the token
endpoint over TLS, and checks the id token's issuer, audience (and `azp` for
several), expiry, issue time, nonce and subject.  The signature is not checked:
the token came straight from the token endpoint over TLS, which OpenID Connect
Core 3.1.3.7 accepts in its place.  Only then is
`harness-acp-remote-oidc-allowed` asked, and the connection signed in.  The
login may finish after the client's `authenticate` timed out: it is remembered
for the connection for five minutes, and choosing the method again finishes at
once.  It lets in **nobody** until configured: with the list empty, `/login` says
so at once and the method is not offered.  A `/login` without a code signs the
browser in and shows it a secret, for a client that is given one by hand.  See
below for authentik.

**Ending a session.**  The remote control page (`k` or `[revoke]`, `K` for all),
ACP's `logout` (announced as `agentCapabilities.auth.logout` to a client that has
a session), `DELETE /session` with the secret, running out, a connection's own
session closing with it, or corporate mode (nothing works while it is on, and the
kept sessions wait).  A secret that was revoked leads its device to the dialog
again, not to an error.

**Lifetimes.**  A kept session ends after `harness-acp-remote-idle-timeout`
unused (30 days; one with a connection open does not run out) and
`harness-acp-remote-session-lifetime` (90 days) after its secret was issued,
whatever it does.  The 90 days count from when the *current* secret was issued:
at sign-in, or when it was last replaced, so a device that takes replacements
(below) gets a new secret every week, never reaches them, and signs in once; one
that does not signs in again after 90 days.

**Replacing the secret.**  A client that put `_harness.sessionRefresh: true` in
its `clientCapabilities` is given a new secret in the answer to `initialize`
(`_harness.session.token`) once the current one is `harness-acp-remote-rotate-after`
old (7 days).  The old one keeps working for `harness-acp-remote-rotation-grace`
(one hour) or until the new one is first used, whichever comes first; a client
that shows up with the old one has lost the new one and is sent another.  A
secret that leaked is thus useless soon, and a client whose own secret is
refused knows that someone else used the session.  Do not paste one session's
secret into two clients; give each its own.

**Managing access.**  Approving, refusing, making tokens, revoking, starting,
stopping and moving the listener (`_harness/acp/remote-*`) are for the Emacs on
this machine only: a device that is signed in drives the harness, it cannot hand
out more access.

## Signing a device in

**An ACP client with a sign-in dialog (ACP UI, the harness's own app).**  In
Emacs, `C-c h P`, then `s` to start serving.  In the client, add a remote agent
at the ACP address the page shows (`ws://HOST:4276/acp`; typing that address is
the one thing nothing can save you) and open it.  The client asks how to sign
in: choose **Approve in Emacs**, check that Emacs shows the code the client
shows, and press Approve there (`C-c h y`, or the button, or click the `?1` in
the mode line).  Nothing is typed or copied, and the client is not left.  The
harness's own app keeps the secret it is handed; ACP UI asks again next time.

**A client without one (Agmente), or to skip the question.**  `t` on the page
makes a token: put it in the client's settings, as above.

**With OpenID Connect (authentik).**  For when nobody is at the Emacs.  Choose
"Sign in with …" in the client, open the page its description names (the
harness's own app opens it itself), confirm the code, sign in at authentik, and go
back: the client signs in.

**From a script.**  A script on the harness's machine can make a token over the
local ACP connection (`_harness/acp/remote-create-token`) and connect with
`Authorization: Bearer`.  One elsewhere with `harness-acp-token` calls
`authenticate` with `{"methodId":"token","token":…}` on a WebSocket or plain TCP.

## Setting up authentik

ACP has no OpenID Connect, so this is only one more way the agent signs its user
in; it suits a laptop, a tablet without a way to reach Emacs, or a harness that
is away from the screen you are looking at.

1. In authentik, *Applications → Providers → Create → OAuth2/OpenID Provider*.
   Client type **Public** (PKCE; there is no secret to keep) or Confidential.
   Redirect URI: exactly the harness's public URL and `/oidc/callback`, for
   example `https://harness.example.com/oidc/callback`, which authentik compares
   as it is unless you give it as a regular expression.  Leave the default scopes `openid`, `email` and
   `profile`; with authentik's own mappings `profile` carries the user's groups
   ([OAuth 2.0 provider](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/)).
   The harness does not check the token's signature, so any signing key will do.
2. *Applications → Create*, slug `harness`, that provider.  Bind the group or
   users that may use it: the application's bindings are authentik's own check.
3. In the harness:

   ```elisp
   (setopt harness-acp-remote-public-url "https://harness.example.com"
           harness-acp-remote-oidc-issuer "https://auth.example.com/application/o/harness/"
           harness-acp-remote-oidc-client-id "THE-CLIENT-ID"
           harness-acp-remote-oidc-allowed '("harness-users"))   ; groups, users, e-mails
   ```

   The issuer is the per-application one authentik shows on the provider, with
   or without the trailing slash.  `harness-acp-remote-oidc-allowed` is matched,
   ignoring case, against the id token's `preferred_username`, `sub`, `groups`
   and `email`; `t` lets in everyone authentik lets in, and the default `nil`
   nobody.  **The harness goes by an e-mail address only when the provider says
   it is verified** (`email_verified`, which the specification leaves optional:
   an address a user could type in themselves proves nobody).  Since authentik
   2025.10 that claim is false unless you set up email verification, so list a
   group or a username.  For a confidential
   client set `harness-acp-remote-oidc-client-secret` to the secret, or to a
   function that returns it.
4. The client now lists "Sign in with auth.example.com".  Choosing it opens
   `https://harness.example.com/login?c=CODE` in a browser (`l` on the remote
   control page copies the plain `/login`, which signs a browser in and shows it
   a secret to put in a client's settings).

This was written against the OpenID Connect and authentik documentation.  It is
tested two ways: against a stub that stands in for the harness's HTTP client, and
over real HTTP against a small provider (`test/fixtures/oidc-provider.py`) that
verifies PKCE, the redirect URI and the client, and keeps the groups out of its
id token so that the harness has to ask userinfo for them.  It has not been run
against a live authentik in this change.

## Encryption

The harness's listener is plain TCP: Emacs has no TLS server.  A session secret
on an open network can be read by anyone who can see the traffic, and so can the
connection that signed in without one, so:

- **Tailscale or another VPN** (WireGuard): bind to the VPN address or leave
  `0.0.0.0`; the remote control page calls such an address encrypted.
- **A TLS proxy** (Caddy, nginx, Tailscale Serve, a Cloudflare tunnel) in front:
  bind the listener to `127.0.0.1` (`harness-acp-remote-host`), set
  `harness-acp-remote-public-url` to the proxy's `https://` address and the ACP
  address and the OpenID redirect carry it (`wss://`).  Proxy the
  WebSocket upgrade and keep its idle timeout above a minute.  Forwarded
  headers are not trusted: behind a proxy every request comes from the proxy's
  address, so the counters per address are shared.  A proxy that logs request
  lines logs `?token=`: give the client the secret as a header or subprotocol,
  or turn that logging off.
- Neither: sign in on a network you trust.  The page says "none" in orange.

## Wire reference

| Request | Without a session secret | With one |
|---|---|---|
| `GET /`, `GET /acp`, anything else | `401` | `/` and `/acp`: 200 text naming the device; else 404 |
| `GET /acp` + `Upgrade: websocket` | `101`: a connection with no session, which may `initialize` and `authenticate` (`429` when its address is refused or too many connections have no session) | `101`, subprotocol `acp.v1`, `Acp-Connection-Id`: signed in |
| `GET /login`, `/oidc/callback` | OpenID Connect, when configured and someone is allowed | |
| `GET /session` | `401` | JSON naming the device |
| `DELETE /session` | `401` | `204`, the session ends |

On a connection with no session (WebSocket, or ACP's line framing with first
byte `{`): `initialize` answers the protocol version, the standard
`agentCapabilities`, `agentInfo.name` and `authMethods`; `authenticate
{"methodId": ID}` signs in by a method it listed (`emacs-approval`, `oidc`,
`token` with a `token`); the answer is `{}`, with `_meta.harness.session` for a
client that said it keeps one.  Anything else is `-32000` with
`data.authMethods`, `$/…` notifications are ignored.  Call `initialize` again
after signing in: the answer is then the full one.

Limits: 8 KB of request body, 16 KB of headers, 64 connections, 16 of them
without a session (4 per address, 64 KB a message, two minutes), 30 seconds for
a request to arrive, 5 refused secrets per address per minute, 6 requests to be
approved per address per minute.

## What changed

- The earlier design offered a QR code whose page copied the server address and
  let in any request from the address that had opened it, for eight hours.  Both
  are gone: **a request now needs a session**, which a device gets by
  `authenticate` or holds as a secret.  The QR code, the pairing page, one-time
  codes and `POST /pair` are removed: they carried a URL through a browser and
  the ACP client took no part.
- A connection that has no session is let in to sign in, and what the harness
  sends or asks goes only to connections that signed in.  (Fan-out used to go to
  every connected client, signed in or not; it now goes to those that may call
  methods, which also holds for a local client that has not yet sent
  `harness-acp-token`.)
- `harness-acp-token` is no longer a bearer for the remote listener; it is
  traded by `authenticate`.  It is unchanged for the loopback ACP server and
  `scripts/harness-acp-stdio`.
- Sessions that are kept are saved and kept when serving stops or the harness
  restarts; `harness-acp-remote-idle-timeout` is 30 days (it was 8 hours).

## Limits, stated plainly

- A secret on an unencrypted network can be read, and so can a connection that
  signed in with an approval; see Encryption.
- Approval depends on the person comparing the code and pressing Approve only for
  their own device.  A request that comes from a web page says so on the page.
- A client that cannot keep a secret signs in again each time it connects.  Give
  it a token to skip that.
- Whoever holds a session secret is that device until it is revoked, ends or is
  replaced.  Clients that cannot take a replacement keep theirs for up to 90
  days, and one that takes them has no other limit than the 30 idle days:
  revoke a lost device on the remote control page.
- The harness serves WebSocket, not ACP's draft Streamable HTTP (HTTP/2, SSE).
  The draft allows that, and every client above speaks WebSocket.
- OpenID Connect does not check the id token's signature (see above), and has
  not been run against a live authentik here, only against a provider written
  for the tests.
- Behind a TLS proxy every device has the proxy's address, so the counters per
  address are shared among them.
- Four addresses on the network can keep all sixteen connections that have no
  session busy (two minutes each, four per address), so that a *new* device
  cannot reach the dialog meanwhile.  Devices that hold a secret sign in at the
  upgrade and are not counted; the VPN or the proxy is what keeps strangers
  from reaching the port at all.
- The login at the provider needs the app to stay connected while the browser is
  open.  A phone may suspend the app and drop the connection meanwhile; the
  app then starts again, and choosing the method again is quick (the provider
  usually knows the browser already).
