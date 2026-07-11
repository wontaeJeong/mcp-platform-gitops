#!/usr/bin/env python3

import argparse
import base64
import hashlib
import json
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from collections.abc import Mapping
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer


ISSUER = "http://keycloak.localhost:8081/realms/mcp"
CLIENT_ID = "mcp-local"
RESOURCE = "http://gateway.localhost:8080/mock/mcp"


@dataclass
class CallbackResult:
    code: str | None = None
    error: str | None = None
    done: bool = False


def post_json(url: str, token: str, payload: Mapping[str, object]):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status != 200:
                raise RuntimeError(f"MCP request failed with HTTP {response.status}")
            return json.load(response)
    except urllib.error.HTTPError as error:
        reason = error.read().decode(errors="replace")
        raise RuntimeError(f"MCP request failed with HTTP {error.code}: {reason}") from error


def jwt_claims(token: str) -> dict[str, object]:
    encoded = token.split(".")[1]
    encoded += "=" * (-len(encoded) % 4)
    return json.loads(base64.urlsafe_b64decode(encoded))


def main() -> None:
    parser = argparse.ArgumentParser(description="Run local Authorization Code + PKCE and call MCP whoami")
    parser.add_argument("--timeout", type=int, default=300, help="login timeout in seconds")
    parser.add_argument("--no-browser", action="store_true", help="print the URL without opening a browser")
    args = parser.parse_args()

    verifier = secrets.token_urlsafe(64)
    state = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(32)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    callback = CallbackResult()

    class CallbackHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            if parsed.path != "/callback":
                self.send_error(404)
                return
            if not secrets.compare_digest(query.get("state", [""])[0], state):
                self.send_error(400, "state mismatch")
                return
            callback.error = query.get("error", [None])[0]
            callback.code = query.get("code", [None])[0]
            if not callback.error and not callback.code:
                callback.error = "callback did not contain an authorization code"
            callback.done = True
            body = b"Authentication complete. You can close this window.\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:
            return

    server = HTTPServer(("127.0.0.1", 8765), CallbackHandler)
    redirect_uri = f"http://127.0.0.1:{server.server_port}/callback"
    authorization_params = {
        "response_type": "code",
        "client_id": CLIENT_ID,
        "redirect_uri": redirect_uri,
        "scope": "openid mcp:mock:use",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        "nonce": nonce,
        "resource": RESOURCE,
    }
    authorization_url = ISSUER + "/protocol/openid-connect/auth?" + urllib.parse.urlencode(authorization_params)
    print("Open this URL to authenticate:")
    print(authorization_url)
    if not args.no_browser:
        threading.Thread(target=webbrowser.open, args=(authorization_url,), daemon=True).start()

    deadline = time.monotonic() + args.timeout
    while not callback.done:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        server.timeout = min(1.0, remaining)
        server.handle_request()
    server.server_close()
    if callback.error:
        raise SystemExit("authorization failed: " + callback.error)
    if not callback.code:
        raise SystemExit("authorization timed out without a code")

    token_params = {
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "code": callback.code,
        "redirect_uri": redirect_uri,
        "code_verifier": verifier,
        "resource": RESOURCE,
    }
    token_request = urllib.request.Request(
        ISSUER + "/protocol/openid-connect/token",
        data=urllib.parse.urlencode(token_params).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(token_request, timeout=15) as response:
            token = json.load(response)["access_token"]
    except urllib.error.HTTPError as error:
        raise SystemExit(f"token exchange failed with HTTP {error.code}") from error
    if not token:
        raise SystemExit("token exchange returned an empty access token")

    claims = jwt_claims(token)
    raw_audiences = claims.get("aud")
    if isinstance(raw_audiences, str):
        audiences = [raw_audiences]
    elif isinstance(raw_audiences, list) and all(isinstance(value, str) for value in raw_audiences):
        audiences = raw_audiences
    else:
        audiences = []
    if RESOURCE not in audiences:
        raise SystemExit("interactive access token is missing the gateway audience")
    if "mcp:mock:use" not in str(claims.get("scope", "")).split():
        raise SystemExit("interactive access token is missing mcp:mock:use")
    if claims.get("loginid") != "local-user":
        raise SystemExit("interactive access token is missing the expected loginid")
    if not claims.get("sub"):
        raise SystemExit("interactive access token is missing sub")
    if claims.get("iss") != ISSUER:
        raise SystemExit("interactive access token has an unexpected issuer")

    initialize = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "local-pkce", "version": "1.0.0"},
        },
    }
    post_json(RESOURCE, token, initialize)
    tools_call = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {"name": "whoami", "arguments": {}},
    }
    response = post_json(RESOURCE, token, tools_call)
    result = response["result"]
    identity = result.get("structuredContent")
    if identity is None:
        identity = json.loads(result["content"][0]["text"])
    print(json.dumps(identity, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
