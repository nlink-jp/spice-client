# Third-party notices

- **Maspice / spice-mac**, commit `4631b0cf43032671fe01e994db5613e78a91037a`,
  MIT, copyright Ching367436 / BeriBeli. Complete notice in [NOTICE.md](NOTICE.md).
  Reviewed compatibility logic informs ordered input; PortalCookieClock and its
  expiry regression fixtures are adapted with attribution. Old updater keys,
  feeds, artwork, and binary releases are not reused.
- **SwiftSpice 0.4.2**, commit `3f8de33a3c91fd7ed42d42b5970e644a8abf94b6`, MIT.
  Complete source and license: [Vendor/SwiftSpice](Vendor/SwiftSpice).
  The three-file clipboard API patch is [Vendor/clipboard-boundary.patch](Vendor/clipboard-boundary.patch).
  Baseline, file hashes, native hashes, and links: [Vendor/UPSTREAM.json](Vendor/UPSTREAM.json).
- **libjpeg-turbo 3.2.0**: IJG, zlib, BSD-3-Clause.
- **spice-common QUIC from spice-gtk 0.42**, **usbredir 0.15.0**, and
  **libusb 1.0.30**: LGPL-2.1-or-later library components.

Native source URLs/checksums and rebuild instructions are preserved in
[build-native-dependencies.sh](Vendor/SwiftSpice/Scripts/build-native-dependencies.sh).
The full native license texts are retained under `Vendor/SwiftSpice/Artifacts/*/Licenses/`
and copied into the application with their separate directory paths. SwiftSpice
and the application are buildable from this source so modified LGPL artifacts can
be substituted and relinked. Preserve this source, patch, build instructions,
licenses, and upstream source availability when preparing distribution.
Static artifacts are pinned, not certified free of defects. Their complete binary
behavior has not been independently audited. The application does not expose USB
or WebDAV functionality, but notices for the vendored dependency closure remain.

Sparkle is not a dependency of this application. The application root LICENSE
applies only to its own MIT code and does not replace any third-party terms.
