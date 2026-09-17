# ADR-0003: 実ピアゲートのエージェント付きゲスト — 実物の spice-vdagent に対するクリップボードとリサイズ

| Field | Value |
|-------|-------|
| Status | Proposed |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | ADR-0002 は、本アプリが参照元と最も異なるクリップボードブローカーとリサイズ経路をシミュレーションのみの検証のまま残した |

## Context

ADR-0002 の実ピアはエージェントの無い最小 Alpine ゲストなので、ADR-0001 が再設計した 2 つの
境界、ホストクリップボードの権限（既定 OFF、操作中のセッションのみ、実アクセス時の取り消し）と
ビューポート駆動のリサイズを検証できない。どちらもエージェントチャネル経由でゲストの
`spice-vdagent` と会話し、ループバックシミュレーションにはエージェントが無い。

SwiftSpice の Apple/container ハーネスにはエージェント付きゲストがある。`dbus`、
`spice-vdagent`、`xclip`、`xorg-server`（`/dev/dri/card0` 上の組み込み modesetting ドライバ）、
`xrandr` を持つ Alpine rootfs、スタックを起動して固定のクリップボードと配置の fixture を報告する
init、それを消費する probe である。

2026-09-18 の実測（scratch でのスパイク。コミットしていない。ADR-0002 のイメージと Podman machine、
同じ `linux-virt` カーネル）:

- Alpine 3.22 公式 CDN から `apk --root --initdb` で作ったエージェント rootfs（`alpine-base`、
  `dbus`、`spice-vdagent 0.22.1`、`xclip`、`xorg-server 21.1.19`、`xrandr`、`linux-virt`）は
  315 MB で、113 MB の initramfs になる。ゲストは 2 回の起動とも `podman run` から 7 秒で
  `AGENT_STACK_STARTED`（Xorg 起動、`spice-vdagentd` と `spice-vdagent` 接続、解像度 1280x800
  報告）に達した。
- `/dev/uinput` が無いと `spice-vdagentd` は `Fatal uinput error` で終了する。Alpine の virt
  カーネルは `uinput` をモジュールで持つ。init で読み込むとエージェント接続が直った。
  `alpine-base` の busybox `mdev.conf` は `/dev/virtio-ports/com.redhat.spice.0` を作る。
- 5 秒の settle 後、upstream の probe を `--require-agent --exercise-clipboard
  --exercise-monitor-config` で走らせると合格した。ゲストはホストのクリップボード fixture
  （26 バイト、期待どおりの SHA-256）を記録し、自身のテキストを提供して probe が往復を検証し、
  要求した 2 モニタ配置（800x600 + 640x480、`XRANDR_DUAL_MONITOR_COMPLETE`）を適用した。
  Xorg が表示を持つとフレーム流はコンソール tick の毎秒数十枚ではなく静的デスクトップ
  （10 秒で 9 枚）になる。

## Decision

### 1. ゲストは 1 つ、init は層構造

エージェント付きゲストは ADR-0002 の最小ゲストの隣に加えるのではなく置き換える。
`Integration/LivePeer/guest/build-in-container.sh` は `https://dl-cdn.alpinelinux.org/alpine`
（upstream スクリプトの既定である第三者ミラーは使わない）から `apk --root --initdb` で作り、
カーネルは同じ `linux-virt` パッケージから取り、モジュール群は従来どおり刈り込んだうえで `uinput`
を残し、インストールした全パッケージを `guest.json` に記録する。

`guest/init` は、Xorg が壊れてもエージェントのテストだけが落ちるよう層にする:

1. 基盤: マウント、`modprobe`（`virtio_gpu`、`virtio_input`、`evdev`、`uinput`、`drm`）、
   `mdev -s`、入力イベントのダンプ、そして現在どおり `GUEST ready` と `GUEST monitoring …`。
   コンソール tick は Xorg が表示を持つので落とす。
2. エージェント: `dbus-daemon`、`spice-vdagentd`、modesetting 設定の Xorg、`spice-vdagent`、
   そして `AGENT_STACK_STARTED`。いずれかの段のタイムアウトでは `AGENT_ERROR <理由>` を出し、
   基盤のループは止めない。
3. 観測: クリップボードループが毎秒 2 回 X のクリップボードを読み、変化ごとに
   `CLIPBOARD_OBSERVED bytes=N sha256=…` を記録する。テキストが
   `spice-client host clipboard <token>` の形なら `spice-client guest clipboard <token>` を
   提供して応答し、`CLIPBOARD_OFFERED <token>` を記録する。xrandr ループは `Virtual-1` の
   推奨モードが変わるたびに適用し、`XRANDR_MODE WxH` を記録する。

`run.sh` は従来どおり `GUEST monitoring` 行を待ち、続いて `AGENT_STACK_STARTED` を待ち
（有界。`AGENT_ERROR` は実行失敗）、5 秒 settle し、環境ファイルに
`SPICE_CLIENT_LIVE_PEER_AGENT=1` を加える。大きな initramfs のため QEMU は `-m 2048`、
コンテナは `--memory 3g` にする。

### 2. エージェントのテストが検証すること

`Tests/SpiceClientTests/LiveAgentTests.swift` は `SPICE_CLIENT_LIVE_PEER_AGENT` で有効になり、
メモリ上のペーストボードに対する注入済み `ClipboardBroker(read:write:)` で `SessionController` を
駆動する。操作者の `NSPasteboard` は読みも書きもしない（アクセスを注入すると vendored パッチは
`SpicePasteboardBridge` にフォールバックしない）。

- **ホスト→ゲストは共有とフォーカスに従う。** 共有 ON でセッションが操作中のとき、新しい
  ホストテキスト `spice-client host clipboard <token>` は 10 秒以内にゲストが SHA-256 付きで
  記録する。共有 OFF では 2 つ目の token は 5 秒以内に記録されない。共有を再度 ON にすると
  3 つ目は記録される。フォーカスを手放すと 4 つ目は記録されず、取り戻すと 5 つ目は記録される。
- **ゲスト→ホストは共有に従う。** 届いた token へのゲストの応答
  `spice-client guest clipboard <token>` が 10 秒以内にメモリ上のペーストボードに現れる。
  共有 OFF が止めた token には応答が来ない。
- **リサイズは Xorg に届く。** `resizingAvailable` が真になったら、`resize(width: 1024,
  height: 768)` は 15 秒以内にゲストログに `XRANDR_MODE 1024x768` を生み、
  `resize(width: 1280, height: 800)` は `XRANDR_MODE 1280x800` を生む。
- 診断サマリに token もホストも含まれない。

`LivePeerTests`（トランスポート、TLS）は同じゲストに対して変更なく走る。フレームの assert
（30 秒以内に 1 リビジョン以上）は静的デスクトップでも成り立つ。ゲートは 8 テスト全部の受領証を
要求する。1 セッションでは示せないこと、2 セッション間のゲスト→ゲスト中継の禁止は、ブローカーの
ユニットテストに残す。

### 3. 出所と限界

ADR-0002 と同じ: 両イメージ digest 固定、パッケージは固定せず記録、`guest.json` にエージェント
パッケージを列挙、合格記録がそれを埋め込む。対象外: 音声、H.264、Ravada ポータル、ファイル転送、
デスクトップ環境固有のクリップボードマネージャ、USB。

## Consequences

- クリップボードブローカーとリサイズ経路が、参照元クライアントが漏らした境界で、実物の
  `spice-vdagent 0.22` に対して、2 つの取り消し辺（共有 OFF、フォーカス喪失）を含めて検証される。
- ゲスト成果物は 8 MB から約 113 MB に増え、このホストでの起動は 4 秒から 7 秒になる。Xorg が
  可動部に加わるが、層構造の init で閉じ込める。ゲートの所要時間は settle 分を足してほぼ同じ。
- 実フレーム流は静的デスクトップになる。フレームの assert は 1 リビジョンの閾値を保ち、
  ADR-0002 のコンソール tick の計測値は置き換えられる。

## Alternatives considered

1. **最小ゲストとエージェントゲストの 2 本** — 豊かなフレーム流と、Xorg が壊れたときの
   トランスポート専用ゲートを保てるが、成果物 2 組とゲートごとの起動 2 回が要る。層構造の init が
   同じ隔離を起動 1 回で与える。
2. **upstream のエージェント init をそのまま再利用** — 固定 fixture は一度しか答えず、ブローカーが
   存在する理由である取り消しの系列を表せない。
3. **upstream の probe でエージェントを検証** — サーバーとゲストは証明できるが、本アプリの
   ブローカー、フォーカス規則、リサイズ経路は証明できない。
4. **ゲストにデスクトップ環境** — 実物のクリップボードマネージャを検証できるが、サイズと起動時間が
   数倍になる。先送り。

## References

- [ADR-0001](0001-native-client-port.ja.md) §2（クリップボード権限）と §4 R7、
  [ADR-0002](0002-live-peer-gate.ja.md) フェーズ 1 と 1b。
- upstream のエージェントゲスト: `Vendor/SwiftSpice/Integration/AppleContainer/guest/`
  （`agent-init`、`xorg.conf`、`build-agent-rootfs.sh`）、MIT で再利用。
- [Testing](https://github.com/nlink-jp/knowledge/blob/main/docs/ja/testing.md):
  ビューが観測するものを観測する。ゲートは自身の実行を証明する。
