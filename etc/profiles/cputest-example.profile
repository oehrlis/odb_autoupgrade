# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Profile...: cputest-example
# Purpose...: CPU-test example: pinned RU, monthly patch by keyword, MOS patch
#             number as header record.
# Record....: MOS MRP <patch number> (replace with the number of the tested
#             month; record only, not a download item)
# Notes.....: AutoUpgrade resolves the MRP keyword to the latest monthly patch
#             for RU 19.32 at download time. A later re-download yields a
#             newer level than the record names - keep the download folder
#             (and its au_patch.env) for a reproducible create_home.
#             patches_info.json of measured downloads carries no MRP patch ID,
#             so au_patch_pin.sh --resolve-mrp keeps the keyword (WARN).
#             The gold image carries the monthly level (measured for 19c,
#             2026-10-05); a plain patch number would not be part of it.
#             Monthly profiles are maintained in the private cpu-patch-tests
#             repository, consumed via AU_PROFILE_DIR.
# Reference.: doc/patch-profiles.md - CPU-Test Workflow
# License...: Apache License Version 2.0
# ------------------------------------------------------------------------------
AU_PROFILE_DESC="CPU test example: RU 19.32, OPatch, OJVM, DPBP, JDK, MRP keyword (MOS number in header)"
AU_PATCH=RU:19.32,OPATCH,OJVM:19.32,DPBP,JDK,MRP
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=YES
