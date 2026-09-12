# Your mailbox — setup card

One page. Hand it to any new staff member with their address and a temporary password;
they should not need to ask anyone anything else.

This is the **human** card. The operator's side — creating the mailbox, where the
temporary password goes, what "handed over out-of-band" means in practice — is the
[convention](#convention-for-the-operator) at the bottom, and the per-domain onboarding
checklist (#12) links here for the "mailboxes" step.

---

## 1. Webmail — this is the normal way

Open the webmail for your brand in any browser, phone included. Nothing to install.

| Your address ends in | Go to |
|---|---|
| `@blueprintdigital.my` | **https://webmail.blueprintdigital.my** |
| `@reservetoday.app` | **https://webmail.blueprintdigital.my** (there is no separate reservetoday webmail — this is the right one) |
| `@kaiteki.my` | **https://webmail.kaiteki.my** |

- **Username:** your full email address, e.g. `danielchua@blueprintdigital.my`
- **Password:** the temporary one you were given

**First thing, before you read any mail: change the password.** Open the settings
(gear icon), find *Password* / *Security*, and set your own. The temporary one is only
meant to get you through the door once. Anyone with it can read your mail until you do
this.

Any brand's webmail will let you sign in — a bookmark to the "wrong" one is not a dead
end, it just shows the other logo.

You can add it to your phone's home screen (Share → *Add to Home Screen* on iPhone,
⋮ → *Add to Home screen* on Android) and it behaves like an app.

## 2. Optional — a mail app on your phone or desktop

Only if you prefer Apple Mail, Outlook, Thunderbird, Gmail-app-with-another-account, etc.
Webmail above already does everything.

| Setting | Value |
|---|---|
| Account type | **IMAP** |
| Username | your **full** email address |
| Password | your mailbox password (the one you set in webmail) |
| Incoming server | `mail.blueprintdigital.my` |
| Incoming port | **993** |
| Incoming security | **SSL/TLS** |
| Outgoing (SMTP) server | `mail.blueprintdigital.my` |
| Outgoing port | **465** |
| Outgoing security | **SSL/TLS** |
| Outgoing authentication | same username and password as incoming |

Three things that trip people up:

- **The server is `mail.blueprintdigital.my` for every domain** — including
  `@reservetoday.app` and `@kaiteki.my` addresses. It is one shared mail server;
  the domain in your address does not change the server name. (Kaiteki devices set up
  before September 2026 use `mail.kaiteki.my`; that still works, same box.)
- **Pick SSL/TLS, not STARTTLS.** If the app asks for STARTTLS or suggests port **587**
  or **143**, say no — those ports are deliberately closed and it will just time out.
  It is 993 in and 465 out, both "SSL".
- **Username is the whole address**, not the part before the `@`.

## 3. Something's wrong?

| Symptom | Almost always |
|---|---|
| "Wrong password" in webmail on day one | Password copied with a trailing space, or you have already changed it and are trying the temporary one. |
| Mail app says "cannot connect" | It picked STARTTLS / 587 / 143. Set 993 + 465 with SSL/TLS. |
| Mail app says "certificate not trusted" | The server name is wrong. It must be exactly `mail.blueprintdigital.my` (or `mail.kaiteki.my`). Not `imap.`, not your domain. |
| Webmail logo is the wrong brand | Harmless — see above. |

Still stuck: `admin@blueprintdigital.my`.

---

## Convention (for the operator)

This is how every mailbox on the platform is issued. It is a **convention**, not a
feature: Stalwart 0.16 has no "must change password at next login" flag, so the forced
change is the hand-over script plus the webmail's own password-change page.

1. **Create the account** with a random temporary password — see "Configuring this
   build" in `vps/bpvps1/stacks/stalwart/README.md` (`x:Account/set`). Generate it
   (`openssl rand -base64 24`), never invent it.
2. **Store it locally** in the repo `.env` as `MAIL_PASSWORD_<ACCOUNT>` (address
   uppercased, non-alphanumerics to `_`; `hello@reservetoday.app` →
   `MAIL_PASSWORD_HELLO_RESERVETODAY_APP`) with a comment saying it is temporary. That is
   what lets `scripts/verify-mail.sh <domain> <account>` prove the login once.
3. **Prove it works before handing it over**: `./scripts/verify-mail.sh <domain>
   <account>` and require the `JMAP login` line to PASS. Delivery legs can be `--skip`ped
   only when the domain's DNS is not yet published (exit `3`, never mistaken for green).
4. **Hand the temporary password over out-of-band** — in person, a phone call, a
   disappearing message. **Never on a GitHub issue, never in a commit, never in chat or
   an agent session transcript.** Tickets record *that* a password was delivered and
   when, nothing more. This card is what goes with it.
5. **The user changes it at first webmail login** (Bulwark's built-in password change —
   `STALWART_FEATURES=true` in the compose is what enables it). From that moment the
   `.env` line is stale on purpose: `verify-mail.sh` for that account fails its login,
   which is the correct signal that the account now belongs to its owner. Remove the
   line or leave it commented as history; do not go asking for the new one.

Passwords are hashed in Stalwart's store, so a forgotten one is a **reset**, never a
recovery: same steps from 1, and the old device sessions stop working.
