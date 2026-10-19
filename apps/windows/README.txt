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
* Pairing credentials are stored under your Windows user profile in:
  .config\doubletake\credentials.json
* Windows may ask for network access the first time. Allow Private networks so
  AirPlay discovery can see TVs on your home network.
* If an update causes discovery to return no TVs, the app can repair its
  private-network firewall permission and retry after administrator approval.

Source: https://github.com/pedrocarv/airplay-mirror
License: GNU Lesser General Public License v3.0
