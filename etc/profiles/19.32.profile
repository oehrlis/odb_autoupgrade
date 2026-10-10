# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Profile...: 19.32
# Purpose...: Pinned release: RU 19.32 with OPatch, OJVM, Data Pump bundle
#             patch, and the latest MRP available at download time.
#             The OJVM version must match the RU version.
# Notes.....: MRP resolves to the latest monthly patch at download time.
#             Use cputest-example.profile to pin a specific MRP patch number
#             for CPU test reproducibility.
#             AU_GOLD_IMAGE=NO: downloads zips.
# Reference.: doc/design.md - Patch profiles
# License...: Apache License Version 2.0
# ------------------------------------------------------------------------------
AU_PROFILE_DESC="RU 19.32 with OPatch, OJVM, Data Pump bundle and the latest MRP at download time"
AU_PATCH=RU:19.32,OPATCH,OJVM:19.32,DPBP,MRP
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
