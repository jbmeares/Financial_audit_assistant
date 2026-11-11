# infra/runbooks/

Step-by-step pages for the jobs James does by hand in the Supabase, GitHub and Era dashboards: swapping a key, and putting a backup back. Each page is meant to be followed top to bottom without anything else open.

**Goes here**
- One page per job, with exact menu paths, direct links and a check at the end that proves it worked.

**Doesn't go here**
- The keys themselves, or any part of one. Keys live in Supabase secrets, GitHub secrets and James's password manager.
- Routine money conversations. Those are `playbooks/`.

`read_context` doesn't serve `infra/`, so on claude.ai these pages are reached by their GitHub link: `https://github.com/jbmeares/financial_audit_assistant/tree/main/infra/runbooks`.

| Page | Use when |
| --- | --- |
| [era-read-key.md](era-read-key.md) | The Era read key (`ERA_READ_KEY`, `era_read`) is near expiry, expired, or may have leaked |
| [era-write-key.md](era-write-key.md) | The same, for the Era write key (`ERA_WRITE_KEY`, `era_write`) |
| [github-context-token.md](github-context-token.md) | `read_context` says GitHub refused the token, or the token may have leaked |
| [backup-secrets.md](backup-secrets.md) | The database password changed, or the backup passphrase needs changing |
| [restore-backup.md](restore-backup.md) | Finance data in Supabase is lost or damaged and a weekly backup should go back in |

## Rules for every page

- **Never paste a key into a chat.** The chat shows long keys as dots, and the dots get copied instead of the key (this broke the first nightly pull on 2026-11-11). Paste keys only into the dashboard field the page names, and into your password manager.
- **New key first, old key last.** Make the new key, put it in place, check it works, and only then revoke the old one. Nothing stops working in between.
- **Record the expiry.** Era keys have an expiry date in `ref.api_keys`, which is what makes the briefing warn 30 days ahead. A swap isn't done until that row is updated.
- **In a Claude Code session, Claude can do the SQL steps** (the `ref.api_keys` update and the checks) through the Supabase connector. The dashboard steps that involve a key value are always James's.
