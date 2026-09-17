# spice-client

Spice Client is a native macOS SPICE client for opening virtual desktops from
`.vv` connection files and an HTTPS Ravada portal. It redesigns the spice-mac
application around explicit connection confirmation and uses SwiftSpice for the
protocol, display, input, audio, and guest integration.

[日本語](README.ja.md)

## Install

macOS releases are **Developer ID signed and Apple-notarized** (stapled). They
launch without Gatekeeper prompts and work offline.

```sh
brew tap nlink-jp/tap
brew install --cask nlink-jp/tap/spice-client
```

Or download `spice-client-vX.Y.Z-darwin-arm64.zip` from the
[releases](https://github.com/nlink-jp/spice-client/releases), unpack it, and
move `Spice Client.app` to Applications.

## Status

Spice Client targets Apple Silicon and macOS 26 or later. Connection, ticket,
display frames, cursor, keyboard input, and shutdown are verified against a real
spice-server (QEMU 8.2, spice-server 0.15) with a minimal Linux guest through
`make live-peer`; the portal and clipboard boundaries run against a loopback
simulation. A Ravada portal, a desktop guest with the SPICE agent (clipboard,
resize), audio, and H.264 remain unverified. See the
[verification record](docs/en/verification.md) for the tested scope and limits.

## Use

1. Open Spice Client.
2. Open or drop a `.vv` file, or enter an HTTPS portal URL and sign in.
3. Review the source, host, port, and protection in the native confirmation.
   Clipboard sharing starts OFF. Select **Connect** to start this exact plan.
4. Each connection has its own window. Use the Session menu for Ctrl-Alt-Delete,
   releasing captured input, full screen, or disconnecting. Closing a session
   window closes its transport and releases the associated resources.

The app supports plain TCP and TLS with system trust or a `.vv` certificate
authority and optional certificate subject. Invalid TLS fields, unsupported
required options, and ambiguous files produce an error rather than a downgrade.
Files must be regular UTF-8 `.vv` files no larger than 1 MiB. Symbolic links are
rejected. A disabled port may be written as `-1`; a valid TLS port takes priority.

The portal hands connection files to native code only from its main frame and
exact HTTPS origin (including port). Redirect cookies are reselected for each
URL. Script navigation and form submission can offer a candidate but cannot
approve it. Extensionless download URLs are unsupported; save the `.vv` file and
open it manually. A self-issued portal certificate can be approved by its
fingerprint for that portal window only; hostname and expiry checks still apply.

Clipboard sharing is text-only and works only in the focused session window.
Revocation applies at the actual clipboard access, and text last received from
one guest is not automatically relayed to another. A new local copy can be shared.
Settings can enable moving selected connection files to Trash **after connection
success** (OFF by default); changed/replaced files are preserved. Portal downloads
stay in memory. The portal login store is separate from Maspice and can be cleared
in Settings. No migration of old settings or saved SPICE passwords is performed.

The display follows the viewport size when the guest agent supports it. Audio
playback uses the advertised playback channel. A codec availability failure before
any advanced-video frame is presented can retry once with MJPEG. Diagnostics are
opt-in aggregate counters; credentials, keys, clipboard text, and screen contents
are not included in the summary. English and Japanese UI text is included.

Automatic updates, USB redirection, microphone capture, WebDAV sharing, proxy
connections, multiple guest display streams, and Intel builds are not included.

## Build and test

Prerequisites: Apple Silicon, macOS 26+, Xcode with Swift 6.3 or later, Metal Toolchain,
Python 3, and OpenSSL for simulation. `make doctor` compiles a real Metal shader;
the presence of an executable shim alone is insufficient.

```sh
make doctor
make test          # app regressions, provenance, documentation, archive rejection tests
make test-vendor   # all SwiftSpice tests, sequential to avoid fixture contention
make simulate      # real WebKit + local HTTPS + simulated SPICE wire protocol
make live-peer     # real spice-server in QEMU (TCG) under Podman + minimal Linux guest
make build         # produces dist/Spice Client.app, local ad-hoc signature
open "dist/Spice Client.app"
```

`make simulate` creates temporary loopback endpoints and short-lived synthetic
certificates/tickets. It does not require a VM, write the system trust store, or
access a real user's clipboard. The app also accepts a `.vv` path as an argument;
`--version`, `--resource-check`, `--smoke-test`, and `--portal-smoke=<https url>`
(opens that portal in this exact bundle and reports whether WebKit rendered it)
support local verification.
`make live-peer` needs Podman with a running machine. On first use it builds a
QEMU image and a small Alpine guest (about 18 MB, kept outside git), then starts
one container that publishes SPICE on loopback only with a per-run ticket,
connects through the application's own session path, checks that the guest
received the injected key, and stops the container. It does not cover audio,
H.264, the Ravada portal, or the guest agent. `make package` refuses to release a
commit without a clean `make live-peer` pass recorded for it.
To regenerate the original icon, run `swift scripts/create-icon.swift` followed
by `iconutil -c icns dist/AppIcon.iconset -o Resources/AppIcon.icns`.

`make package` is a separate release operation. It requires Developer ID signing
and successful notarization using the organization's signing scripts; it cannot
produce a trusted release by silently falling back to the local ad-hoc build.
`make verify-release` unpacks and verifies the final ZIP itself, including its
identity, version, signature, stapled ticket, bundled Metal resources, and the
macOS SDK the binary was linked against. `make build` links against the installed
SDK explicitly and rejects any other result, because macOS draws an app linked
against an older SDK with the previous generation of window chrome.
Do not distribute a local build as a notarized release.

## Structure and review

- `ConnectionCore`: immutable `.vv` parsing and origin/cookie rules.
- `SessionCore`: one-shot confirmation and session lifecycle.
- `SwiftSpiceAdapter`: transport ownership, ordered input, and clipboard authority.
- `SpiceClient`: native windows, portal, file intake, settings, and localization.
- `Vendor/SwiftSpice`: pinned v0.4.2 with a narrow clipboard access patch.

[Accepted design](docs/en/adr/0001-native-client-port.md) ·
[All 76 reference files](docs/en/source-map.md) ·
[Review and fixes](docs/en/review.md) ·
[Verification](docs/en/verification.md)

## License

MIT (see [LICENSE](LICENSE)) for the application code. This work derives specifications and selected compatibility
code from [Maspice](https://github.com/BeriBeli/spice-mac) (Ching367436 / BeriBeli).
The backend is [SwiftSpice](https://github.com/BeriBeli/spice-swift).
See [NOTICE.md](NOTICE.md), [third-party notices](THIRD_PARTY_NOTICES.md), and the
pinned file hashes and patch in `Vendor/`. Native libraries retain their own
licenses, including LGPL components; they are not relicensed as MIT.
