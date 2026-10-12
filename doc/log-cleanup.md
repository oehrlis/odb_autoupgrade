# Log Cleanup

Safe cleanup of the AutoUpgrade `global_log_dir` (`AU_LOG_DIR`).

## What AutoUpgrade Reuses

AutoUpgrade writes runtime data below `global_log_dir` that it needs across runs. The cleanup script preserves
these paths unconditionally:

<!-- markdownlint-disable MD013 MD060 -->
| Path (below `global_log_dir`) | Purpose | Cleanup rule |
| --- | --- | --- |
| `cfgtoollogs/patch/auto/aru/request_id_cache.json` | Previous OUA gold image request ID; reused to avoid a new request | always keep |
| `cfgtoollogs/patch/auto/aru/*.csd` | Checksum store of downloaded files; prevents re-download when the file exists | always keep |
| `cfgtoollogs/patch/auto/lock/` | Run lock directory | always keep; cleanup refuses while AutoUpgrade runs |
| `.ap_build` | Written at the root by AutoUpgrade; purpose unknown | always keep |
<!-- markdownlint-restore -->

Job directories (containing `status.json` or `progress.json`) are needed while the job is incomplete.
The N newest are kept regardless of age (`--keep-jobs N`, default 3).

Log files, diagnostic directories (`aru/*.log`, `aru/ous.log`, `config_files/`, `examiner/`, `sql/`) and older
job directories are deleted by age.

The download folder (`*.zip`, `bug-map.json`, `aru-bug-map.json`, `patches_info.json`, `au_patch.env`) and the
keystore subdirectory `.autoupgrade/` are not under `global_log_dir` and are never touched by log cleanup.

## Default Mode: List Only

Running `au_log_cleanup.sh` without `--delete` prints what would be deleted and what is kept, with the reason for
every kept file. No files are removed.

```bash
# List what would be deleted (safe, no changes)
bin/au_log_cleanup.sh

# Same as default listing
bin/au_log_cleanup.sh --dry-run
```

## Delete Mode

`--delete` removes files; `--yes` skips the interactive confirmation.

```bash
# Delete files older than 30 days, keep 3 newest job directories (interactive confirm)
bin/au_log_cleanup.sh --delete

# Non-interactive
bin/au_log_cleanup.sh --delete --yes

# Aggressive: delete everything older than 0 days, keep 1 job
bin/au_log_cleanup.sh --delete --yes --older-than 0 --keep-jobs 1
```

## Refusals

The script refuses to run when:

- The target directory is `/`, `$HOME`, or does not exist
- The target has no `cfgtoollogs/` subdirectory (not an AutoUpgrade log directory)
- `autoupgrade.jar` is running for the current user (detected via `pgrep -f`)

The `lock/` directory is never touched regardless.

## Output

Every preserved file is named with the reason. Nothing is held back silently. The summary counts deleted,
preserved and skipped entries.

Example output (listing mode):

```text
[INFO] KEEP cfgtoollogs/patch/auto/aru/request_id_cache.json (OUA request cache)
[INFO] KEEP cfgtoollogs/patch/auto/aru/12345678.csd (checksum store)
[INFO] KEEP cfgtoollogs/patch/auto/lock/ (run lock)
[INFO] KEEP job_2026-10-01_19.32/ (newest 3 job directories)
[INFO] DELETE cfgtoollogs/patch/auto/aru/autoupgrade_patching.log (older than 30d)
...
[INFO] Summary: 12 would be deleted, 8 kept, 0 skipped
```

## Tested Behaviour

The log directory cleanup was verified with offline tests (no MOS access required):

- Wiping `logs/*` completely does not change where the next run stops. The next run stops at the same message
  as the first run ("Operation requires MOS credentials...") with no new error.
- The worst case `rm -rf logs/*` produces the same stop point.
- A create_home run without a source home after a wipe stops at `LocatePatchFiles` ("No 19.x Oracle Database
  Release Update file is found"), identical to before the wipe.

Loss of the `.csd` checksum store and `request_id_cache.json` (by deletion, not by the cleanup script which
keeps them) causes AutoUpgrade to re-validate or re-request on the next run. The impact on MOS-authenticated
flows (gold image re-request) has not been measured.
