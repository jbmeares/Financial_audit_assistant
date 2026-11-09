# infra/scripts/

Repo tooling.

- `check-map`: fails when a top-level folder has no README.md, isn't listed in CLAUDE.md under "## Folders", or is listed but missing. Runs on every pull request (`.github/workflows/check-map.yml`). Run it locally with `infra/scripts/check-map`.
- `test_check_map.py`: tests for `check-map`. Run with `python3 infra/scripts/test_check_map.py`.
