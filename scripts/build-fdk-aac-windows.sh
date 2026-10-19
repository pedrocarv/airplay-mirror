#!/usr/bin/env bash
# Cross-compile Fraunhofer's fdk-aac as a self-contained Windows x64 DLL for
# the engine's AAC-ELD screen audio. The engine loads it at run time; it is not
# linked into AirPlay.Engine.exe.
#
# Usage: build-fdk-aac-windows.sh OUTPUT_DIR
# Needs cmake and a MinGW-w64 toolchain (x86_64-w64-mingw32-gcc/g++, or set
# MINGW_CC, MINGW_CXX, MINGW_STRIP and MINGW_OBJDUMP).
set -euo pipefail

version=2.0.3
sha256=e25671cd96b10bad896aa42ab91a695a9e573395262baed4e4a2ff178d6a3a78
output_dir=${1:?usage: build-fdk-aac-windows.sh OUTPUT_DIR}

host=x86_64-w64-mingw32
cc=${MINGW_CC:-$host-gcc}
cxx=${MINGW_CXX:-$host-g++}
strip=${MINGW_STRIP:-$host-strip}
objdump=${MINGW_OBJDUMP:-$host-objdump}
for tool in cmake "$cc" "$cxx" "$strip" "$objdump"; do
  command -v "$tool" >/dev/null || { echo "missing build tool: $tool" >&2; exit 1; }
done

work_root=$(mktemp -d)
cleanup() {
  rm -rf -- "$work_root"
}
trap cleanup EXIT

archive="$work_root/fdk-aac-$version.tar.gz"
curl -fsSL -o "$archive" "https://github.com/mstorsjo/fdk-aac/archive/refs/tags/v$version.tar.gz"
echo "$sha256  $archive" | sha256sum -c --quiet -
tar -xzf "$archive" -C "$work_root"
source_dir="$work_root/fdk-aac-$version"

# Link the C++ and GCC runtimes statically so the DLL needs only Windows
# system libraries.
cmake -S "$source_dir" -B "$work_root/build" \
  -DCMAKE_SYSTEM_NAME=Windows \
  -DCMAKE_C_COMPILER="$cc" \
  -DCMAKE_CXX_COMPILER="$cxx" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_PROGRAMS=OFF \
  -DFDK_AAC_INSTALL_CMAKE_CONFIG_MODULE=OFF \
  -DFDK_AAC_INSTALL_PKGCONFIG_MODULE=OFF \
  -DCMAKE_SHARED_LINKER_FLAGS="-static -static-libgcc -static-libstdc++" \
  >/dev/null
cmake --build "$work_root/build" --parallel >/dev/null

dll="$work_root/build/libfdk-aac-2.dll"
[[ -f $dll ]] || { echo "build did not produce libfdk-aac-2.dll" >&2; exit 1; }
"$strip" "$dll"

unexpected=$("$objdump" -p "$dll" | awk '/DLL Name:/ {print $3}' |
  grep -viE '^(kernel32|msvcrt|user32|advapi32)\.dll$|^api-ms-win-crt-.*\.dll$' || true)
if [[ -n $unexpected ]]; then
  echo "libfdk-aac-2.dll depends on non-system DLLs:" >&2
  echo "$unexpected" >&2
  exit 1
fi

mkdir -p "$output_dir"
install -m 0644 "$dll" "$output_dir/libfdk-aac-2.dll"
install -m 0644 "$source_dir/NOTICE" "$output_dir/FDK-AAC-LICENSE.txt"
echo "Built $output_dir/libfdk-aac-2.dll (fdk-aac $version)"
