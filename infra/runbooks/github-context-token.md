# Swap the GitHub context token

The context token lets `read_context` read this repo's Markdown files, so claude.ai chats can see the constitution, profiles and plan. It is a fine-grained GitHub token that can only read this one repo. It lives in the Supabase secret `GITHUB_CONTEXT_TOKEN`.

It was made on 2026-11-11 with **no expiry** (James's choice), so it has no row in `ref.api_keys` and the briefing never warns about it.

**When:** `read_context` says "GitHub refused the read token"; or the token may have leaked.

**Time:** about 10 minutes. Have your password manager open.

## 1. Make the new token in GitHub

1. Open **https://github.com/settings/personal-access-tokens/new**
   (github.com > your profile photo, top right > **Settings** > left sidebar, at the bottom, **Developer settings** > **Personal access tokens** > **Fine-grained tokens** > **Generate new token**).
2. **Token name:** for example `finance read_context 2026-11`.
3. **Resource owner:** `jbmeares`.
4. **Expiration:** **No expiration** keeps things as they are. If you pick a date instead, ask Claude Code afterwards to add a `github_context` row to `ref.api_keys`, so the briefing warns 30 days ahead.
5. **Repository access:** **Only select repositories**, then pick **jbmeares/financial_audit_assistant**. Nothing else.
6. **Permissions:** under **Repository permissions**, set **Contents** to **Read-only**. (On the newer page this is **Add permissions** > tick **Contents** > set it to **Read-only**.) **Metadata: Read-only** is added by itself. Leave every other permission off.
7. Press **Generate token**, then confirm.
8. GitHub shows the token **once**. It starts with `github_pat_`. Copy it straight into your password manager, as a new entry.

## 2. Put it in Supabase

1. Open **https://supabase.com/dashboard/project/lbhrkwjffgbfvmpyjuai/functions/secrets**
   (Supabase > project "Financial Audit Assitant" > left sidebar **Edge Functions** > **Secrets**).
2. Under **Add or replace secrets**, set **Name** to `GITHUB_CONTEXT_TOKEN` exactly, and paste the new token into **Value**.
3. Press **Save**. `GITHUB_CONTEXT_TOKEN` now shows an updated time in the list.

## 3. Check it works

1. Open a **new** chat on claude.ai with the "Household finance" connector on.
2. Say: `Use read_context to read CLAUDE.md and tell me its first heading.`
3. **Good:** it answers "Household finance: start here".
   - "GitHub refused the read token": the secret holds the wrong text, or the token can't see the repo. Check step 1.5 and 1.6, then paste again in step 2.

## 4. Revoke the old token

1. Open **https://github.com/settings/personal-access-tokens** (the same **Fine-grained tokens** list).
2. Click the **old** token's name (check the name and creation date; it is not the one you just made).
3. At the bottom of its page, press **Delete**, and confirm.
4. Mark the old entry in your password manager as revoked, or delete it.

Done. If anything above went wrong and you can't tell why, open a Claude Code session and say "the GitHub token swap failed at step N".
