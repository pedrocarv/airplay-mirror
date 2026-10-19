# Attribution

AirPlay Mirror is derived from [Doubletake](https://github.com/omarroth/doubletake), an AirPlay mirroring and audio sender by Omar Roth.

- Upstream base revision: `5e2f1cbe3e1070bcefec8e549c7baf884727bc00`
- Upstream license: GNU Lesser General Public License v3.0
- Fork additions: Linux fullscreen-stable monitor capture, receiver-volume preservation, JSON discovery, Windows Direct3D 11 capture, Windows WASAPI loopback audio, cross-platform process management, graphical interfaces, packaging, and CI

The original copyright notices and license files are retained.

## Third-party components

- [Fraunhofer FDK AAC](https://github.com/mstorsjo/fdk-aac) 2.0.3 provides AAC-ELD audio encoding. It is loaded at run time and is not part of AirPlay Mirror. The Windows package includes an unmodified build as `libfdk-aac-2.dll` with its license as `FDK-AAC-LICENSE.txt`.
