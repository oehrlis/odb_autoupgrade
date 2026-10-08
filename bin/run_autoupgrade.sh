#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: run_autoupgrade.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.08
# Version....: v0.5.0
# Purpose....: Deprecated shim - delegates all invocations to au_run.sh.
# Notes......: This shim will be removed in version 1.0. Update any scripts,
#              aliases, or documentation to use au_run.sh instead.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.08 oehrli - shim for run_autoupgrade.sh -> au_run.sh rename
# ------------------------------------------------------------------------------
set -euo pipefail
SCRIPT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
echo "WARN: run_autoupgrade.sh is deprecated, use au_run.sh (shim removed in 1.0)" >&2
exec "${SCRIPT_BIN_DIR}/au_run.sh" "$@"
