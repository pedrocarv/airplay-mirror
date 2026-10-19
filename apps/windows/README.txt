AIRPLAY MIRROR FOR WINDOWS (64-BIT)
===================================

Requirements
------------
* Windows 10 or Windows 11, 64-bit
* Both devices on the same local network
* The 64-bit GStreamer MSVC runtime, installed with the Complete option

Official GStreamer download:
https://gstreamer.freedesktop.org/download/#windows

First run
---------
1. Extract the entire ZIP to a permanent folder.
2. Install the 64-bit GStreamer MSVC runtime and choose Complete.
3. Double-click "Start AirPlay.cmd".
4. Choose a TV and display, then click Start mirroring.
5. If the TV shows a pairing code, enter it in the app when prompted.

Optional: right-click "Install shortcut.ps1" and choose Run with PowerShell
to add AirPlay Mirror to the Desktop and Start menu.

Notes
-----
* The receiver's current volume is preserved.
* Video uses Direct3D 11 desktop capture.
* Desktop sound uses Windows WASAPI loopback capture.
* libfdk-aac-2.dll provides the AAC-ELD audio codec many TVs require. It is
  the Fraunhofer FDK AAC library, covered by its own license in
  FDK-AAC-LICENSE.txt, which grants no patent rights. Keep it next to
  AirPlay.Engine.exe; without it the app falls back to ALAC audio.
* Pairing credentials are stored under your Windows user profile in:
  .config\doubletake\credentials.json
* Windows may ask for network access the first time. Allow access so
  AirPlay discovery can see TVs on your network. On campus or office networks
  Windows usually treats the network as Public, so allow that as well.
* If discovery returns no TVs, the app can repair its Windows Firewall
  permission and retry after administrator approval.

Source: https://github.com/pedrocarv/airplay-mirror
License: GNU Lesser General Public License v3.0
