# Third-party notices

Quant Scenario Studio is authored and published by **LAI ZEYU（来泽宇）**. It
includes or builds upon open-source components whose copyright and license terms
remain with their respective owners. The
release pipeline produces an SPDX software bill of materials (SBOM); the exact
SBOM and license files distributed with a release are the authoritative
component inventory for that build.

Material runtime/build families include Python, PyInstaller, NumPy, pandas,
React, Vite, Microsoft Windows App SDK, Microsoft WebView2 SDK and their
transitive dependencies. These components are not endorsements of this product.
The Windows build copies upstream license/notice files into the package and
fails if the required legal inventory is missing.

The Microsoft Store candidate does not include a brokerage SDK, account
connector or third-party trading gateway. Any experimental connector module in
the source tree is outside the Store package and is not a Store feature.

Nasdaq and Nasdaq-100 names and marks belong to their respective owners. The
bundled demonstration data is synthetic. Constituent identifiers are used for
research description and do not imply sponsorship, endorsement or ongoing
index membership.

Before any Store submission, generate the release SBOM and compare it with the
packaged `Legal/` inventory. An unexplained component or missing upstream license
is a release blocker.
