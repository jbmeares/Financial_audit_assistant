# read_context

*Reads.* Returns a Markdown file from this repo, or lists a folder.

**Takes** `path`: a file such as `CLAUDE.md` or `people/james.md`, a folder ending in `/` such as `life/`, or `""` for the top level.

**Returns** `content` for a file (cut at 200 KB, with `truncated: true`), or `entries` for a folder (Markdown files and subfolders only).

**When** at the start of a conversation on claude.ai (CLAUDE.md, constitution, the person's profile), and whenever the conversation needs the words behind the numbers.

**Guards** Markdown files only, never `infra/` or hidden files. Reads the `main` branch through a read-only GitHub token (secret `GITHUB_CONTEXT_TOKEN`). If the token is missing or expired, it says so in one sentence. On claude.ai the repo is read-only: park new context with [log_question](log_question.md).
