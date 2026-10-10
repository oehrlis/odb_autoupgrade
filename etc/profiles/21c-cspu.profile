# ------------------------------------------------------------------------------
# OraDBA - Oracle Database Infrastructure and Security, 5630 Muri, Switzerland
# ------------------------------------------------------------------------------
# Profile...: 21c-cspu
# Purpose...: 21c with Cumulative Security Patch Update (CSPU).
#             CSPU is the correct patch type for 21c on all platforms.
#             MRP, OJVM and DPBP are not supported on 21c.
# Notes.....: Replace 21.<n> with the desired RU (e.g. RU:21.3, RU:21.14).
#             CSPU is valid on Linux for 21c (VCP_CSPU_UNSUPPORTED_ON_LINUX
#             only applies to 19c and 23ai on Linux).
#             Validated with RU:21.3,OPATCH,CSPU against AutoUpgrade 26.6
#             config validation (AU facts 13 Q2).
# Reference.: doc/design.md - Patch profiles
# License...: Apache License Version 2.0
# ------------------------------------------------------------------------------
AU_PROFILE_DESC="21c with CSPU - replace RU version before use"
AU_PATCH=RU:21.3,OPATCH,CSPU
AU_TARGET_VERSION=21
AU_PLATFORM=LINUX.X64
AU_GOLD_IMAGE=NO
