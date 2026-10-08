#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: update_autoupgrade.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.08
# Version....: v0.5.0
# Purpose....: Deprecated shim - delegates all invocations to au_update_jar.sh.
# Notes......: This shim will be removed in version 1.0. Update any scripts,
#              aliases, or documentation to use au_update_jar.sh instead.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.08 oehrli - shim for update_autoupgrade.sh -> au_update_jar.sh rename
# ------------------------------------------------------------------------------
set -euo pipefail
SCRIPT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
echo "WARN: update_autoupgrade.sh is deprecated, use au_update_jar.sh (shim removed in 1.0)" >&2
exec "${SCRIPT_BIN_DIR}/au_update_jar.sh" "$@"
