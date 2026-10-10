# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Profile...: recommended
# Purpose...: Current Oracle recommendation: latest available RU with OPatch,
#             OJVM, Data Pump bundle patch, and the latest Monthly Recommended
#             Patch. The pin file (au_patch.env) is written after download to
#             lock the resolved RU version for create_home and deploy.
# Notes.....: After download, au_patch_pin.sh converts RECOMMENDED to
#             RECOMMENDED:<x.y> in the pin file.
#             AU_GOLD_IMAGE=NO: downloads zips; set to YES for OL 9 builds that
#             require an Oracle gold image.
# Reference.: doc/design.md - Patch profiles
# License...: Apache License Version 2.0
# ------------------------------------------------------------------------------
AU_PROFILE_DESC="Current Oracle recommendation (RECOMMENDED) with OPatch, OJVM, DPBP and MRP"
AU_PATCH=RECOMMENDED
AU_TARGET_VERSION=19
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
