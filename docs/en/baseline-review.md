# spice-mac / Maspice review

Review date: 2026-09-17

Addendum: the full test run and the distribution build were rerun the same day,
after the Metal Toolchain was installed. Both succeeded. The seven principal
findings are unfixed.

Subject: `spice-mac local working copy`, Maspice 0.5.4, commit
`4631b0cf43032671fe01e994db5613e78a91037a`.

## Assessment

In the sources examined, no evidence was found of an intentional backdoor, of
hidden transmission to a third party, of persistence, or of unauthorized
execution of downloaded code. What was confirmed is that the user-gesture
judgment can be bypassed, that the updater library carries known
vulnerabilities, that the portal and TLS trust boundaries are incomplete, and
that shutdown handling stalls. The current state cannot be assessed as "no
safety problem".

There are seven principal findings. P1 means fix first and P2 means fix in the
ordinary course; neither is a CVSS severity. What follows distinguishes facts
confirmed by running the implementation, reproductions in a simulated
environment, and external official advisories.

## Principal findings

### R1 — P1: an automatic navigation driven by JavaScript is judged a user gesture

Subject: [RavadaNavigationDecider.swift:209](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/RavadaNavigationDecider.swift#L209)

`isUserInitiated` allows `.formSubmitted` and its like unconditionally, and for
`.other` it takes `buttonNumber == 0` as evidence of a real click. But WebKit
returns that same value for a navigation driven from `window.onload` with no
user input at all.

Reproduced with the same `WebPage` API the application uses and the actual
`RavadaNavigationDecider.isUserInitiated`:

```text
automatic navigation by window.location.href:
  type=-1 (.other), button=0, main=true, host=portal.example
  ACTUAL isUserInitiated=true allowedURL=true
automatic submission by form.submit():
  type=1 (.formSubmitted), button=0, main=true, host=portal.example
  ACTUAL isUserInitiated=true allowedURL=true
```

Nothing downstream asks the user again: the downloaded `.vv` is handed to
`openDownloadedConnection` → `SessionModel.start`. A malicious script on the
portal, or an XSS, can therefore start a SPICE connection the user did not
choose. Once such a connection stands, the clipboard sharing that is enabled by
default is affected as well. This does not demonstrate arbitrary code execution.

**Remediation:** do not rest approval on `buttonNumber` or on the navigation
type alone. Where the public API cannot prove a trustworthy user gesture, put in
an approval boundary that web content cannot satisfy on its own — for instance,
naming the destination on the native side and taking the user's approval to
connect. Add behavioural tests that refuse an automatic form submission and an
automatic location change.

### R2 — P1: Sparkle 2.9.4 is subject to known vulnerabilities

Subject: [Package.swift:17](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Package.swift#L17), [Package.resolved](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Package.resolved)

Sparkle, used for automatic updates, is pinned at 2.9.4. According to the
official information as of 2026-09-17, that version does not carry the
following fixes.

| Advisory | Affected and fixed in | Conditions for exploitation, and impact |
|---|---|---|
| [GHSA-3x7w-j75x-ppq5](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5) | 2.9.5 and below, fixed in 2.9.6 | A local race that substitutes a path. Where the installer runs as root — updating a system location, for example — it can lead to moving protected files or to privilege escalation. There are further conditions, such as the file name. |
| [GHSA-gmj2-gq3j-vqmj](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-gmj2-gq3j-vqmj) | 2.9.4 and below, fixed in 2.9.5 | Requires a malicious delta update that passes signature verification. That presupposes a stolen signing key or the like; an ordinary network attack alone does not achieve it. Overwrites files outside the extraction destination. |
| [GHSA-4v99-qgq9-6pxp](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp) | 2.2.0 to 2.9.5, fixed in 2.9.6 | Cache handling where the updating CLI or daemon itself runs as root. That condition does not simply hold for Maspice, which starts as an ordinary user. |

The application carries an EdDSA public key, and verification before extraction
is enabled. That much is appropriate, but it is not a reason to leave the fixed
vulnerabilities above in place. No privilege escalation and no execution of a
malicious update was carried out in this review.

**Remediation:** update to a version that carries at least the fixes of 2.9.6,
and check the pinned revision, the licence statement and the update behaviour.
What 2.9.6 fixed is stated in the [official release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6).

### R3 — P2: the same-origin judgment includes neither the port nor the source scheme

Subject: [RavadaNavigationDecider.swift:197](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/RavadaNavigationDecider.swift#L197), and around lines 204 and 259 of the same file.

Only the host name is kept from the configured URL. The download destination is
compared on HTTPS plus host name, the source on main frame plus host name, and
a redirect destination again on nothing but HTTPS plus host name.

Calling the actual judgment: with `https://portal.example/` configured,
`https://portal.example:8443/test.vv` was allowed. A different host and an HTTP
destination were refused. An application running on another port of the same
host is thereby treated as equal to the configured portal. This does not match
the README's description of "same-origin" either.

**Remediation:** keep the configured URL's scheme, normalized host and effective
port, and use the same judgment for the source, for the first download
destination and for every redirect. Note that an HTTP cookie is not itself a
mechanism separated by port, so this is mainly a question of how wide the
permission to hand something over to a native connection is.

### R4 — P2: a cookie's path restriction is not applied after a redirect

Subject: [RavadaNavigationDecider.swift:121](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/RavadaNavigationDecider.swift#L121), [the same file:259](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/RavadaNavigationDecider.swift#L259)

The cookie's domain, path, secure flag and expiry are matched against the first
URL, but after the Cookie header has been set by hand and automatic cookie
handling disabled, the redirect request is allowed through as it stands. There
is no reselection at the destination.

A 302 redirect from `/private/session.vv` to `/public/final.vv` was performed
with the actual `PortalURLSessionDelegate` and a loopback HTTPS server. A
synthetic cookie that should apply only to the first path was received at the
final server as follows.

```json
{"path": "/public/final.vv", "cookie": "review_only=synthetic"}
```

The application's own `cookie(appliesTo:)` judges this cookie true for the first
URL and false for the final one. The problem is that the judgment is not used
for the redirect. A cookie's Path is not generally a complete security boundary
within one origin, but the behaviour amounts to handing credentials to
server-side handling at another path, where they would not normally be sent.

**Remediation:** at each redirect, erase the existing Cookie header and rebuild
the permitted cookies against the destination URL and the current time, or keep
only the necessary cookies in a dedicated ephemeral store. Test redirects that
require a login cookie to be refreshed as well.

### R5 — P2: a malformed TLS port specification switches over to a plaintext connection

Subject: [VVConfig.swift:190](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/VVConfig/Sources/VVConfig/VVConfig.swift#L190), [the same file:235](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/VVConfig/Sources/VVConfig/VVConfig.swift#L235), [SpiceClient.swift:541](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/SpiceController/Sources/SpiceController/SpiceClient.swift#L541)

A malformed `tls-port` is converted to the nil that means "not specified". If a
valid `port` remains, validation passes and `makeEndpoint` chooses no TLS.

Reproduced using the implementation:

```text
port=5900 + tls-port=5901  -> validated=true, isTLS=true,  selectedPort=5901
port=5900 + tls-port=oops  -> validated=true, isTLS=false, selectedPort=5900
port=5900 + tls-port=65536 -> validated=true, isTLS=false, selectedPort=5900
```

The condition is a file with no custom CA and no host-subject, whose plaintext
port is valid. A case where a CA is given is refused by a separate check. A
plaintext connection is itself a supported feature; what is a problem is
turning an input error in the TLS specification into plaintext without
reporting it.

**Remediation:** distinguish between not specified, the value the specification
uses to disable, and syntactically malformed or out of range. Treat a malformed
value for the TLS port as an error and stop the connection.

### R6 — P2: `secure-channels`' encryption requirement is silently ignored

Subject: [VVConfig.swift:242](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/VVConfig/Sources/VVConfig/VVConfig.swift#L242), [SpiceConnectionParameters.swift:43](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/VVConfig/Sources/VVConfig/SpiceConnectionParameters.swift#L43)

An unknown key is merely stored in `raw`; `secure-channels`, which matters for
security, is neither validated nor refused. Even with no TLS port, plaintext
connection parameters could be produced from the following input.

```ini
[virt-viewer]
type=spice
host=example.invalid
port=5900
secure-channels=main;display;inputs
```

Result: `accepted=true, isTLS=false`.

`secure-channels` is the specification of which channels to encrypt.
[virt-viewer official manual](https://gitlab.com/virt-viewer/virt-viewer/-/raw/master/man/remote-viewer.pod)

**Remediation:** if the key is supported, guarantee the encryption it requires.
If it is not, refuse it explicitly, as proxy and host-subject already are. List
the other unsupported keys that bear on safety too, and do not treat "stored"
as "validated".

### R7 — P2: when the input send jams, the actual disconnect cannot be reached

Subject: [SpiceClient.swift:173](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/SpiceController/Sources/SpiceController/SpiceClient.swift#L173), [OrderedSpiceInputPump.swift:81](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/SpiceController/Sources/SpiceController/OrderedSpiceInputPump.swift#L81)

`disconnect` marks the displayed state as disconnected first, but the
asynchronous teardown runs in the order `oldInputPump.shutdown()` → stop the
agent → stop audio → `session.disconnect()`. `shutdown` waits without any bound
for the in-flight send task to finish.

If the destination takes no data and the send stalls, the session disconnect
needed to interrupt that send is never reached. Stopping the agent and audio is
deferred too. The same wait exists in the failure path and in the codec
reconnection.

With a controllable simulated send injected into the actual input pump:

```text
blocked send: reached transport disconnect=false
after teardown cancellation: reached transport disconnect=false
after send released: reached transport disconnect=true
```

The body of the input pump was used unchanged; SwiftSpice's types and the
diagnostic output were replaced with minimal stubs. Reproduction through a real
network stall or through the application's own window operations was not
performed. That the upstream send path awaits a Network connection's send was
confirmed in the source.

**Remediation:** make the key-release send a best effort with a finite deadline,
and on expiry abandon the send and close the transport. Disable host
integration such as the clipboard without waiting for the jammed input to
complete. Add regression tests covering a stalled send and cancellation.

## Minor defects and maintainability

### P3: "move to the Trash after connecting" runs immediately after the connection starts

[SessionModel.swift:80](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/SessionModel.swift#L80)
moves the file to the Trash immediately after `client.connect()`, which starts
the connection asynchronously. On an authentication failure or an unreachable
host the file is gone from its original place all the same, which makes a retry
awkward. Moving a file the user chose to the Trash once `.connected` is reached,
and only once, is what matches the UI's description. Immediately deleting a
portal temporary file that holds a short-lived ticket can be kept as a separate
policy.

### P3: doctor wrongly judges the Metal Toolchain to be available

[doctor.sh:40](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/scripts/doctor.sh#L40)
looks only at whether the executable obtained from `xcrun -f metal` exists. At
the first review, before the Metal Toolchain was installed, a forwarding
executable was present, so doctor displayed success while make test and
make build failed because no actual Metal Toolchain was available. On the
rerun after installation both the tests and the build succeeded, so the
obstruction in the current environment is gone. The judgment code in doctor
itself has not been changed, however. As the upstream build script does, it
should go as far as confirming that the compiler can be invoked.

### P3: the bundled licence document names an old dependency version

[THIRD-PARTY-LICENSES.txt:10](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/THIRD-PARTY-LICENSES.txt#L10)
and the same document's reference to the rebuild procedure still say SwiftSpice
0.2.4. It is 0.4.2 in fact, and the document is copied into the application. An
audit or a dependency identification is pointed at the wrong version. This is
not a judgment of legal compliance; it is a finding about an inconsistent
version statement.

### The tests depend on implementation strings over a wide area

[SwiftUICommandRegistrationTests.swift:403](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Tests/MaspiceTests/SwiftUICommandRegistrationTests.swift#L403)
uses `source.contains(...)` many times, for the portal's safety as well, and
requires the presence of `action.buttonNumber == 0`, the very string that is the
problem. It is partly effective against duplicated configuration, but it
guarantees nothing about the authorization, cookie and redirect behaviour.
Replacing it with behavioural tests that can actually refuse R1, R3 and R4 is a
high priority.

### Release quality assurance depends on manual work

[release.sh:62](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/scripts/release.sh#L62)
performs the build and the version verification, but does not run make test
or confirm that CI passed for the commit being published. The real-hardware and
clean-environment tests the README requires separately are not automatic
conditions of publication either. Distribution under an ad-hoc signature
without notarization is stated in the README as well, so it is not a suspicious
hidden behaviour, but the assurance for general distribution is limited. At a
minimum, the release procedure itself ought to be able to confirm that the
tests passed before publication.

## What is done well

- The UI, connection control, configuration parser and lifecycle are separated.
  The input pump has an injection point for the send, which made it possible to
  verify the stall above without real hardware.
- Reading a `.vv` from disk and receiving one over HTTP are both limited to
  1 MiB, and the UTF-8, port-range and custom-CA preconditions are checked. A
  simple proxy specification is refused explicitly.
- Building a TLS connection selects between the system, per-file CA and
  host-subject policies, and no path is found by which the application chooses
  upstream's `insecureForTestingOnly`.
- The diagnostic output is centred on fixed fields and aggregate values; no code
  that prints passwords, clipboard bodies, input contents or screen pixels was
  confirmed.
- Dependency versions and revisions are pinned, and Sparkle's binary
  distribution carries a checksum too. SwiftSpice's native dependencies come
  with the original source's URL, hash and rebuild procedure.
- The build artifact's library references are inspected, and there is no code
  that rewrites an absolute path from Homebrew or elsewhere afterwards to hide a
  problem. This audit alone does not, however, guarantee that every dependency
  file is present or that the application launches.

## Scope of the search for suspicious code

The structure was confirmed from the 76 tracked files, and the application and
local package implementations, the tests, every shell script, CI, Info.plist,
the update configuration and the principal documents were examined. The entry
points for execution, communication, persistence, logging, cookies, clipboard
and file operations were searched, and the related code followed.

The destinations confirmed are the configured Ravada portal, the SPICE server
named in the connection file, and the update, help and dependency sources on
GitHub. No code indicating a resident registration, arbitrary command execution
on the host, or transmission to a hidden analytics service was found in Maspice
itself. The public key is for update verification and is not a private key. A
limited pattern search over the tracked files also detected no private key, no
typical GitHub token, no AWS access key, no curl-to-shell and no
LaunchAgent/Daemon registration.

In the SwiftSpice 0.4.2 that was fetched, the package structure, the build
plugin, the native dependencies' build procedure, TLS, session send and receive,
and the agent, clipboard and audio paths were examined in addition. Upstream's
SSH code for testing and the like sit in a separate executable target and have
not been confused with a hidden transmission in Maspice itself.

Not carried out, however: a complete audit of all SwiftSpice sources,
disassembly of the bundled C binaries and a reproducible-build comparison
against the original sources, a secret audit of the entire Git history, and a
check that the published ZIP matches the sources. This is therefore not a
guarantee that "no malicious code exists at all".

## Checks performed

Environment: Apple Silicon, macOS 27.0, Xcode's Swift 6.4 / macOS 27 SDK.

| Check | Result |
|---|---|
| Dependency resolution | Succeeded. SwiftSpice 0.4.2, Sparkle 2.9.4. No tracked file changed. |
| VVConfig within make test | 28 cases passed, including a deterministic fuzz test over 20,000 inputs. |
| SpiceSessionLogic within make test | 4 tests passed. |
| The whole application under make test | 39 tests in 4 suites passed on the rerun after the Metal Toolchain was installed. The whole of make test, including VVConfig's 28 cases and SpiceSessionLogic's 4, exited 0. |
| The existing cookie-expiry tests | Copied into a temporary package without changing the original sources or tests; 9 tests passed. Not a full lifecycle test of the WebKit store. |
| make build | Succeeded on the rerun after installation. Metal compilation, application assembly, the dynamic-library audit before and after assembly, the ad-hoc signature and codesign's deep/strict verification, and generating the ZIP and SHA-256 files all completed. |
| make doctor | Succeeded. After installation, in an environment with the necessary permissions, the components' installed state and an actual successful compilation were confirmed as well. The wrong judgment before installation is as described above. |
| make check-version | Succeeded. |
| shellcheck --severity=warning -x scripts/*.sh | Succeeded. |
| The actual WebPage plus the permission judgment | Reproduced R1 and R3. The communication was cancelled after the judgment. |
| The actual URLSession delegate plus a temporary HTTPS server | Reproduced R4. Only 127.0.0.1 and a synthetic cookie were used. The server has been stopped. |
| The actual VVConfig plus the connection parameters | Reproduced R5 and R6. No connection to a real server. |
| The input pump plus a stallable simulated send | Reproduced R7. Upstream's types and diagnostics were stubs. |
| git status / diff at the end | No change. No fix, no commit and no publication was carried out. |

Logs: make test (audit material kept locally), make build (audit material kept
locally), the existing cookie tests (audit material kept locally). The
reproduction programs were saved under evidence (audit material kept locally).
Those programs include a concatenation of the original sources as they stood at
review time. They use synthetic data only, and are kept distinct from adding to
or fixing the original project's tests.

A connection to a real Ravada or QEMU, real-hardware tests of disconnect and
reconnect, display, audio, clipboard and update, and a compatibility check on
macOS 26 were not performed. The obstruction to the local full test run and the
distribution build is gone, but the existing tests passing does not mean R1 to
R7 are fixed.

## Re-verification logs after the Metal Toolchain was installed

- The full test run (audit material kept locally)
- The distribution build (audit material kept locally)

There was one warning, that linking the test binary had ignored a
`duplicate -rpath`. There was no test failure and no warning from the
distribution build. The first run's failure log is kept as a record.

Artifacts: `Maspice.app` (a local artifact of the time), `Maspice.app.zip` (a
local artifact of the time). Developer ID signing and notarization were not
performed. The application was not launched, no connection was made, and
nothing was published.
