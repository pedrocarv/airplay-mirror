# AirPlay Mirror

Mirror a Linux or Windows desktop, including system audio, to an AirPlay-capable TV. AirPlay Mirror pairs a modified [Doubletake](https://github.com/omarroth/doubletake) sender engine with native desktop interfaces for Linux and Windows.

## Highlights

- AirPlay receiver discovery on the local network
- Entire-display capture that remains stable through fullscreen transitions
- Desktop audio with the receiver's existing volume preserved
- Pairing-code and password prompts inside the app
- Linux GTK 4/libadwaita interface
- Windows WinForms interface with Direct3D 11 capture
- Reproducible Linux x64 and Windows x64 packages from GitHub Actions

## Download

Download the latest Linux or Windows package from [Releases](https://github.com/pedrocarv/airplay-mirror/releases). Packages are also produced as artifacts by every successful GitHub Actions build.

## Linux

### Requirements

- A modern x86-64 Linux desktop using Wayland or X11
- GStreamer with the base, good, bad, and ugly plugin sets
- PipeWire or PulseAudio for desktop audio
- libfdk-aac for AAC-ELD screen audio. Some TVs, including Sony Google TVs, accept the ALAC fallback but play no sound without it
- GTK 4, libadwaita, and PyGObject for the graphical app
- The XDG desktop portal and an appropriate screencast backend when using Wayland
- Go 1.25 or newer when building from source

On Arch Linux and Omarchy, the core packages can be installed with:

```bash
sudo pacman -S --needed go gstreamer gst-plugins-base gst-plugins-good \
  gst-plugins-bad gst-plugins-ugly gtk4 libadwaita python-gobject libfdk-aac
```

On Debian and Ubuntu, libfdk-aac is the `libfdk-aac2` package from the non-free (Debian) or multiverse (Ubuntu) component. On Fedora it is `fdk-aac` from RPM Fusion.

Build and install from a repository checkout:

```bash
./packaging/linux/install.sh
```

This installs the app for the current user and adds `airplay-mirror` to `~/.local/bin`. Start it from the application launcher or run:

```bash
airplay-mirror
```

When the portal picker opens, select the physical display you want to mirror. Selecting the display, instead of an individual app window, allows applications to enter and leave fullscreen without replacing the capture stream.

## Windows

### Requirements

- Windows 10 or Windows 11, 64-bit
- The 64-bit GStreamer MSVC runtime installed with the **Complete** option
- The PC and TV on the same local network

Install GStreamer from the [official Windows download page](https://gstreamer.freedesktop.org/download/#windows), extract the Windows release ZIP, and double-click `Start AirPlay.cmd`. The app checks for the required GStreamer elements before starting a stream.

The Windows build uses Direct3D 11 desktop capture and WASAPI loopback audio. The release ZIP includes `libfdk-aac-2.dll` for AAC-ELD screen audio; keep it next to `AirPlay.Engine.exe`. Windows may ask for network access on first launch; allow it so receiver discovery can work. Campus and office networks are usually classified as Public, so allow that profile too. If no receivers are found, the app offers to repair its firewall permission.

## Build packages locally

The packaging script runs the test suite, builds both engines, and writes archives to `dist/`:

```bash
./scripts/build-packages.sh v0.1.0
```

`zip`, `cmake`, and a MinGW-w64 cross-compiler (`x86_64-w64-mingw32-gcc`/`g++`) are required to create the Windows archive; the script cross-compiles `libfdk-aac-2.dll` from a checksum-pinned fdk-aac release.

## Command-line engine

The graphical apps launch the Go engine from `cmd/doubletake`. To inspect all engine options:

```bash
go run ./cmd/doubletake -help
```

Useful additions in this fork include `-discover-json`, `-capture-source`, `-monitor-index`, `-window-handle`, and `-preserve-receiver-volume`.

## Privacy and security

Screen and audio capture stay on the local AirPlay connection. Pairing credentials are stored in the current user's Doubletake credential file. No telemetry or cloud service is used by this project.

## Project status

Linux display mirroring has been tested on Hyprland/Wayland, including browser fullscreen transitions. The Windows x64 engine and interface are built and cross-compiled in CI; Windows requires local runtime testing with the target PC, GStreamer installation, and receiver.

This is an independent project and is not affiliated with or endorsed by Apple Inc. AirPlay is a trademark of Apple Inc.

## License and attribution

AirPlay Mirror is distributed under the GNU Lesser General Public License v3.0. It is derived from Doubletake; see [ATTRIBUTION.md](ATTRIBUTION.md) and [LICENSE](LICENSE).

AAC-ELD audio uses the Fraunhofer FDK AAC library, which is not part of AirPlay Mirror and is covered by its own license. The engine loads it at run time; the Windows package distributes an unmodified build of it as `libfdk-aac-2.dll` with that license in `FDK-AAC-LICENSE.txt`. The FDK AAC license grants no patent rights; AAC patent licensing is the responsibility of the user.
