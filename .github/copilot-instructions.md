# GitHub Copilot Instructions for OraDBA Autoupgrade Extension

## Project Overview

OraDBA Autoupgrade (odb_autoupgrade) is an OraDBA extension for Oracle AutoUpgrade. It provides wrapper scripts for downloading, updating, and running Oracle AutoUpgrade, along with ready-to-use configuration templates. The extension manages AutoUpgrade JAR files, patches, and MOS (My Oracle Support) credentials for automated Oracle database upgrades.

## Code Quality Standards

### Shell Scripting

- **Always use**: `#!/usr/bin/env bash` (never `#!/bin/sh`)
- **Strict error handling**: Use `set -euo pipefail` for critical scripts
- **ShellCheck compliance**: All scripts must pass shellcheck without warnings
- **Quote variables**: Always quote variables: `"${variable}"` not `$variable`
- **Constants**: Use `readonly` for constants (uppercase names)
- **Variables**: Use lowercase for variables

### Naming Conventions

- **Scripts**: `lowercase_with_underscores.sh`
- **Config files**: `lowercase_with_underscores.cfg`
- **Tests**: `test_feature.bats`
- **Documentation**: `lowercase-with-hyphens.md`

## Project Structure

```
odb_autoupgrade/
├── .extension           # Extension metadata (name, version, priority)
├── .checksumignore     # Files excluded from integrity checks
├── VERSION             # Semantic version
├── bin/                # Wrapper scripts (run/update autoupgrade, keystore)
│   ├── run_autoupgrade.sh      # Main wrapper for AutoUpgrade
│   ├── update_autoupgrade.sh   # Download/update AutoUpgrade JAR
│   └── create_mos_keystore.sh  # MOS credential management
├── etc/                # AutoUpgrade config templates
│   ├── download_patch.cfg      # Patch download config
│   └── download_RU*.cfg        # Release Update configs
├── lib/                # Shared library functions
├── jar/                # AutoUpgrade JAR storage (not packaged)
├── patches/            # Patch bundles storage (not packaged)
├── doc/                # Documentation
├── scripts/            # Build and development tools
└── tests/              # BATS test files

```

## Extension Metadata (.extension)

```ini
name: odb_autoupgrade
version: 0.3.1
description: OraDBA autoupgrade extension
author: Stefan Oehrli
enabled: true
priority: 50
provides:
  bin: true
  sql: true
  rcv: true
  etc: true
```

## Key Features

### AutoUpgrade Wrapper (run_autoupgrade.sh)

- Resolves config files relative to CWD or `etc/` directory
- Expands environment variables in configs using `envsubst`
- Sets `AUTOUPGRADE_BASE` for AutoUpgrade runtime
- Supports all AutoUpgrade modes (analyze, deploy, download)
- Handles AutoUpgrade JAR location automatically

### JAR Update (update_autoupgrade.sh)

- Downloads latest AutoUpgrade JAR from Oracle
- Stores JAR in `jar/` directory
- Validates JAR integrity
- Supports specific version downloads
- Manages JAR versioning

### MOS Keystore (create_mos_keystore.sh)

- Creates secure keystore for MOS credentials
- Stores username and password encrypted
- Used by AutoUpgrade for patch downloads
- Follows Oracle security best practices

## Development Workflow

### Making Changes

1. **Test locally**: Run `make test` before committing
2. **Lint code**: Run `make lint` (shellcheck + markdownlint)
3. **Update configs**: Keep config templates in `etc/` current
4. **Update docs**: Document configuration changes
5. **Update CHANGELOG**: Document all changes

### Testing

- **Run all tests**: `make test` or `bats tests/`
- **Test wrapper**: Test with various AutoUpgrade configs
- **Test JAR download**: Verify update_autoupgrade.sh functionality
- **Test keystore**: Verify credential encryption works

### Building

- **Build package**: `make build` creates tarball in `dist/`
- **Output**: `dist/odb_autoupgrade-<version>.tar.gz` + `.sha256` checksum
- **Included**: `.extension`, `VERSION`, docs, `bin/`, `etc/`, `lib/`
- **Excluded**: `jar/`, `patches/`, `log/`, dev tools

## Common Patterns

### Script Template with AutoUpgrade Support

```bash
#!/usr/bin/env bash
#
# Script Name: my_autoupgrade_tool.sh
# Description: AutoUpgrade helper script
# Author: Stefan Oehrli
# Version: 1.0.0
#

set -euo pipefail

readonly SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${0}")" && pwd)"
readonly AUTOUPGRADE_BASE="${AUTOUPGRADE_BASE:-${SCRIPT_DIR}/..}"

show_usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Options:
    -h, --help          Show this help
    -c, --config FILE   AutoUpgrade config file
    -m, --mode MODE     AutoUpgrade mode (analyze|deploy|download)
EOF
}

# Check AutoUpgrade JAR
check_autoupgrade_jar() {
    local jar_file="${AUTOUPGRADE_BASE}/jar/autoupgrade.jar"
    if [[ ! -f "${jar_file}" ]]; then
        echo "Error: AutoUpgrade JAR not found at ${jar_file}" >&2
        echo "Run: update_autoupgrade.sh to download it" >&2
        return 1
    fi
}

main() {
    check_autoupgrade_jar
    
    # Main logic here
    echo "AutoUpgrade tool running"
}

# Parse arguments and run
main "$@"
```

### AutoUpgrade Config Template

```properties
# ============================================================================
# AutoUpgrade Configuration
# Description: Configuration for database upgrade
# ============================================================================

global.autoupg_log_dir=/u01/app/oracle/autoupgrade/logs

# Source database
upg1.source_home=${ORACLE_HOME_19c}
upg1.target_home=${ORACLE_HOME_21c}
upg1.sid=ORCL
upg1.log_dir=/u01/app/oracle/autoupgrade/logs/ORCL
upg1.upgrade_node=localhost
upg1.target_version=21.3
```

### Handling MOS Credentials

```bash
# Create keystore
create_mos_keystore.sh

# Use in AutoUpgrade config
upg1.mos_user=username@example.com
upg1.mos_pass_file=${AUTOUPGRADE_BASE}/keystore/mos.keystore
```

## Integrity Checking

The `.checksumignore` file excludes dynamic content:

```text
# Extension metadata
.extension
.checksumignore

# Runtime artifacts (not packaged)
jar/
patches/
log/

# Credentials
keystore/
*.key
*.pem

# Temporary files
*.tmp
*.log
```

## Configuration Files

### Config File Location

AutoUpgrade configs can be:
1. Absolute path: `/path/to/config.cfg`
2. Relative to CWD: `./config.cfg`
3. Relative to `etc/`: Resolved automatically by wrapper

### Environment Variable Expansion

Configs support environment variables:

```properties
# Before expansion
upg1.source_home=${ORACLE_HOME_19c}
upg1.target_home=${ORACLE_HOME_21c}

# After expansion (via envsubst)
upg1.source_home=/u01/app/oracle/product/19.0.0/dbhome_1
upg1.target_home=/u01/app/oracle/product/21.0.0/dbhome_1
```

## Integration with OraDBA

### Environment Variables

The extension uses:
- `${ORADBA_BASE}`: OraDBA installation directory
- `${ORACLE_HOME}`: Current Oracle Home (for source/target)
- `${AUTOUPGRADE_BASE}`: AutoUpgrade extension base directory

### Auto-Discovery

When installed in `${ORADBA_LOCAL_BASE}`, OraDBA auto-discovers:
- `bin/*.sh` scripts added to PATH
- Extension loaded with priority 50

## Release Process

1. **Update VERSION**: Bump version (e.g., 0.3.1 → 0.3.2)
2. **Update CHANGELOG.md**: Document changes
3. **Update .extension**: Ensure version matches VERSION file
4. **Test**: Run `make test` and `make lint`
5. **Build**: Run `make build` to verify
6. **Commit**: `git commit -m "chore: Release vX.Y.Z"`
7. **Tag**: `git tag -a vX.Y.Z -m "Release vX.Y.Z"`
8. **Push**: `git push origin main --tags`

## When Generating Code

- Follow AutoUpgrade best practices and patterns
- Use wrapper scripts for AutoUpgrade operations
- Support environment variable expansion in configs
- Handle missing JAR gracefully (suggest update_autoupgrade.sh)
- Validate config files before running AutoUpgrade
- Add appropriate error handling
- Update documentation
- **Always ask clarifying questions** when requirements are unclear
- **Avoid hardcoded paths** - Use `${AUTOUPGRADE_BASE}` variable

## Best Practices

### Error Handling

```bash
# Check JAR exists
if [[ ! -f "${AUTOUPGRADE_BASE}/jar/autoupgrade.jar" ]]; then
    echo "Error: AutoUpgrade JAR not found" >&2
    echo "Run: update_autoupgrade.sh" >&2
    exit 1
fi

# Validate config file
if [[ ! -f "${config_file}" ]]; then
    echo "Error: Config file not found: ${config_file}" >&2
    exit 1
fi

# Check Oracle environment
if [[ -z "${ORACLE_HOME:-}" ]]; then
    echo "Error: ORACLE_HOME not set" >&2
    exit 1
fi
```

### Logging

```bash
# Consistent logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >&2
}

log "Starting AutoUpgrade operation"
log "Config file: ${config_file}"
log "Mode: ${mode}"
```

### Config File Handling

```bash
# Resolve config path
resolve_config() {
    local config="$1"
    
    # Absolute path
    if [[ "${config}" = /* ]]; then
        echo "${config}"
        return 0
    fi
    
    # Relative to CWD
    if [[ -f "${config}" ]]; then
        echo "${PWD}/${config}"
        return 0
    fi
    
    # Relative to etc/
    if [[ -f "${AUTOUPGRADE_BASE}/etc/${config}" ]]; then
        echo "${AUTOUPGRADE_BASE}/etc/${config}"
        return 0
    fi
    
    echo "Error: Config not found: ${config}" >&2
    return 1
}
```

## Security Considerations

- Never hardcode MOS credentials in scripts or configs
- Use keystore for credential storage
- Protect keystore with appropriate file permissions (600)
- Log credential operations without exposing values
- Validate file permissions before operations
- Use secure temporary file handling

## Debugging

```bash
# Enable debug mode
set -x

# Debug AutoUpgrade wrapper
AUTOUPGRADE_BASE=/path/to/extension bash -x bin/run_autoupgrade.sh -config myconfig.cfg

# Check environment
echo "AUTOUPGRADE_BASE: ${AUTOUPGRADE_BASE}"
echo "ORACLE_HOME: ${ORACLE_HOME}"
ls -l "${AUTOUPGRADE_BASE}/jar/"
```

## Resources

- [Oracle AutoUpgrade Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/21/upgrd/using-autoupgrade-oracle-database-upgrades.html)
- [OraDBA Extension Documentation](doc/)
- [Bash Best Practices](https://bertvv.github.io/cheat-sheets/Bash.html)
- [ShellCheck](https://www.shellcheck.net/)
