#!/usr/bin/env python3
"""mail-inventory.py <domain> [--out FILE]

One account-by-account snapshot of a mail domain: every mailbox, its message count and the
bytes it holds. Capture it before a migration and again after, and diff the two files.

    python scripts/mail-inventory.py kaiteki.my --out docs/mail/kaiteki.my-2026-09-12.json

Reads MAIL_HOST and the admin account from the same per-domain config verify-mail.sh uses
(scripts/verify-mail.d/<domain>.conf), so a new domain is a new config file, not a new
script. The admin password comes from .env as MAIL_PASSWORD_<ACCOUNT> -- uppercased, every
non-alphanumeric character to _ -- or an interactive prompt.

Read-only. It issues JMAP reads and nothing else.

---------------------------------------------------------------------------------------
WHY THIS EXISTS, AND WHY IT IS JMAP

Stalwart v0.16.16 has no scriptable admin surface at all. `/api/principal` and every
sibling management path 404; the OAuth metadata advertises only mail/contacts/calendars
scopes, so there is no admin scope to ask for; `/account/` is a self-service page whose
bundle contains exactly two routes; and `--console` wants an argument this build does not
document. "Read it out of the admin UI" is not an available answer on this platform.

What IS available: the admin mailbox can run `Principal/get`, which enumerates every
account, and can then query other accounts' mail. That is the whole mechanism.

Sizes are summed from each message's `size` rather than read from `Quota/get`, because
Quota/get returns an empty list here -- no quotas are configured, so the server holds no
used-bytes figure to report. The sum is the size of the messages, so it will not equal the
volume on disk: it excludes RocksDB overhead and index space, and does not see any
compression or single-instance storage. Cross-checked 2026-09-12 at 7.86 GiB summed against
a 7.4 GiB volume, which is the right ballpark and the right direction.
---------------------------------------------------------------------------------------
"""
import argparse
import base64
import getpass
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
CONF_DIR = os.path.join(HERE, "verify-mail.d")

CORE = "urn:ietf:params:jmap:core"
MAIL = "urn:ietf:params:jmap:mail"
PRIN = "urn:ietf:params:jmap:principals"

# Pages of ids per round trip. 500 measured at ~0.3s for both the query and the size
# fetch on bpvps1, so the largest mailbox (145k messages) costs about a minute.
PAGE = 500


def die(msg):
    print(f"mail-inventory: {msg}", file=sys.stderr)
    sys.exit(2)


def read_conf(domain):
    """Pull MAIL_HOST and DEFAULT_ACCOUNTS out of the shell config verify-mail.sh reads.

    Parsed rather than sourced: this is a python script and the config is deliberately a
    handful of plain KEY='value' lines. An absent or empty value is an error, never a
    default -- the same rule the rest of the mail tooling follows, because a blank
    expectation is not a weaker check, it is no check.
    """
    path = os.path.join(CONF_DIR, f"{domain}.conf")
    if not os.path.isfile(path):
        die(f"no config at {path} -- add one, the way verify-mail.sh expects")
    values = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"""^\s*([A-Z_]+)\s*=\s*'([^']*)'\s*$""", line)
            if m:
                values[m.group(1)] = m.group(2)
    for key in ("MAIL_HOST", "DEFAULT_ACCOUNTS"):
        if not values.get(key):
            die(f"{key} is missing or empty in {path}")
    return values


def password_for(account):
    var = "MAIL_PASSWORD_" + re.sub(r"[^A-Za-z0-9]", "_", account).upper()
    value = os.environ.get(var)
    if value:
        return value
    if sys.stdin.isatty():
        return getpass.getpass(f"password for {account} (or set {var}): ")
    die(f"{var} is not set and there is no terminal to prompt on")


class Jmap:
    def __init__(self, host, account, password):
        self.host = host
        self.url = f"https://{host}/jmap"
        self.auth = "Basic " + base64.b64encode(
            f"{account}:{password}".encode()).decode()

    def session(self):
        req = urllib.request.Request(f"https://{self.host}/jmap/session",
                                     headers={"Authorization": self.auth})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                die(f"JMAP rejected the login for this account ({exc.code})")
            die(f"JMAP session returned HTTP {exc.code}")

    def __call__(self, using, calls, tries=4):
        body = json.dumps({"using": using, "methodCalls": calls}).encode()
        for attempt in range(tries):
            try:
                req = urllib.request.Request(
                    self.url, data=body, method="POST",
                    headers={"Content-Type": "application/json",
                             "Authorization": self.auth})
                with urllib.request.urlopen(req, timeout=240) as resp:
                    payload = json.load(resp)
            except urllib.error.HTTPError as exc:
                # Not transient: a 400 is a malformed request and a 401 is the wrong
                # password. Retrying either just sends the same broken call four times,
                # and against a mail server with fail2ban a retried 401 is worse than
                # useless. Only connection-level faults, below, are worth another go.
                if exc.code in (401, 403):
                    die(f"JMAP rejected the login for this account ({exc.code})")
                die(f"JMAP returned HTTP {exc.code}: {exc.read()[:400].decode(errors='replace')}")
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                # A long inventory is a lot of round trips against a production mail
                # server; one dropped connection should not throw away the whole run.
                if attempt == tries - 1:
                    raise
                print(f"    retry {attempt + 1}: {exc}", file=sys.stderr, flush=True)
                time.sleep(3 * (attempt + 1))
            else:
                name, result, _ = payload["methodResponses"][0]
                if name == "error":
                    die(f"JMAP error: {result}")
                return result
        return None  # unreachable


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("domain")
    ap.add_argument("--account", help="admin mailbox (default: first DEFAULT_ACCOUNTS entry)")
    ap.add_argument("--out", help="write JSON here instead of stdout")
    args = ap.parse_args()

    conf = read_conf(args.domain)
    account = args.account or conf["DEFAULT_ACCOUNTS"].split()[0]
    api = Jmap(conf["MAIL_HOST"], account, password_for(account))

    # Principal/get needs a concrete accountId; a null one is a 400 on this build. The
    # session lists exactly one account -- the caller's own -- and Principal/get against it
    # then returns EVERY principal on the server, which is the whole trick this relies on.
    session = api.session()
    if not session.get("accounts"):
        die("the JMAP session lists no accounts")
    own = next(iter(session["accounts"]))
    principals = api([CORE, PRIN],
                     [["Principal/get", {"accountId": own, "ids": None}, "0"]]).get("list")
    if not principals:
        die("Principal/get returned no accounts -- is this the admin mailbox?")

    rows = []
    for principal in principals:
        aid = principal["id"]
        name = principal.get("name") or principal.get("email") or aid
        count = 0
        total = 0
        position = 0
        while True:
            body = api([CORE, MAIL], [["Email/query",
                                       {"accountId": aid, "calculateTotal": True,
                                        "position": position, "limit": PAGE}, "0"]])
            ids = body.get("ids", [])
            if position == 0:
                count = body.get("total", 0)
            if not ids:
                break
            got = api([CORE, MAIL], [["Email/get",
                                      {"accountId": aid, "ids": ids,
                                       "properties": ["size"]}, "0"]])
            total += sum(e.get("size") or 0 for e in got["list"])
            position += len(ids)
            if position >= count:
                break
        rows.append({"account": name,
                     "description": principal.get("description"),
                     "messages": count,
                     "bytes": total})
        print(f"  {name:<28} {count:>7} msgs  {total / 1048576:>10.1f} MiB",
              file=sys.stderr, flush=True)

    rows.sort(key=lambda r: r["account"])
    doc = {
        "captured": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "domain": args.domain,
        "mail_host": conf["MAIL_HOST"],
        "source": "JMAP Principal/get + Email/query + Email/get(size)",
        "note": ("bytes are the summed sizes of the messages themselves, not the size of "
                 "the store on disk -- see the header of scripts/mail-inventory.py"),
        "accounts": rows,
        "totals": {"accounts": len(rows),
                   "messages": sum(r["messages"] for r in rows),
                   "bytes": sum(r["bytes"] for r in rows)},
    }
    text = json.dumps(doc, indent=2) + "\n"
    if args.out:
        path = args.out if os.path.isabs(args.out) else os.path.join(REPO_ROOT, args.out)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print(f"wrote {path}", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
