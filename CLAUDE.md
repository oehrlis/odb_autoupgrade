# CLAUDE.md - odb_autoupgrade

## Project

Oracle AutoUpgrade patching tooling (19c, 21c, 23ai/26ai): wrapper around `autoupgrade.jar` for patch download,
create_home and deploy, MOS keystore lifecycle, JAR update, patch profiles, gold images and per-host config
generation. Runs standalone or as an OraDBA extension (`oradba_extension.sh add oehrlis/odb_autoupgrade`).
Bash 4.2+, no compiled parts. Public repository - no customer data, no MOS credentials, no facts derived from
decompiling Oracle binaries (cite docs, help output, messages, test runs).

The legacy repository `oehrlis/autoupgrade` is private (MOS wallet leak in its history) and read-only.

## Layout

- `bin/au_*.sh` - user-facing scripts; `au_run.sh` is the AutoUpgrade wrapper (config rendering, proxy,
  truststore, Java selection). Old names (`run_autoupgrade.sh`, `update_autoupgrade.sh`,
  `create_mos_keystore.sh`) are deprecation shims until 1.0
- `lib/au_lib.sh` - loader for `common.sh` (logging, die), `au_env.sh` (config precedence, file security,
  rendering, profiles), `au_net.sh`, `au_home.sh`, `au_logs.sh`, `au_tools.sh`
- `etc/au_patch.cfg` - one template for download, create_home and deploy; `etc/profiles/*.profile` - patch
  profiles; `etc/groups/` - site group examples; `.extension` - OraDBA metadata
- `tests/*.bats` + `tests/fixtures/` - BATS suite; `scripts/build.sh` - release tarball
- `doc/` - user docs (`index.md` is the entry point), `doc/design.md` (Phase 2 design and decisions),
  `doc/release_notes/v<version>.md`
- Local only (gitignored): `tasks/` (plan, state, lessons, `au_facts.md`), `ref/`, `jar/*.jar`, `keystore/`,
  `patches/*`, `etc/*.env`

## Make Targets

- `make test` - full BATS suite; run it alone (parallel bats runs contend for temp dirs)
- `make lint` - `lint-shell` (shellcheck incl. `tests/*.bats`) and `lint-markdown`
- `make ci` - lint + test, the same as the GitHub workflow
- `make build` - `dist/odb_autoupgrade-<VERSION>.tar.gz` + `.sha256` (755/644, owner 0/0)
- `make version-bump-patch|minor|major`, `make tag`, `make clean`

## Conventions

- OraDBA script header and function headers; `set -euo pipefail`; shellcheck clean, CI flags what macOS misses
- Every external tool a test touches gets a stub in `setup` (`java`, `curl`, `id`, `expect`, ...)
- A regression test per fix; it must fail on `origin/main` and pass on the branch
- Skip or filter paths log what they skipped - never a silent `continue`
- CHANGELOG: `## <version> - YYYY-MM-DD` with `Added | Changed | Fixed | Removed`; `## Unreleased` until release
- Branch per block (`fix/...`, `docs/...`), squash merge after green CI, never force-push

## Release Flow

1. On a branch: `VERSION`, CHANGELOG section, `doc/release_notes/v<version>.md`, `doc/index.md` link
2. PR, green CI, squash merge
3. On the updated `main`: `make tag`, then push the tag (`git push origin v<version>`) - `git push` alone does not
   transfer tags
4. `.github/workflows/release.yml` runs `make ci`, checks `VERSION` against the tag, builds and uploads
   `odb_autoupgrade-<version>.tar.gz` and `.sha256`
5. Verify the published asset: download both, `sha256sum -c`, `tar -tvzf` shows 755/644 and 0/0,
   `oradba_extension.sh add oehrlis/odb_autoupgrade@v<version>` installs and `validate` passes

## Quick Reference

- Lint: `make lint`; test: `make test`; secrets scan: `gitleaks git --no-banner .`
- Secrets: 1Password via `op read` - nothing secret in the repo, the tests or the fixtures

## Rules (always active)

@.claude/rules/markdown-lint.md
@.claude/rules/shell-scripts.md

## Skills (load on demand)

- Bash Header -> /bash-header
- Makefile -> /makefile
- Markdown Doc -> /markdown-doc
- Markdown Lint -> /markdown-lint
- Simplify -> /simplify
- Structured Analysis -> /structured-analysis
