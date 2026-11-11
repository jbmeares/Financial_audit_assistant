# Change the backup secrets

The weekly backup ([`db-backup.yml`](../../.github/workflows/db-backup.yml), Sundays 09:00 UTC) uses two GitHub repository secrets:

| Secret | What it is | Change it when |
| --- | --- | --- |
| `SUPABASE_DB_URL` | The database's **Session pooler** connection string, with the database password in it | The database password was reset, or the backup fails with a connection or password error |
| `BACKUP_PASSPHRASE` | The passphrase that encrypts each backup | It may have leaked |

The restore ([restore-backup.md](restore-backup.md)) uses the same secrets, plus `BACKUP_PASSPHRASE_OLD` after a passphrase change.

Neither has an expiry date, so neither is in `ref.api_keys`.

All GitHub secrets for this repo are at **https://github.com/jbmeares/financial_audit_assistant/settings/secrets/actions**
(the repo > **Settings** tab > left sidebar, under Security, **Secrets and variables** > **Actions** > **Repository secrets**). To change one, press the **pencil** icon on its row, paste the new value, and press **Update secret**.

## A. Update SUPABASE_DB_URL

### 1. Copy the Session pooler string

1. Open **https://supabase.com/dashboard/project/lbhrkwjffgbfvmpyjuai?showConnect=true&method=session**
   (Supabase > project "Financial Audit Assitant" > the **Connect** button at the top of the page > **Connection String** tab > **Method**: **Session pooler**).
2. Check you have the right one:
   - **Right:** starts `postgresql://postgres.lbhrkwjffgbfvmpyjuai:`, the host ends in **`pooler.supabase.com`**, and the port is **5432**.
   - **Wrong:** **Direct connection** (host `db.lbhrkwjffgbfvmpyjuai.supabase.co`). It only works over IPv6, and GitHub's machines can't reach it.
   - **Wrong:** **Transaction pooler** (port **6543**). The backup tool needs a session.
3. Copy it into a new password manager entry, not a chat.
4. In that entry, replace `[YOUR-PASSWORD]`, brackets included, with the database password. If the password has any of `@ : / ? # %` in it, the string breaks; reset the password (below) to one with letters and numbers only.

### 2. Put it in GitHub

On the secrets page above, press the pencil on **`SUPABASE_DB_URL`**, paste the whole string, and press **Update secret**.

### 3. Check it works

Run the backup now (see "Run the backup by hand" at the bottom). **Good:** a green check. A red "Dump the finance schemas" step means the string is wrong: check step 1.2 and 1.4.

### If you need to reset the database password

1. Open **https://supabase.com/dashboard/project/lbhrkwjffgbfvmpyjuai/database/settings**
   (the project's database settings page). In the **Database password** section, press **Reset database password**.
2. Let it generate one, or type one with letters and numbers only. Save it in your password manager.
3. Do part A above with the new password.
4. Also check the two Edge Functions still reach the database, because they connect with a database address Supabase gives them itself. It hasn't been confirmed whether Supabase updates that address the moment the password changes. Run the check in [era-read-key.md](era-read-key.md) step 3, and ask a claude.ai chat for the briefing. If either fails, open a Claude Code session and say so.

Reset the password only if it may have leaked. Nothing else needs it changed.

## B. Change BACKUP_PASSPHRASE

Backups made before the change stay locked with the **old** passphrase. GitHub keeps them for 90 days, so the old passphrase is kept for 90 days too, as `BACKUP_PASSPHRASE_OLD`. The restore tries both.

1. In your password manager, make a new passphrase: random, at least 32 characters (or 6 random words). Save it as a new entry.
2. Rename the old entry to `Backup passphrase (old, keep until YYYY-MM-DD)`, with the date 90 days from today.
3. On the secrets page, press **New repository secret**. **Name:** `BACKUP_PASSPHRASE_OLD`. **Secret:** the old passphrase. Press **Add secret**. (If `BACKUP_PASSPHRASE_OLD` is already there from an earlier change, press its pencil and replace it instead.)
4. Press the pencil on **`BACKUP_PASSPHRASE`**, paste the new passphrase, press **Update secret**.
5. Run the backup by hand (below). **Good:** a green check.
6. Put a reminder in your calendar for the date in step 2. On that day, delete `BACKUP_PASSPHRASE_OLD` (the **trash** icon on its row) and the old password manager entry.

## Run the backup by hand

1. Open **https://github.com/jbmeares/financial_audit_assistant/actions/workflows/db-backup.yml**
   (the repo > **Actions** tab > left list **db-backup**).
2. Press **Run workflow** (right side, above the list of runs), leave **Branch: main**, and press the green **Run workflow**.
3. Refresh after a few seconds. The new run appears at the top. It takes about 2 to 3 minutes.
4. **Good:** a green check, and the run page lists an artifact `finance-backup-<number>` at the bottom.
