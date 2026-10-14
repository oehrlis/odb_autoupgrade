#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    VERSION="$(cat "${REPO_ROOT}/VERSION")"
}

@test "build script creates tarball and checksum" {
    dist="${BATS_TMPDIR}/dist"
    run bash -c "cd \"$REPO_ROOT\" && ./scripts/build.sh --dist \"$dist\""
    [ "$status" -eq 0 ]

    tarball="${dist}/odb_autoupgrade-${VERSION}.tar.gz"
    checksum="${tarball}.sha256"
    [ -f "$tarball" ]
    [ -f "$checksum" ]
}

@test "build tarball ships doc/ and the jar/patches READMEs" {
    dist="${BATS_TMPDIR}/dist_content_$$"
    run bash -c "cd \"$REPO_ROOT\" && ./scripts/build.sh --dist \"$dist\""
    [ "$status" -eq 0 ]
    tarball="${dist}/odb_autoupgrade-${VERSION}.tar.gz"
    run tar -tzf "$tarball"
    [ "$status" -eq 0 ]
    local f
    # every tracked doc file plus the jar/ and patches/ READMEs
    while IFS= read -r f; do
        [[ "$output" == *"$f"* ]] || { echo "missing in tarball: $f"; return 1; }
    done < <(cd "$REPO_ROOT" && git ls-files doc jar/README.md patches/README.md)
    rm -rf "$dist"
}

@test "rename script supports dry run" {
    run bash -c "cd \"$REPO_ROOT\" && ./scripts/rename-extension.sh --name demo --dry-run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo"* ]]
}
