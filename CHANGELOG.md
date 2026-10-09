# Changelog

## Unreleased

### Added

- `doc/design.md` - Phase 2 design: inventory legacy vs target, target architecture, configuration precedence,
  gold image paths, patch profiles, one template `au_patch.cfg` for all modes, edition and OS groups,
  cross-repository ownership, field findings mapping, work packages and decisions

## 0.5.0 - 2026-10-08

### Added

- **Proxy and truststore handling** in `bin/au_run.sh` (fixes PKIX
  `unable to find valid certification path` behind proxies with TLS inspection)
  - Proxy from `AUTOUPGRADE_PROXY` > `https_proxy` > `HTTPS_PROXY` > `http_proxy` > `HTTP_PROXY`,
    `none` disables; credentials in the URL are stripped with a warning
  - Exports a sanitized lowercase `https_proxy` (the only proxy variable AutoUpgrade reads) and passes
    `-Dhttps.proxyHost/Port`, `-Dhttp.proxyHost/Port`, `-Dhttp.nonProxyHosts` (from `no_proxy`)
  - OS truststore (`/etc/pki/ca-trust/extracted/java/cacerts`, `/etc/ssl/certs/java/cacerts`) instead of
    the Oracle Home JDK cacerts; override with `AUTOUPGRADE_TRUSTSTORE` (`none` = JDK default)
  - `AUTOUPGRADE_JAVA_HOME`, `AUTOUPGRADE_JAVA_OPTS`, `AUTOUPGRADE_JAVA_SUPPORTED`,
    `AUTOUPGRADE_DEBUG_SSL`, `AUTOUPGRADE_DRY_RUN`; JVM options on the command line, not `JAVA_TOOL_OPTIONS`
- `lib/au_lib.sh` - shared Java, proxy, truststore, env file and config checks
- `etc/autoupgrade.env.example` - optional site settings and template variables
- Generic templates `etc/au_download.cfg`, `etc/au_create_home.cfg`, `etc/au_deploy.cfg` - no file per RU;
  one patch list `AU_PATCH` (default `RECOMMENDED`, pinned via `patches/au_patch.env`), gold image via
  `AU_GOLD_IMAGE=YES`, create_home and deploy without keystore
- `bin/au_check_connectivity.sh` - pre-flight check of endpoints, TLS issuer, keystore and JAR version
- `doc/proxy-and-truststore.md` - symptom, cause, configuration, required network endpoints
- BATS tests for the wrapper, the library and the connectivity check

### Changed

- Scripts renamed to the `au_` prefix: `au_run.sh`, `au_update_jar.sh`, `au_keystore.sh`; the old names
  remain as deprecation shims until 1.0
- `au_keystore.sh` runs AutoUpgrade through `au_run.sh` (proxy, truststore) and answers the 26.x auto-login
  prompt (`--auto-login YES|SHARED|NO`)
- `etc/autoupgrade.env` no longer overrides variables set by the caller
- Java version check is configurable; Oracle Home JDK is preferred over `PATH`
- Config files abort with a list of unset variables instead of expanding them to empty strings
- `.gitignore` and `.checksumignore` exclude keystore, JAR, patches, logs and `etc/autoupgrade.env`

### Security

- `etc/autoupgrade.env` is refused unless owned by the current user and not group/world writable; caller
  variables are restored without `eval`
- `patches/au_patch.env` is parsed (only `AU_PATCH=`), never sourced, with ownership and permission checks
- `envsubst` expands only the variables referenced in the config; values with newlines are rejected
- Proxy URL parsing strips credentials reliably (also with `/` in the password) and validates host and port
- `-Djavax.net.ssl.trustStorePassword` is passed only when `AUTOUPGRADE_TRUSTSTORE_PASS` is set
- `au_keystore.sh`: passwords on the command line require `--insecure-argv`; passwords are not inherited
  by AutoUpgrade; `umask 077`, keystore directory `0700`, symlinks refused, WARN for `--auto-login SHARED`
- `au_check_connectivity.sh`: curl verifies against the same truststore as Java; truststore errors are FAIL;
  issuer check matches the CA organisation exactly across all redirect hops
- `au_update_jar.sh`: HTTPS-only download, zip and size check, SHA-256 printed

### Fixed

- AutoUpgrade exit code is propagated by the wrapper
- Wrapper aborts when the `-config` file is not found
- Temporary config is removed reliably (portable `mktemp`, `trap`)

## 0.4.0 - 2026-02-17

### Added

- **Optional extension etc hook scaffolding**
  - Added explicit `.extension` metadata flags:
    - `load_env: false`
    - `load_aliases: false`
  - Added `etc/env.sh` as optional environment hook
  - Added `etc/aliases.sh` as optional aliases hook
  - Hook support is disabled by default and can be enabled explicitly per extension

### Documentation

- Added release notes for v0.4.0: `doc/release_notes/v0.4.0.md`
- Updated README and documentation index with env/alias hook usage details

## 0.3.1 - 2026-01-13

### Added

- **Release Notes Documentation** - Comprehensive release notes for version 0.3.1
  - Added `doc/release_notes/v0.3.1.md` - Enhanced release workflow
  - Detailed documentation of workflow improvements and features
  - Professional format with usage examples and best practices
  - Existing `doc/release_notes/v0.3.0.md` retained

### Changed

- **Release Workflow Enhancement** - Smart release notes generation
  - Updated `.github/workflows/release.yml` to check for version-specific release notes
  - Workflow now uses detailed release notes from `doc/release_notes/v{VERSION}.md` if available
  - Falls back to comprehensive generic notes with proper odb_autoupgrade branding
  - Improved documentation links specific to autoupgrade operations
  - Better user experience with professional release documentation
  - Generic fallback includes installation and usage instructions

## 0.3.0 - 2026-01-12

### Changed

- **Development Workflow Enhancement**: Synchronized with oradba_extension template v0.3.0
  - Comprehensive Makefile with color-coded output and extensive help system
  - Added categorized help with Development, Build, Version, CI/CD, and Tools sections
  - New targets: `format`, `format-check`, `check`, `ci`, `pre-commit`, `tools`, `info`, `status`
  - Version management targets: `version-bump-patch`, `version-bump-minor`, `version-bump-major`, `tag`
  - Quick shortcuts: `t` (test), `l` (lint), `f` (format), `b` (build), `c` (clean)
  - Improved error messages and tool installation guidance
  - Better formatting with consistent indentation and structure

- **CI/CD Improvements**:
  - Updated GitHub Actions workflows to use Makefile targets
  - CI workflow now uses `make lint-shell` and `make lint-markdown` for consistency
  - Release workflow simplified to use `make ci` for all checks and build
  - Centralized CI logic in Makefile for better maintainability

- **Documentation**:
  - Enhanced README.md Integrity Checking section with more details
  - Added "Common use cases" description for `.checksumignore` patterns
  - Added clarification about OraDBA integrity verification process
  - Better formatting consistency throughout documentation

### Added

- **Development Tools**:
  - `make tools` - Display status of all development tools (shellcheck, shfmt, markdownlint, bats, git)
  - `make info` - Show comprehensive project information and file counts
  - `make status` - Display git status and current version
  - `make clean-all` - Deep clean including caches and temporary files

- **Pre-commit Support**: New `make pre-commit` target for running format, lint, and test before commits

## 0.2.0 - 2026-01-07

### Added

- **Checksum Exclusion Support**: Added `.checksumignore` file for customizable
  integrity checks
  - Define patterns for files to exclude from checksum verification
  - Supports glob patterns: `*`, `?`, directory matching (`pattern/`)
  - Default exclusions: `.extension`, `.checksumignore`, `log/`
  - Per-extension configuration in template
  - Common use cases: credentials, caches, temporary files, user-specific configs
  - Included in build tarball for distribution

- **Enhanced SQL Script Examples**: Added comprehensive SQL script templates
  - `sql/extension_simple.sql` - Basic query example with standard formatting
  - `sql/extension_comprehensive.sql` - Production-ready script with:
    - Automatic log directory detection from ORADBA_LOG environment variable
    - Dynamic spool file naming with timestamp and database SID
    - Multiple report sections with proper headers
    - Tablespace usage, session info, top objects, and SQL activity
    - Error handling with WHENEVER OSERROR
    - Integration with OraDBA logging infrastructure
  - Updated `sql/extension_query.sql` with proper header and formatting

- **Enhanced RMAN Script Template**: Comprehensive `rcv/extension_backup.rcv` example
  - Documents all 17+ template tags supported by oradba_rman.sh
  - Full backup workflow: database, archivelogs, controlfile, SPFILE
  - Variable substitution examples: `<BCK_PATH>`, `<START_DATE>`, `<ORACLE_SID>`
  - Safety features: DELETE/CROSSCHECK commands commented out
  - Usage examples with multiple invocation patterns
  - Serves as reference guide for extension developers

### Changed

- **Build Process**: Updated `scripts/build.sh` to include `.checksumignore` in CONTENT_PATHS
- **Documentation**: Enhanced README.md with "Integrity Checking" section
  - Pattern syntax and examples
  - Default exclusions documented
  - Common use case patterns provided

## 0.1.1 - 2026-01-07

- Add .extension.checksum generation to build artifacts
- Fix release workflow heredoc formatting
- Add Makefile help target and ensure dist auto-created

## 0.1.0 - 2026-01-07

- Initial template for OraDBA extensions with sample structure, packaging script, rename helper, and CI workflows.
- Release workflow fixed (heredoc), build script lint fixes, dist auto-creation, BATS passing, Makefile help target added.
