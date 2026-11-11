# Swap the Era read key

The read key lets the nightly pull (`era-pull`) and the `create_era_rule` preview read Era. It lives in the Supabase secret `ERA_READ_KEY`, and its expiry date lives in `ref.api_keys` as `era_read`.

**When:** the briefing says `era_read` expires within 30 days (YELLOW) or has expired (RED); the pull fails with "Era rejected the read key (HTTP 401)"; or the key may have leaked.

**Time:** about 10 minutes. Have your password manager open.

## 1. Make the new key in Era

1. Open **https://era.app/app/api-keys** (Era dashboard, API keys) and sign in.
2. Start a new key. Era's docs call this "Make a key".
3. **Name:** something you'll recognise later, for example `household-finance read 2027`.
4. **Scopes:** Era ticks most scopes to start with. Untick everything except **`banking:read`**. Scopes can't be changed after the key is made.
   - The key made on 2026-11-09 has many extra scopes. The new one doesn't need them.
5. **Expiry:** pick the longest offered (365 days on a paid plan; there is no "never").
6. Create it. Era shows the key **once**. It starts with `fmk_`.
7. Copy it straight into your password manager, as a new entry. Write down the **expiry date** Era shows.

## 2. Put it in Supabase

1. Open **https://supabase.com/dashboard/project/lbhrkwjffgbfvmpyjuai/functions/secrets**
   (Supabase > project "Financial Audit Assitant" > left sidebar **Edge Functions** > **Secrets**).
2. Under **Add or replace secrets**, set **Name** to `ERA_READ_KEY` exactly, and paste the new key into **Value**.
3. Press **Save**. Saving a secret with an existing name replaces it. `ERA_READ_KEY` now shows an updated time in the list.

## 3. Check it works

1. Open **https://supabase.com/dashboard/project/lbhrkwjffgbfvmpyjuai/sql/new** (left sidebar **SQL Editor** > **New query**).
2. Paste this and press **Run**. It asks for a pull now, using the same call the nightly schedule makes. No key goes in the text.

   ```sql
   select net.http_post(
     url := 'https://lbhrkwjffgbfvmpyjuai.supabase.co/functions/v1/era-pull',
     body := '{"mode": "manual"}'::jsonb,
     headers := jsonb_build_object(
       'Content-Type', 'application/json',
       'Authorization', substring(command from 'Bearer [A-Za-z0-9._-]+')),
     timeout_milliseconds := 150000)
   from cron.job where jobname = 'era-pull-nightly';
   ```

3. Wait two minutes. Replace the editor's text with this and press **Run**:

   ```sql
   select id, kind, status, started_at, error
   from raw.pull_runs order by id desc limit 1;
   ```

4. **Good:** `kind` is `manual` and `status` is `ok` (or `partial`).
   - `status` `failed` with "Era rejected the read key": the secret holds the wrong text. Go back to step 2 and paste again from the password manager.
   - No new `manual` row: a pull ran in the last 10 minutes, so this one was refused. Wait 10 minutes and run step 3.2 again.

## 4. Record the new expiry

In the SQL Editor, replace the text with this. Change both dates first: `YYYY-MM-DD` in `expires_on` is the expiry Era showed, and the one in the note is today. Press **Run**.

```sql
update ref.api_keys set valid_to = current_date
 where key_name = 'era_read' and valid_to is null;

insert into ref.api_keys (key_name, scope, expires_on, note)
values ('era_read', 'banking:read', 'YYYY-MM-DD',
        'Nightly pull. Supabase secret ERA_READ_KEY. Created YYYY-MM-DD by James.');

select key_name, expires_on, days_left from ref.current_api_keys where valid_to is null;
```

**Good:** one `era_read` row, with the new date and about 365 `days_left`. The briefing's key warning goes away.

## 5. Revoke the old key

1. Back at **https://era.app/app/api-keys**, find the **old** key (the older creation date; the 2026-11-09 one, the first time).
2. Revoke it. Era's docs say a revoked key stops working from its next request. They don't name the button, so look for **Revoke** or **Delete** beside the key, and check you picked the old one, not the one you just made.
3. Mark the old entry in your password manager as revoked, or delete it.

Done. If anything above went wrong and you can't tell why, open a Claude Code session and say "the Era read key swap failed at step N".
