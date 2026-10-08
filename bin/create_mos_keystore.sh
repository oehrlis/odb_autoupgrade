#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: create_mos_keystore.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Editor.....: Stefan Oehrli
# Date.......: 2026.10.08
# Version....: v0.5.0
# Purpose....: Deprecated shim - delegates all invocations to au_keystore.sh.
# Notes......: This shim will be removed in version 1.0. Update any scripts,
#              aliases, or documentation to use au_keystore.sh instead.
# Reference..: https://github.com/oehrlis/odb_autoupgrade
# License....: Apache License Version 2.0
# ------------------------------------------------------------------------------
# Modified...:
# 2026.10.08 oehrli - shim for create_mos_keystore.sh -> au_keystore.sh rename
# ------------------------------------------------------------------------------
set -euo pipefail
SCRIPT_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
echo "WARN: create_mos_keystore.sh is deprecated, use au_keystore.sh (shim removed in 1.0)" >&2
exec "${SCRIPT_BIN_DIR}/au_keystore.sh" "$@"
