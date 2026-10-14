# Patch Profiles

A patch profile is a named patch selection that is shared by download, create_home and deploy.
Profiles guarantee that the same `AU_PATCH` value is used in all three modes without repeating it on every command line.

## Profile Format

A profile is a small `KEY=VALUE` text file with the `.profile` suffix. Values are literal - no shell expansion.
The file is parsed with an allow-list, never sourced; an unknown key is fatal.

```ini
# etc/profiles/19.32.profile
AU_PROFILE_DESC="RU 19.32 with OPatch, OJVM, Data Pump bundle and the latest MRP at download time"
AU_PATCH=RU:19.32,OPATCH,OJVM:19.32,DPBP,MRP
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
```

Allowed keys:

- `AU_PROFILE_DESC` - human-readable description (informational only)
- `AU_PATCH` - patch keyword list (same syntax as `AU_PATCH` in `autoupgrade.env`)
- `AU_TARGET_VERSION` - target Oracle major version (`19`, `21`, `23`)
- `AU_PLATFORM` - platform code (`LINUX.X64`, `ARM.X64`, etc.)
- `AU_GOLD_IMAGE` - `YES`, `NO`, `AUTO` or `ALL`
- `AU_EDITION` - optional; `EE` or `SE2`

The same file security checks apply as for env files (owner user or root, not group/world-writable).

## Selecting a Profile

```bash
au_run.sh --profile <name|path> -config etc/au_patch.cfg -patch -mode <mode>
```

A value containing `/` is treated as a file path. A plain name is resolved through the search path.

## Search Path and Shadowing

First match wins:

1. Explicit path (when the value contains `/`)
2. `AU_PROFILE_DIR` (if set)
3. `${ORADBA_CONFIG_DIR}/autoupgrade/profiles` (OraDBA mode only)
4. `${AUTOUPGRADE_BASE}/etc/profiles/` (shipped)

When a profile name matches more than one directory, every shadowed file is reported. A missing profile is an
error that lists every directory searched.

## Shipped Profiles

<!-- markdownlint-disable MD013 MD060 -->
| Profile | `AU_PATCH` value | Purpose |
| --- | --- | --- |
| `recommended` | `RECOMMENDED` | Current Oracle recommendation; the pin file converts this to `RECOMMENDED:<x.y>` after download |
| `19.32` | `RU:19.32,OPATCH,OJVM:19.32,DPBP,MRP` | Pinned release with the latest MRP at download time |
| `cputest-example` | `RU:19.32,OPATCH,OJVM:19.32,DPBP,JDK,MRP` | CPU-test example; monthly patch by keyword, MOS patch number as header record |
| `21c-cspu` | `RU:21.3,OPATCH,CSPU` | 21c with CSPU; replace the RU version before use |
<!-- markdownlint-restore -->

## Keyword Rules

AutoUpgrade 26.x enforces these rules; the profile parser checks them before the run to fail earlier with the
same message key:

- `RU:x.y` and `OJVM:x.y` carry a version. The OJVM version must match the RU version
  (`VCP_INVALID_RU_OJVM_MISMATCH`).
- `MRP`, `DPBP` and `CSPU` take no version (`PATCH_FORMAT_FAIL`). Plain patch numbers (ARU IDs) are accepted.
- `RECOMMENDED` combined with a versioned `RU:x.y` is rejected. Use `RECOMMENDED:<x.y>` or an explicit list.
- `CSPU` is rejected on Linux for 19c and 23ai (`VCP_CSPU_UNSUPPORTED_ON_LINUX`). It is valid for 19c and 23ai
  on non-Linux platforms and for 21c on all platforms.
- On 21c, `MRP`, `OJVM` and `DPBP` are not supported (`VCP_MRP_UNSUPPORTED_ON_21`, `VCP_INVALID_PATCH_APPLY`).
- `MRP` exists for 19c from RU 19.17 and is Linux x86-64 only.

## Per-Profile Download Folder

With a profile, `AU_DOWNLOAD_FOLDER` defaults to `${AUTOUPGRADE_BASE}/patches/<profile-name>`. Without a profile
it stays `patches/`. An explicit `AU_DOWNLOAD_FOLDER` in the caller environment wins.

One folder per profile keeps the `patches_info.json` and pin file with the zips they describe. A versioned
`RU:x.y` picks exactly its version from the folder; `RECOMMENDED` picks the newest RU zip found at create_home
time - which is why the pin file matters.

## Pinning (au_patch_pin.sh)

After a successful `-mode download`, `au_run.sh` automatically calls `au_patch_pin.sh` to write the resolved
patch list to `${AU_DOWNLOAD_FOLDER}/au_patch.env`. The pin file is at level 6 in the precedence chain
(above the profile) so create_home and deploy use the exact same set as the download.

```bash
# Run by hand for a specific folder
bin/au_patch_pin.sh patches/recommended

# Replace MRP by its patch ID if patches_info.json lists one (see below)
bin/au_patch_pin.sh --resolve-mrp patches/recommended

# Skip auto-pinning for this run
bin/au_run.sh --no-pin --profile recommended -config etc/au_patch.cfg -patch -mode download
```

Rules:

- `RECOMMENDED` becomes `RECOMMENDED:<x.y>` (the resolved RU version from patches_info.json).
- An unversioned `RU` becomes `RU:<x.y>,...`; an already-versioned list is left unchanged.
- An existing pin with a different value is not overwritten silently: the conflict is reported as WARN with both
  values. Use `--force` to replace.
- `au_patch_pin.sh --resolve-mrp` replaces `MRP` by a patch ID only if `patches_info.json` lists an MRP entry.
  Downloads measured so far (2026-10-05, also with a gold image) have none: the keyword is kept and a WARN is
  printed. Do not rely on it for reproducibility - see [CPU-Test Workflow](#cpu-test-workflow).

## Verification (au_patch_verify.sh)

`au_patch_verify.sh` checks every file listed in `patches_info.json` by size and SHA-256. It also checks that the
metadata files (`bug-map.json` / `aru-bug-map.json` and `patches_info.json`) exist, because create_home and deploy
fail without them. Files in the folder that are not listed are named in the output.

```bash
bin/au_patch_verify.sh patches/recommended
```

The hashes come from the same `patches_info.json` produced by AutoUpgrade during download. They prove transfer
integrity, not Oracle authenticity.

## CPU-Test Workflow

A CPU-test profile pins the RU and requests the monthly patch by keyword (`MRP` on Linux x86-64, `CSPU`
otherwise). The MOS patch number of the tested month goes into the profile header as a record, not into
`AU_PATCH`: the gold image carries the monthly level, a plain patch number would not be part of it. See the
`cputest-example` profile.

1. Write the profile with `AU_PATCH=RU:<x.y>,...,MRP` and the record line `# Record....: MOS MRP <number>`.
2. Download with `--profile <name>`. AutoUpgrade resolves `MRP` to the latest monthly patch for that RU.
3. Compare the downloaded monthly patch with the record (`patches_info.json`, `au_patch_verify.sh`).
4. Keep the download folder: create_home from it is reproducible, a later re-download may bring a newer level.

The monthly profiles are generated in the private `cpu-patch-tests` repository and consumed through
`AU_PROFILE_DIR`. The profile format belongs to `odb_autoupgrade`; the profile data belongs to the consumer.

## Not Yet Verified

- The field names read from `patches_info.json` (`releaseUpdate`, `patchId`) are tested against fixtures. The MRP
  mapping of `au_patch_pin.sh --resolve-mrp` has no live counterpart: measured downloads list no MRP entry.
- A pinned MRP (plain patch number) is not part of an Oracle gold image; use `AU_GOLD_IMAGE=NO` with such profiles
  until create_home with image plus separate MRP zip is confirmed.
