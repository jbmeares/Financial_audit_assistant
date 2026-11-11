# Put a backup back

The Free plan keeps no backups of its own. The only ones are the weekly encrypted dumps made by [`db-backup.yml`](../../.github/workflows/db-backup.yml) every Sunday at 09:00 UTC, kept by GitHub for 90 days. This page puts one back with the [`db-restore`](../../.github/workflows/db-restore.yml) GitHub Action, so nothing needs installing on your computer.

**When:** finance data in Supabase is lost or damaged: tables empty or missing, a bad change that a void can't fix.

**Not this page:**
- **One wrong row.** Void it with a reason (constitution rule 5). A restore throws away everything written since the backup.
- **"Project paused".** If the Supabase dashboard says the project is paused, press **Restore project** on that page. That wakes the project with all its data; no backup is needed.
- **The whole Supabase project is gone.** See [the last section](#if-the-whole-project-is-gone).

**Time:** about 15 minutes.

## What a backup holds

| In the backup | Not in the backup (a restore leaves it alone) |
| --- | --- |
| The six finance schemas: `raw`, `ref`, `ledger`, `knowledge`, `calc`, `actions`. That is every table and its rows, the views, the calc and action functions, and who may read or run them | The `mcp` schema (the `query` tool's `mcp.run_query`), the roles, `pg_cron` and the nightly schedule, `pg_net`, Supabase Auth (your sign-in user, OAuth settings), the Edge Functions and their secrets |

### Roles and passwords: nothing to reset

The three roles, `ingest`, `assistant_read` and `assistant_act`, have no login and no password. The Edge Functions connect once and switch into a role for each call ([finance-mcp README](../functions/finance-mcp/README.md), "How the database is reached"). Roles live outside the six schemas, so a restore doesn't touch them, and the backup brings back which tables each role may read or run. The only password is the database's own, inside `SUPABASE_DB_URL`, and a restore doesn't change it.

## 1. Pick the backup

1. Open **https://github.com/jbmeares/financial_audit_assistant/actions/workflows/db-backup.yml**
   (the repo > **Actions** tab > left list **db-backup**).
2. Pick the newest run with a **green check** from **before** the damage happened. Click it.
3. Check the bottom of the run page lists an artifact named `finance-backup-<number>`. (Older than 90 days: it's gone, pick a newer run.)
4. Look at the page's web address. It ends `/actions/runs/<run ID>`, a long number like `19312345678`. Copy that number.

## 2. Rehearse first (changes nothing)

1. Open **https://github.com/jbmeares/financial_audit_assistant/actions/workflows/db-restore.yml**
   (the repo > **Actions** tab > left list **db-restore**).
2. Press **Run workflow** (right side, above the list of runs). A small form opens:
   - **Use workflow from:** leave **Branch: main**.
   - **Run ID of the db-backup run…:** paste the number from step 1.4.
   - **Type RESTORE … or TEST …:** type `TEST`.
3. Press the green **Run workflow**. Refresh after a few seconds; the run appears at the top. It takes about 2 minutes.
4. **Good:** a green check. The step "Prove it restores into a scratch database" ends with a number, the count of pulls in that backup.
   - Red at **Download the backup**: the run ID is wrong, or that run's backup has expired.
   - Red at **Decrypt it** ("Neither … opens this backup"): the passphrase in GitHub isn't the one that backup was made with. See [backup-secrets.md](backup-secrets.md), part B.

## 3. Restore

1. Same page, **Run workflow** again, same run ID, and this time type `RESTORE` (capitals).
2. Press the green **Run workflow**. It takes about 3 minutes. In order, it:
   1. downloads, decrypts and test-restores the backup, as in the rehearsal;
   2. saves the live database as it is now, encrypted, as an artifact named `finance-before-restore-<number>` on this run, so you can undo;
   3. replaces the six schemas with the backup, all in one transaction. If anything fails, the live database is left exactly as it was.
3. **Good:** a green check. The last real step, **Show what the live database holds now**, lists the time of the last pull in the backup and how many transactions, ledger payments and life events came back.
4. Write down this run's own run ID (the end of its web address). You need it to undo.

## 4. Afterwards

1. **Catch up the bank data.** A pull re-reads the last 30 days, and a backup is at most a week old, so one pull fills the gap. Run the check in [era-read-key.md](era-read-key.md), step 3 (it asks for a pull now). Or wait for tonight's.
2. **Redo what was said since the backup.** Anything written after the backup was taken is gone: confirmed or rejected matches, recorded balances, bill changes, life events, answered questions. The pending matches show up again in the briefing. Balances and life events have to be told again.
3. **Check the chat works.** In a new claude.ai chat, ask for the briefing. It should open normally.

## Undo a restore

Run **db-restore** again (step 3), with the run ID of the **restore run** from step 3.4 instead of a backup run. It finds that run's `finance-before-restore` copy and puts it back. Rehearse with `TEST` first if you like.

If the restore run warned "The live database couldn't be dumped, so there is no before-restore copy", the database was too damaged to save, and there is nothing to undo to.

## Look inside a backup on your own computer

Only needed to check what a backup holds without touching Supabase. Ask for help in a Claude Code session if this is new.

1. On the db-backup run page, click the artifact name to download it. Unzip it to get `finance.dump.gpg`.
2. Install **Gpg4win** (gpg4win.org) and **PostgreSQL 17** (postgresql.org/download/windows; only "Command Line Tools" is needed).
3. In PowerShell, in the folder with the file:
   ```powershell
   gpg --output finance.dump --decrypt finance.dump.gpg   # asks for the backup passphrase
   pg_restore --list finance.dump                          # lists every table in it
   ```
4. Delete `finance.dump` when you're done. It's your money data, unencrypted.

## If the whole project is gone

This hasn't been rehearsed. It is a rebuild, done in a Claude Code session with James present, roughly:

1. Make a new Supabase project. Apply every file in `infra/migrations/` in order (this makes the roles, `mcp`, the extensions and empty tables).
2. Point `SUPABASE_DB_URL` in GitHub at the new project's Session pooler ([backup-secrets.md](backup-secrets.md), part A), then run **db-restore** with `RESTORE`. It replaces the empty tables with the backup.
3. Redeploy `era-pull` and `finance-mcp`, set their secrets again (`ERA_READ_KEY`, `ERA_WRITE_KEY`, `GITHUB_CONTEXT_TOKEN`, `FINANCE_ALLOWED_EMAILS`), and redo the Auth settings in the [finance-mcp README](../functions/finance-mcp/README.md), "Settings it needs".
4. Change the project address and anon key everywhere they're written: the nightly schedule (a new migration), `pull-health.yml`, the consent page's Site URL on Vercel, and the claude.ai connector and `.mcp.json`.
