#!/bin/sh
# verify-engine.sh <engine package folder> [max glibc]   (default 2.28)
#
# Checks that an engine package produced by build-cuda-el8-aarch64.yml will
# start on a stock EL8 / UOS V20 1070 aarch64 box that has ONLY the NVIDIA
# driver installed (no CUDA Toolkit, no newer C++ runtime):
#
#   * every ELF stays within the glibc baseline and never uses GLIBC_PRIVATE
#   * every DT_NEEDED soname is either in the package, an OS library, or a
#     library the GPU driver owns (libcuda.so.1)
#   * the driver's own libraries are NOT bundled (pinning them would tie the
#     package to one driver version)
#   * the CUDA and C++ runtimes it needs really are in the package
#   * the engine's rpath is $ORIGIN, so it resolves those copies first
#   * the bundled libstdc++ / libgomp provide every symbol version the engine asks for
#
# Needs binutils (readelf/objdump), coreutils (od/head) and ldd. Run it in CI
# and again on the target box after unpacking.
set -eu

pkg=${1:?usage: verify-engine.sh <engine package folder> [max glibc]}
glibc_max=${2:-2.28}

for tool in readelf objdump strings od ldd; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "verify-engine: '$tool' is missing (install binutils + coreutils)" >&2
        exit 2
    }
done

[ -f "$pkg/strata" ] || { echo "verify-engine: $pkg/strata not found" >&2; exit 2; }

fail=0
err() { echo "error: $*" >&2; fail=1; }

# ELF magic. Text files (DEPLOY.txt, BUILD.json, the .sh scripts) are skipped.
elfs=""
for f in "$pkg"/*; do
    [ -f "$f" ] || continue
    [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || continue
    elfs="$elfs $f"
done
[ -n "$elfs" ] || { echo "verify-engine: no ELF files in $pkg" >&2; exit 2; }

echo "== glibc baseline (<= $glibc_max) =="
for f in $elfs; do
    dynsyms=$(objdump -T "$f" 2>/dev/null || true)
    if echo "$dynsyms" | grep -q GLIBC_PRIVATE; then
        err "$f references GLIBC_PRIVATE (an internal glibc symbol, cannot be shipped)"
    fi
    vers=$(echo "$dynsyms" | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV || true)
    if [ -n "$vers" ]; then
        top=$(printf '%s\nGLIBC_%s\n' "$vers" "$glibc_max" | sort -V | tail -1)
        echo "  ${f##*/}: highest $(echo "$vers" | tail -1)"
        if [ "$top" != "GLIBC_$glibc_max" ]; then
            err "$f needs $(echo "$vers" | tail -1), above glibc $glibc_max"
        fi
    fi
done

echo "== DT_NEEDED =="
for f in $elfs; do
    needed=$(readelf -d "$f" 2>/dev/null | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p' || true)
    for lib in $needed; do
        if [ -e "$pkg/$lib" ]; then
            echo "  ${f##*/}: $lib <- package"
            continue
        fi
        case "$lib" in
            # Supplied by the base OS. glibc 2.28 keeps libpthread / libdl as
            # separate sonames; both are listed here.
            linux-vdso.so.*|ld-linux*.so.*|libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libutil.so.*|libresolv.so.*|libnss_*.so.*|libgcc_s.so.*|libstdc++.so.*|libgomp.so.*|libatomic.so.*|libz.so.*|libnuma.so.*|libelf.so.*|libcrypt.so.*|libffi.so.*|libudev.so.*)
                echo "  ${f##*/}: $lib <- OS" ;;
            # The only GPU libraries the host has to provide. libcuda.so.1 is
            # the CUDA driver API from the .run installer.
            libcuda.so.*|libnvidia-*.so*|libnvcuvid.so*|libnvidia-ml.so*)
                echo "  ${f##*/}: $lib <- host NVIDIA driver" ;;
            *) err "$f needs $lib, which is neither in the package, the OS, nor the driver" ;;
        esac
    done
done

echo "== ldd (driver libraries may legitimately be absent on the build host) =="
missing=$(ldd "$pkg/strata" 2>/dev/null | sed -n 's/^[[:space:]]*\([^ ]*\) => not found/\1/p' || true)
for lib in $missing; do
    case "$lib" in
        libcuda.so.*|libnvidia-*.so*) echo "  $lib: not on this build host, comes from the driver on the target" ;;
        *) err "$pkg/strata: ldd cannot resolve $lib" ;;
    esac
done

echo "== driver-only rule =="
for f in "$pkg"/*; do
    case "${f##*/}" in
        libcuda.so*|libnvidia-*.so*) err "${f##*/} is bundled; it belongs to the host driver and must be removed" ;;
    esac
done

echo "== runtimes that must travel with the engine =="
for pattern in libcublas.so libcublasLt.so libstdc++.so.6 libgomp.so.1; do
    found=0
    for f in "$pkg"/*; do
        case "${f##*/}" in "$pattern"*) found=1 ;; esac
    done
    if [ "$found" = 1 ]; then echo "  $pattern: present"; else err "$pattern* is missing from the package"; fi
done
[ -f "$pkg/SYSTEM-LIBS.txt" ] || err "SYSTEM-LIBS.txt is missing"
[ -f "$pkg/BUILD.json" ] || err "BUILD.json is missing"
[ -f "$pkg/engine-component.json" ] || err "engine-component.json is missing"

echo '== $ORIGIN rpath on the programs =='
for f in "$pkg"/strata "$pkg"/strata-dsv41 "$pkg"/libstrata_kq.so "$pkg"/strata-vision; do
    [ -f "$f" ] || continue
    if readelf -d "$f" | grep -E 'RPATH|RUNPATH' | grep -qF '$ORIGIN'; then
        echo "  ${f##*/}: \$ORIGIN"
    else
        err "${f##*/} has no \$ORIGIN rpath; it would load the host's libraries instead of this package's"
    fi
done

echo "== C++ / OpenMP symbol versions: needed vs bundled =="
need=$(strings -a $elfs | grep -oE 'GLIBCXX_[0-9.]+|CXXABI_[0-9.]+|GOMP_[0-9.]+' | sort -uV || true)
have=$(strings -a "$pkg"/libstdc++.so.6* "$pkg"/libgomp.so.1* 2>/dev/null | grep -oE 'GLIBCXX_[0-9.]+|CXXABI_[0-9.]+|GOMP_[0-9.]+' | sort -uV || true)
for sym in GLIBCXX_ CXXABI_ GOMP_; do
    n=$(echo "$need" | grep -oE "${sym}[0-9.]+" | sort -uV | tail -1 || true)
    h=$(echo "$have" | grep -oE "${sym}[0-9.]+" | sort -uV | tail -1 || true)
    echo "  ${sym} need='${n:-none}' bundled='${h:-none}'"
    if [ -n "$n" ] && [ -n "$h" ] && [ "$(printf '%s\n%s\n' "$n" "$h" | sort -V | tail -1)" != "$h" ]; then
        err "the bundled runtime only provides $h but the engine needs $n"
    fi
    if [ -n "$n" ] && [ -z "$h" ]; then
        err "the engine needs $n but the bundled runtime provides no ${sym} symbols"
    fi
done

if [ "$fail" = 0 ]; then
    echo "OK: $pkg runs on glibc <= $glibc_max with only the NVIDIA driver installed."
else
    echo "FAILED: $pkg is not safe for the target host." >&2
fi
exit "$fail"
