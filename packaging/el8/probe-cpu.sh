#!/bin/sh
# probe-cpu.sh - run this ON THE TARGET BOX before rebuilding the engine.
#
# Strata's portable aarch64 build compiles ggml-cpu with one -march
# (STRATA_ARM64_ARCH). build-cuda-el8-aarch64.yml defaults to
# armv8.2-a+dotprod+fp16, the highest the EL8 target box (Phytium S5000C)
# reports: dotprod and FP16 are in its Features, i8mm and sve are not. i8mm
# (Armv8.6) and sve are optional, so a value is only safe once this script says
# the host has it - building with an extension the CPU lacks gives an immediate
# SIGILL. Use armv8-a for a box without dotprod. This script reads
# /proc/cpuinfo and prints the highest -march the host can actually run; feed
# that value into the workflow's `arm64_arch` dispatch input to rebuild.
set -eu

case "$(uname -m)" in
    aarch64|arm64) ;;
    *) echo "probe-cpu: this is not an aarch64 host ($(uname -m))" >&2; exit 2 ;;
esac

features=$(awk -F: '/^Features/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)
if [ -z "$features" ]; then
    echo "probe-cpu: cannot read Features from /proc/cpuinfo" >&2
    exit 2
fi
has() { echo " $features " | grep -qw "$1"; }

model=$(awk -F: '/^Hardware/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)
[ -n "$model" ] || model=$(awk -F: '/^Processor/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)
cores=$(grep -c '^processor' /proc/cpuinfo || true)

echo "CPU      : ${model:-unknown}"
echo "cores    : ${cores:-unknown}"
echo "features : $features"
echo ""

for f in asimd asimdhp asimddp i8mm sve sve2; do
    if has "$f"; then echo "  [yes] $f"; else echo "  [ no] $f"; fi
done
echo ""

# asimdhp = FP16 SIMD (Armv8.2), asimddp = SDOT/UDOT (Armv8.4), i8mm = Armv8.6.
# GCC names them +fp16, +dotprod and +i8mm. Only claim an extension when the
# flags for it (and the ones it builds on) are all present.
arch=armv8-a
if has asimdhp; then
    arch=armv8.2-a+fp16
fi
if has asimddp && has asimdhp; then
    arch=armv8.2-a+dotprod+fp16
fi
if has i8mm && has asimddp && has asimdhp; then
    arch=armv8.2-a+dotprod+fp16+i8mm
fi
echo "recommended arm64_arch : $arch"
echo "workflow default       : armv8.2-a+dotprod+fp16"
echo ""
if [ "$arch" = "armv8.2-a+dotprod+fp16" ]; then
    echo "This box matches the workflow default: -march alone needs no rebuild."
else
    echo "Rebuild with: GitHub Actions -> Build Strata engine (EL8 / aarch64 /"
    echo "CUDA 13 / NVFP4) -> Run workflow -> arm64_arch = $arch"
fi
echo ""
echo "GPU / driver (the only GPU prerequisite on this box):"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true
    echo "CUDA 13 needs driver >= 580.65; a newer stable driver is fine (minor version compatibility)."
else
    echo "  nvidia-smi not found: install the official stable NVIDIA .run driver,"
    echo "  which provides libcuda.so.1. No CUDA Toolkit is required."
fi
