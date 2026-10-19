#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
version=${1:-dev}
dist_root="$repo_root/dist"
work_root=$(mktemp -d)

cleanup() {
  rm -rf -- "$work_root"
}
trap cleanup EXIT

linux_name="airplay-mirror-linux-x64-$version"
windows_name="airplay-mirror-windows-x64-$version"
linux_root="$work_root/$linux_name"
windows_root="$work_root/$windows_name"

mkdir -p "$dist_root" "$linux_root/apps/linux" "$linux_root/packaging/linux" "$windows_root"

cd -- "$repo_root"
go test ./...

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "$linux_root/airplay-engine" ./cmd/doubletake
install -m 0755 apps/linux/airplay.py "$linux_root/apps/linux/airplay.py"
install -m 0755 packaging/linux/install.sh "$linux_root/packaging/linux/install.sh"
install -m 0644 packaging/linux/airplay-mirror.desktop "$linux_root/packaging/linux/airplay-mirror.desktop"
install -m 0644 README.md ATTRIBUTION.md LICENSE COPYING.GPL "$linux_root/"

CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -o "$windows_root/AirPlay.Engine.exe" ./cmd/doubletake
install -m 0644 apps/windows/AirPlay.ps1 "$windows_root/AirPlay.ps1"
install -m 0644 apps/windows/Discovery.ps1 "$windows_root/Discovery.ps1"
install -m 0644 "apps/windows/Repair discovery.ps1" "$windows_root/Repair discovery.ps1"
install -m 0644 "apps/windows/Start AirPlay.cmd" "$windows_root/Start AirPlay.cmd"
install -m 0644 "apps/windows/Install shortcut.ps1" "$windows_root/Install shortcut.ps1"
install -m 0644 apps/windows/AirPlay.ico "$windows_root/AirPlay.ico"
install -m 0644 apps/windows/AirPlay.svg "$windows_root/AirPlay.svg"
install -m 0644 apps/windows/README.txt "$windows_root/README.txt"
install -m 0644 ATTRIBUTION.md "$windows_root/SOURCE.txt"
install -m 0644 LICENSE "$windows_root/LICENSE.txt"
# AAC-ELD screen audio: the engine loads this DLL at run time.
"$script_dir/build-fdk-aac-windows.sh" "$windows_root"

tar -C "$work_root" -czf "$dist_root/$linux_name.tar.gz" "$linux_name"
(
  cd -- "$work_root"
  zip -qr "$dist_root/$windows_name.zip" "$windows_name"
)

echo "Created:"
echo "  $dist_root/$linux_name.tar.gz"
echo "  $dist_root/$windows_name.zip"
