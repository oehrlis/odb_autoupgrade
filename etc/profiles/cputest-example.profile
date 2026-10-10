# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Profile...: cputest-example
# Purpose...: CPU-test example with a pinned MRP patch number for
#             reproducibility. Replace the placeholder MRP number with the
#             actual ARU patch ID before use.
# Notes.....: The MRP patch number shown (99999999) is an invalid placeholder - a download
#             with it fails instead of fetching a wrong patch.
#             Run: au_patch_pin.sh --resolve-mrp <folder>
#             after a download with the recommended profile to obtain the
#             resolved MRP patchId for the target quarter.
#             Monthly profiles with real MRP numbers are maintained in the
#             private cpu-patch-tests repository, consumed via AU_PROFILE_DIR.
#             Plain patch numbers are not part of Oracle gold images (AU facts
#             13 Q3); set AU_GOLD_IMAGE=NO when using a pinned MRP.
# Reference.: doc/design.md - Patch profiles, Automatic AU_PATCH pinning
# License...: Apache License Version 2.0
# ------------------------------------------------------------------------------
AU_PROFILE_DESC="CPU test example: RU 19.32, OPatch, OJVM, DPBP, pinned MRP (replace placeholder)"
# Replace 99999999 with the actual ARU patch ID from au_patch_pin.sh --resolve-mrp
AU_PATCH=RU:19.32,OPATCH,OJVM:19.32,DPBP,99999999
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
