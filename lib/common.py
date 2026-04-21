"""
pmg-quarantine-junk: shared utilities
Token generation/validation, config loading, logging setup, IMAP helpers.
"""

import base64
import configparser
import hmac
import hashlib
import imaplib
import logging
import os
import sqlite3
import time

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_PATH = '/etc/pmg-quarantine-junk/config.ini'
SECRET_PATH = '/etc/pmg-quarantine-junk/secret.key'
STATE_DB    = '/var/lib/pmg-quarantine-junk/state.db'
LOG_FILE    = '/var/log/pmg-quarantine-junk.log'

def load_config(path=CONFIG_PATH):
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

def setup_logging(name: str, level: str = 'INFO') -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(getattr(logging, level.upper(), logging.INFO))
    if not logger.handlers:
        fh = logging.FileHandler(LOG_FILE)
        fh.setFormatter(logging.Formatter(
            '%(asctime)s %(name)s [%(levelname)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        ))
        logger.addHandler(fh)
        sh = logging.StreamHandler()
        sh.setFormatter(logging.Formatter('%(name)s [%(levelname)s] %(message)s'))
        logger.addHandler(sh)
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

    import re
    if not re.match(r'^C\d+R\d+T\d+(:bl)?$', quarantine_id):
        raise ValueError("Invalid quarantine ID in token")

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
    expiry = int(time.time()) + ttl_days * 86400
    conn.execute(
        "INSERT OR REPLACE INTO notified VALUES (?,?,?,?)",
        (quarantine_id, pmail, int(time.time()), expiry)
    )
    conn.commit()

def is_token_used(conn: sqlite3.Connection, token: str) -> bool:
    h = hashlib.sha256(token.encode()).hexdigest()
    row = conn.execute(
        "SELECT 1 FROM used_tokens WHERE token_hash=?", (h,)
    ).fetchone()
    return row is not None

def mark_token_used(conn: sqlite3.Connection, token: str, action: str):
    h = hashlib.sha256(token.encode()).hexdigest()
    conn.execute(
        "INSERT OR IGNORE INTO used_tokens VALUES (?,?,?)",
        (h, int(time.time()), action)
    )
    conn.commit()

def cleanup_expired(conn: sqlite3.Connection):
    now = int(time.time())
    conn.execute("DELETE FROM notified WHERE token_expiry < ?", (now,))
    # Keep used_tokens for 30 days to prevent replay even after cleanup
    conn.execute("DELETE FROM used_tokens WHERE used_at < ?", (now - 30*86400,))
    conn.commit()

# ---------------------------------------------------------------------------
# IMAP helpers
# ---------------------------------------------------------------------------

def imap_connect(host: str, port: int, use_ssl: bool = True,
                 timeout: int = 30) -> imaplib.IMAP4:
    if use_ssl:
        return imaplib.IMAP4_SSL(host, port, timeout=timeout)
    else:
        return imaplib.IMAP4(host, port)

def imap_login_plain(imap: imaplib.IMAP4, authzid: str,
                     authcid: str, password: str):
    """
    SASL PLAIN login with delegation (Zimbra/Carbonio admin impersonation).
    authzid  = target user (e.g. user@domain.com)
    authcid  = authenticating user (e.g. admin@domain.com)
    password = authenticating user's password
    """
    auth_bytes = f"{authzid}\x00{authcid}\x00{password}".encode('utf-8')
    encoded = base64.b64encode(auth_bytes)
    imap.authenticate('PLAIN', lambda _: encoded)

def imap_find_junk_folder(imap: imaplib.IMAP4) -> str:
    """
    Find the Junk/Spam folder by listing all folders and checking
    special-use attributes (\\Junk) or common names.
    Returns the folder name, or 'Junk' as fallback.
    """
    candidates = []
    try:
        status, folder_list = imap.list()
        if status == 'OK':
            for item in folder_list:
                if not item:
                    continue
                raw = item.decode('utf-8', errors='replace')
                # Check for \\Junk special-use attribute
                if r'\Junk' in raw or r'\Spam' in raw:
                    name = _extract_folder_name(raw)
                    if name:
                        return name
                candidates.append(raw)

        # Fall back: look for common names
        for raw in candidates:
            name = _extract_folder_name(raw)
            if name and name.lower() in ('junk', 'spam', 'junk e-mail',
                                         'junk email', 'спам', 'нежелательная почта'):
                return name
    except Exception:
        pass
    return 'Junk'

def imap_ensure_folder(imap: imaplib.IMAP4, folder: str):
    """Create folder if it doesn't exist."""
    status, _ = imap.select(f'"{folder}"')
    if status != 'OK':
        imap.create(f'"{folder}"')

def imap_append_message(imap: imaplib.IMAP4, folder: str, msg_bytes: bytes):
    """Append a raw RFC 822 message to folder."""
    imap.append(
        f'"{folder}"',
        r'(\Seen)',                          # mark as read — user sees it without unread badge
        imaplib.Time2Internaldate(time.time()),
        msg_bytes
    )

def _extract_folder_name(raw: str) -> str:
    """Extract folder name from IMAP LIST response line."""
    import re
    # Try quoted name first: ... "folder name"
    m = re.search(r'"([^"]+)"\s*$', raw)
    if m:
        return m.group(1)
    # Unquoted name at end
    parts = raw.rsplit(' ', 1)
    if len(parts) == 2:
        return parts[-1].strip()
    return ''
