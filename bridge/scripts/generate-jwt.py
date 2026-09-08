#!/usr/bin/env python3
"""Generate JWT tokens for App Store Connect and Google Play APIs."""

import json
import sys
import time

import jwt  # PyJWT


def apple_jwt(key_id: str, issuer_id: str, private_key: str) -> str:
    """Generate App Store Connect API JWT (ES256, 20min expiry)."""
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": key_id})


def google_jwt(service_account_json: str, scope: str) -> str:
    """Generate Google OAuth2 JWT assertion (RS256, 1hr expiry)."""
    sa = json.loads(service_account_json)
    now = int(time.time())
    payload = {
        "iss": sa["client_email"],
        "scope": scope,
        "aud": sa["token_uri"],
        "iat": now,
        "exp": now + 3600,
    }
    return jwt.encode(payload, sa["private_key"], algorithm="RS256")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "apple":
        # Usage: generate-jwt.py apple <key_id> <issuer_id> <private_key_pem>
        print(apple_jwt(sys.argv[2], sys.argv[3], sys.argv[4]))
    elif cmd == "google":
        # Usage: generate-jwt.py google <service_account_json> <scope>
        print(google_jwt(sys.argv[2], sys.argv[3]))
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
