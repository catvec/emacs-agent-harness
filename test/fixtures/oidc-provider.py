"""A small OpenID Connect provider, for testing the harness's sign-in over real HTTP.

    python3 oidc-provider.py [PORT]      (0 or none: a free port; it prints "idp on PORT")

Discovery, an authorization endpoint that approves at once, a token endpoint
that verifies PKCE (S256), the redirect URI and the client, and userinfo.  The
id token carries no signature ("alg": "none"): the harness takes it from the
token endpoint over TLS in place of a signature check, and this is plain http on
loopback, which the harness allows for tests.  The id token holds no groups; the
userinfo answer does, as a provider that keeps them out of its tokens would.
Not for anything but tests.
"""
import base64, hashlib, json, sys, time, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CLIENT_ID = "harness-client"
codes = {}          # code -> the authorization request it answered


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        port = self.server.server_address[1]
        issuer = f"http://127.0.0.1:{port}/application/o/harness/"
        url = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        if url.path == "/application/o/harness/.well-known/openid-configuration":
            base = f"http://127.0.0.1:{port}/application/o"
            return self.send_json(200, {
                "issuer": issuer,
                "authorization_endpoint": f"{base}/authorize/",
                "token_endpoint": f"{base}/token/",
                "userinfo_endpoint": f"{base}/userinfo/",
            })
        if url.path == "/application/o/authorize/":
            if q.get("client_id") != CLIENT_ID or q.get("response_type") != "code" \
               or q.get("code_challenge_method") != "S256" or not q.get("code_challenge") \
               or not q.get("state") or not q.get("nonce") \
               or "openid" not in q.get("scope", "").split():
                return self.send_json(400, {"error": "invalid_request", "got": q})
            code = b64(hashlib.sha256((q["state"] + str(time.time())).encode()).digest())[:24]
            codes[code] = q
            sep = "&" if "?" in q["redirect_uri"] else "?"
            self.send_response(302)
            self.send_header("Location", q["redirect_uri"] + sep
                             + urllib.parse.urlencode({"code": code, "state": q["state"]}))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if url.path == "/application/o/userinfo/":
            if self.headers.get("Authorization") != "Bearer access-for-me":
                return self.send_json(401, {"error": "invalid_token"})
            return self.send_json(200, {"sub": "user-42", "groups": ["harness-users", "everyone"]})
        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        port = self.server.server_address[1]
        issuer = f"http://127.0.0.1:{port}/application/o/harness/"
        url = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        form = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(length).decode()).items()}
        if url.path != "/application/o/token/":
            return self.send_json(404, {"error": "not_found"})
        if self.headers.get("Content-Type") != "application/x-www-form-urlencoded":
            return self.send_json(400, {"error": "invalid_request", "why": "content type"})
        auth = codes.pop(form.get("code", ""), None)
        if auth is None:
            return self.send_json(400, {"error": "invalid_grant"})
        if form.get("grant_type") != "authorization_code" or form.get("client_id") != CLIENT_ID \
           or form.get("redirect_uri") != auth["redirect_uri"]:
            return self.send_json(400, {"error": "invalid_grant", "why": "client or redirect"})
        challenge = b64(hashlib.sha256(form.get("code_verifier", "").encode()).digest())
        if challenge != auth["code_challenge"]:
            return self.send_json(400, {"error": "invalid_grant", "why": "PKCE"})
        now = int(time.time())
        claims = {"iss": issuer, "aud": CLIENT_ID, "sub": "user-42", "iat": now, "exp": now + 600,
                  "nonce": auth["nonce"], "preferred_username": "noah",
                  "email": "noah@example.com", "email_verified": False}
        token = ".".join([b64(b'{"alg":"none","typ":"JWT"}'), b64(json.dumps(claims).encode()), ""])
        self.send_json(200, {"access_token": "access-for-me", "token_type": "Bearer", "id_token": token})


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 0), Handler)
    print("idp on", server.server_address[1], flush=True)
    server.serve_forever()
