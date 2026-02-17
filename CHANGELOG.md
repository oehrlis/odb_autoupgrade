# Changelog

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
