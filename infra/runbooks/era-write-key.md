# Swap the Era write key

The write key lets one tool, `create_era_rule`, make a transaction rule in Era after you say yes to its preview. Nothing else uses it, and it can't move money. It lives in the Supabase secret `ERA_WRITE_KEY`, and its expiry date lives in `ref.api_keys` as `era_write`.

**When:** the briefing says `era_write` expires within 30 days (YELLOW) or has expired (RED); `create_era_rule` says "Era rejected ERA_WRITE_KEY (HTTP 401)"; or the key may have leaked.

**Time:** about 10 minutes. Have your password manager open.

## 1. Make the new key in Era

1. Open **https://era.app/app/api-keys** (Era dashboard, API keys) and sign in.
2. Start a new key. Era's docs call this "Make a key".
3. **Name:** something you'll recognise later, for example `household-finance write 2027`.
4. **Scopes:** Era ticks most scopes to start with. Untick everything except **`banking:write`**. Scopes can't be changed after the key is made.
   - The key made on 2026-11-09 has many extra scopes. The new one doesn't need them, and it doesn't need `banking:read` either: the preview uses the read key.
5. **Expiry:** pick the longest offered (365 days on a paid plan; there is no "never").
6. Create it. Era shows the key **once**. It starts with `fmk_`.
7. Copy it straight into your password manager, as a new entry. Write down the **expiry date** Era shows.

## 2. Put it in Supabase

1. Open **https://supabase.com/dashboard/project/lbhrkwjffgbfvmpyjuai/functions/secrets**
   (Supabase > project "Financial Audit Assitant" > left sidebar **Edge Functions** > **Secrets**).
2. Under **Add or replace secrets**, set **Name** to `ERA_WRITE_KEY` exactly, and paste the new key into **Value**.
3. Press **Save**. Saving a secret with an existing name replaces it. `ERA_WRITE_KEY` now shows an updated time in the list.

## 3. Check it works

The key is only used when a rule is created, so the only real check is creating one.

- **Easiest:** do nothing now. The next time you make a rule with `create_era_rule`, it either works or says "Era rejected ERA_WRITE_KEY". If it says that, go back to step 2 and paste again from the password manager.
- **To check now:** in a Claude Code session, say "test the new Era write key with a throwaway rule, then delete it". Claude did exactly this on 2026-11-10 when the tool was built.

## 4. Record the new expiry

Open **https://supabase.com/dashboard/project/lbhrkwjffgbfvmpyjuai/sql/new** (left sidebar **SQL Editor** > **New query**). Paste this, change both dates first (`expires_on` is the expiry Era showed, the note's date is today), and press **Run**.

```sql
update ref.api_keys set valid_to = current_date
 where key_name = 'era_write' and valid_to is null;

insert into ref.api_keys (key_name, scope, expires_on, note)
values ('era_write', 'banking:write', 'YYYY-MM-DD',
        'create_era_rule. Supabase secret ERA_WRITE_KEY. Created YYYY-MM-DD by James.');

select key_name, expires_on, days_left from ref.current_api_keys where valid_to is null;
```

**Good:** one `era_write` row, with the new date and about 365 `days_left`. The briefing's key warning goes away.

## 5. Revoke the old key

1. Back at **https://era.app/app/api-keys**, find the **old** key (the older creation date; the 2026-11-09 one, the first time).
2. Revoke it. Era's docs say a revoked key stops working from its next request. They don't name the button, so look for **Revoke** or **Delete** beside the key, and check you picked the old one, not the one you just made.
3. Mark the old entry in your password manager as revoked, or delete it.

Done. If anything above went wrong and you can't tell why, open a Claude Code session and say "the Era write key swap failed at step N".
