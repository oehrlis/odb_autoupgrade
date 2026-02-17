#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Name.......: aliases.sh
# Author.....: Stefan Oehrli (oes) stefan.oehrli@oradba.ch
# Date.......: 2026.02.17
# Revision...: 0.4.0
# Purpose....: Optional odb_autoupgrade alias hook
# Notes......: This file is sourced by OraDBA only when BOTH conditions are met:
#              - ORADBA_EXTENSIONS_SOURCE_ETC=true
#              - .extension contains: load_aliases: true
#              Default for odb_autoupgrade is load_aliases: false.
# ------------------------------------------------------------------------------

alias autoupgrade='cd "${ODB_AUTOUPGRADE_BASE:-${ORADBA_LOCAL_BASE}/odb_autoupgrade}"'
alias au='run_autoupgrade.sh'
