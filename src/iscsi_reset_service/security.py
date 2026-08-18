from __future__ import annotations

import hashlib
import hmac
import secrets


def token_digest(token: str, pepper: bytes) -> str:
    value = hmac.new(pepper, token.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"hmac-sha256:{value}"


def verify_token(token: str, expected_digest: str, pepper: bytes) -> bool:
    return hmac.compare_digest(token_digest(token, pepper), expected_digest)


def generate_token() -> str:
    return secrets.token_urlsafe(32)

