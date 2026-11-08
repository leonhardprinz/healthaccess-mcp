#!/usr/bin/env python3
"""Minimal App Store Connect API client for PTC's team. Reads the key from ~/.config/healthaccessmcp/
(asc.env + AuthKey_<id>.p8, never in the repo). Needs pyjwt and cryptography:
    python3 -m venv ~/.config/healthaccessmcp/venv && ~/.config/healthaccessmcp/venv/bin/pip install pyjwt cryptography
Use as a module (from asc import call) or: scripts/asc.py GET /v1/apps"""
import json, os, sys, time, urllib.error, urllib.request

import jwt

CONF = os.path.expanduser("~/.config/healthaccessmcp")
ENV = {}
for line in open(os.path.join(CONF, "asc.env")):
    if line.startswith("export "):
        k, v = line[7:].strip().split("=", 1)
        ENV[k] = v
KEY = open(os.path.join(CONF, f"AuthKey_{ENV['ASC_KEY_ID']}.p8")).read()


def token() -> str:
    now = int(time.time())
    return jwt.encode({"iss": ENV["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      KEY, algorithm="ES256", headers={"kid": ENV["ASC_KEY_ID"]})


def call(method: str, path: str, body=None):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            text = r.read()
            return r.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


if __name__ == "__main__":
    status, data = call(sys.argv[1], sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else None)
    print(status)
    print(json.dumps(data, indent=2)[:4000])
