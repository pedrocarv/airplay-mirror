#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
data_root=${XDG_DATA_HOME:-$HOME/.local/share}
bin_root=${XDG_BIN_HOME:-$HOME/.local/bin}
app_root="$data_root/airplay-mirror"
applications_root="$data_root/applications"
build_root=$(mktemp -d)

cleanup() {
  rm -rf -- "$build_root"
}
trap cleanup EXIT

if [[ -f "$repo_root/airplay-engine" ]]; then
  engine_source="$repo_root/airplay-engine"
else
  if ! command -v go >/dev/null 2>&1; then
    echo "Go is required when installing from a source checkout." >&2
    exit 1
  fi
  echo "Building the AirPlay sender engine..."
  (
    cd -- "$repo_root"
    CGO_ENABLED=0 go build -trimpath -o "$build_root/airplay-engine" ./cmd/doubletake
  )
  engine_source="$build_root/airplay-engine"
fi

if [[ -f "$repo_root/apps/linux/airplay.py" ]]; then
  app_source="$repo_root/apps/linux/airplay.py"
else
  app_source="$repo_root/airplay.py"
fi

install -d "$app_root" "$bin_root" "$applications_root"
install -m 0755 "$engine_source" "$app_root/airplay-engine"
install -m 0755 "$app_source" "$app_root/airplay.py"

launcher="$bin_root/airplay-mirror"
printf '#!/usr/bin/env bash\nexec "%s/airplay.py" "$@"\n' "$app_root" >"$launcher"
chmod 0755 "$launcher"

desktop_file="$applications_root/airplay-mirror.desktop"
sed "s|@EXEC@|$launcher|g" "$script_dir/airplay-mirror.desktop" >"$desktop_file"
chmod 0644 "$desktop_file"

echo "AirPlay Mirror is installed. Launch it from your app menu or run:"
echo "  $launcher"

if ! ldconfig -p 2>/dev/null | grep 'libfdk-aac\.so\.2' >/dev/null; then
  echo
  echo "Note: libfdk-aac was not found. Install it for AAC-ELD audio; without it,"
  echo "some TVs (for example Sony Google TVs) mirror video but play no sound."
  echo "  Arch: libfdk-aac   Debian/Ubuntu: libfdk-aac2   Fedora: fdk-aac (RPM Fusion)"
fi
