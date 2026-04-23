"""
pmg-quarantine-junk: shared utilities
Token generation/validation, config loading, logging setup.
"""

import base64
import configparser
import hashlib
import hmac
import logging
import os
import pwd
import re
import sqlite3
import stat
import time

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_PATH = '/etc/pmg-quarantine-junk/config.ini'
SECRET_PATH = '/etc/pmg-quarantine-junk/secret.key'
STATE_DB    = '/var/lib/pmg-quarantine-junk/state.db'
LOG_FILE    = '/var/log/pmg-quarantine-junk.log'

def load_config(path=CONFIG_PATH):
    _fix_ownership(path, user='pmg-quarantine', mode=0o640)
    cfg = configparser.ConfigParser()
    if not cfg.read(path):
        raise FileNotFoundError(f"Config not found: {path}")
    return cfg

def load_secret(path=SECRET_PATH):
    with open(path, 'rb') as f:
        return f.read().strip()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def _fix_ownership(path: str, user: str = 'pmg-quarantine', mode: int = 0o640):
    """Устанавливает владельца файла root:<group> и права <mode>.
    Ошибки игнорируются: если нет прав или пользователь не существует — не страшно."""
    try:
        pw = pwd.getpwnam(user)
        st = os.stat(path)
        if st.st_uid != 0 or st.st_gid != pw.pw_gid:
            os.chown(path, 0, pw.pw_gid)
        if stat.S_IMODE(st.st_mode) != mode:
            os.chmod(path, mode)
    except (KeyError, PermissionError, OSError):
        pass


def _fix_log_ownership(path: str):
    """Обратная совместимость — делегирует в _fix_ownership."""
    _fix_ownership(path, user='pmg-quarantine', mode=0o640)


def setup_logging(name: str, level: str = 'INFO') -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    if not logger.handlers:
        fh = logging.FileHandler(LOG_FILE)
        _fix_log_ownership(LOG_FILE)
        fh.setFormatter(logging.Formatter(
            '%(asctime)s %(name)s [%(levelname)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        ))
        logger.addHandler(fh)
    return logger

# ---------------------------------------------------------------------------
# Tokens  (HMAC-SHA256, base64url, format: data|sig)
# ---------------------------------------------------------------------------

def generate_token(quarantine_id: str, pmail: str, secret: bytes, ttl_days: int = 7) -> str:
    """Generate a signed, time-limited token for a quarantine action."""
    expiry = int(time.time()) + ttl_days * 86400
    data = f"{quarantine_id}|{pmail}|{expiry}"
    sig = hmac.new(secret, data.encode('utf-8'), hashlib.sha256).hexdigest()
    raw = f"{data}|{sig}".encode('utf-8')
    return base64.urlsafe_b64encode(raw).decode('utf-8').rstrip('=')

def validate_token(token: str, secret: bytes) -> tuple:
    """
    Validate token and return (quarantine_id, pmail).
    Raises ValueError on any problem.
    """
    try:
        pad = 4 - len(token) % 4
        if pad != 4:
            token += '=' * pad
        decoded = base64.urlsafe_b64decode(token).decode('utf-8')
    except Exception:
        raise ValueError("Cannot decode token")

    # Split off the last segment as the HMAC signature
    parts = decoded.rsplit('|', 1)
    if len(parts) != 2:
        raise ValueError("Malformed token (missing signature)")
    data, sig = parts

    expected = hmac.new(secret, data.encode('utf-8'), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        raise ValueError("Invalid token signature")

    data_parts = data.split('|')
    if len(data_parts) != 3:
        raise ValueError("Malformed token (bad data)")

    quarantine_id, pmail, expiry_str = data_parts
    if int(expiry_str) < int(time.time()):
        raise ValueError("Token has expired")

    if not re.match(r'^C\d+R\d+T\d+(:bl)?$', quarantine_id):
        raise ValueError("Invalid quarantine ID in token")

    if not re.match(r'^[^@\s]+@[^@\s]+\.[^@\s]+$', pmail):
        raise ValueError("Invalid email in token")

    return quarantine_id, pmail

# ---------------------------------------------------------------------------
# SQLite state DB  (tracks which quarantine items were already notified)
# ---------------------------------------------------------------------------

def open_state_db(path=STATE_DB) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS notified (
            quarantine_id TEXT PRIMARY KEY,
            pmail         TEXT NOT NULL,
            notified_at   INTEGER NOT NULL,
            token_expiry  INTEGER NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS used_tokens (
            token_hash  TEXT PRIMARY KEY,
            used_at     INTEGER NOT NULL,
            action      TEXT NOT NULL
        )
    """)
    conn.commit()
    return conn

def is_notified(conn: sqlite3.Connection, quarantine_id: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM notified WHERE quarantine_id=?", (quarantine_id,)
    ).fetchone()
    return row is not None

def mark_notified(conn: sqlite3.Connection, quarantine_id: str,
                  pmail: str, ttl_days: int = 7):
    now = int(time.time())
    conn.execute(
        "INSERT OR REPLACE INTO notified VALUES (?,?,?,?)",
        (quarantine_id, pmail, now, now + ttl_days * 86400)
    )
    conn.commit()

def try_use_token(conn: sqlite3.Connection, token: str, action: str) -> bool:
    """
    Atomically mark token as used.
    Returns True if token was new (action should proceed).
    Returns False if token was already used (replay attempt).
    Uses INSERT OR IGNORE to avoid TOCTOU race between check and write.
    """
    h = hashlib.sha256(token.encode()).hexdigest()
    cursor = conn.execute(
        "INSERT OR IGNORE INTO used_tokens VALUES (?,?,?)",
        (h, int(time.time()), action)
    )
    conn.commit()
    return cursor.rowcount == 1

def cleanup_expired(conn: sqlite3.Connection):
    now = int(time.time())
    conn.execute("DELETE FROM notified WHERE token_expiry < ?", (now,))
    # Keep used_tokens for 30 days to prevent replay even after cleanup
    conn.execute("DELETE FROM used_tokens WHERE used_at < ?", (now - 30*86400,))
    conn.commit()
