# Dependency license inventory

Quant Scenario Studio by LAI ZEYU is authored by **LAI ZEYU（来泽宇）**.
The app itself is distributed under the MIT License in `Legal/LICENSE.txt`.

The Windows build copies the license and notice files shipped by every bundled
Python and frontend runtime dependency into `Backend/Legal/`. It also copies the
license files shipped by the Microsoft Windows App SDK and WebView2 NuGet
packages into `Backend/Legal/NuGet/`. The build fails if an expected license file
cannot be found. The generated SPDX SBOM is the exact component inventory for a
candidate.

Material dependency families include:

- the CPython standard library used by the frozen, offline Store sidecar
  (Python Software Foundation License);
- PyInstaller bootloader/runtime (GPL-2.0-or-later with the PyInstaller
  bootloader exception);
- React, React DOM, scheduler and lucide-react (MIT/ISC-family licenses as
  identified by their installed packages);
- Microsoft Windows App SDK and Microsoft Edge WebView2 SDK (Microsoft package
  license terms included by their NuGet packages).

Third-party names and marks remain the property of their owners. Inclusion does
not imply sponsorship or endorsement. When this summary and a copied upstream
license differ, the copied upstream license controls.
