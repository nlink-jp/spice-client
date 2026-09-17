# ADR-0003: 実ピアゲートのエージェント付きゲスト — 実物の spice-vdagent に対するクリップボードとリサイズ

| Field | Value |
|-------|-------|
| Status | **Accepted** — 2026-09-18 ユーザー承認。同日、独立の設計検証パスを受けて改訂（改訂注記を参照） |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | ADR-0002 は、本アプリが参照元と最も異なるクリップボードブローカーとリサイズ経路をシミュレーションのみの検証のまま残した |

改訂注記（2026-09-18）: 設計検証パスで、保留したホストテキストが共有再開と同時に提供されること、
時間窓による負の assert が競合依存であること、同一エージェント接続での 2 回目のリサイズがバックエンド
では応答待ちなのに virtio-gpu は応答しないこと、層構造の init と `AGENT_ERROR` で実行を失敗させる記述が
矛盾すること、ゲートの新ロジックに自己テストが無いことが指摘された。§1〜§2 は改訂後の本文。ADR-0002 は
フェーズ 2 をフェーズ 1 の 1 リリース運用後としていたが、ユーザーはその前に同日進めることを選んだ。

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
  （10 秒で 9 枚、1 回の計測）になる。
- ゲストの画面サイズはクライアントに戻ってこない。ゲストが
  `xrandr --fb 800x600 --output Virtual-1 --mode 800x600` を適用し、ゲスト自身の
  `xrandr --query` が 800x600 の画面を報告している状態でも、クライアントが受け取るフレームは
  すべて 1280x800 のままだった。`virtio-gpu-pci` では QEMU 8.2 の SPICE バックエンドが
  ゲストの新しい画面サイズでプライマリサーフェスを再公開しない。これが正しく動く QXL は
  `qemu-system-aarch64` が提供するデバイスに無い（`virtio-gpu-pci` と `bochs-display` のみ）。
  upstream のハーネスも同じことをゲスト側の `xrandr --query` で検証しており、クライアントの
  サーフェスでは検証していない。

## Decision

### 1. ゲストは 1 つ、init は層構造

エージェント付きゲストは ADR-0002 の最小ゲストの隣に加えるのではなく置き換える。
`Integration/LivePeer/guest/build-in-container.sh` は `https://dl-cdn.alpinelinux.org/alpine` の
`main` と `community` リポジトリ（upstream スクリプトの既定である第三者ミラーは使わない。
`spice-vdagent`、`xorg-server`、`xclip` は `community` にある）から `apk --root --initdb` で作り、
パッケージ署名は固定イメージの `/etc/apk/keys` で検証する。カーネルは同じ `linux-virt` パッケージから
取り、モジュール群は従来どおり刈り込んだうえで `uinput` を残し、インストールした全パッケージと init と
自身の SHA-256 を `guest.json` に記録するので、どちらかが変わればゲートがゲストを作り直す。

`guest/init` は層にする。Xorg が壊れてもトランスポートのテストは走り、失敗はエージェント層に帰属する。
ゲートはそれでもエージェントの受領証不足で fail-closed になる:

1. 基盤: マウント、`modprobe`（`virtio_gpu`、`virtio_input`、`evdev`、`uinput`、`drm`）、
   `mdev -s`、入力イベントのダンプ、そして現在どおり `GUEST ready` と `GUEST monitoring …`。
   コンソール tick は Xorg が表示を持つので落とす。
2. エージェント: `dbus-daemon`、`spice-vdagentd`、modesetting 設定の Xorg、`spice-vdagent`、
   そして `AGENT_STACK_STARTED`。いずれかの段のタイムアウトでは `AGENT_ERROR <理由>` を出し、
   基盤のループは止めない。
3. 観測: クリップボードループが毎秒 2 回 X のクリップボードを読み、変化ごとに
   `CLIPBOARD_OBSERVED bytes=N sha256=…` を記録する。テキストが
   `spice-client host clipboard <token>` の形なら `spice-client guest clipboard <token>` を、
   別の所有者が現れるまで選択を保持する `xclip`（`-loops` 無し。観測ループ自身の読み取りがクライアントの
   要求より先に提供を消費できない）で提供して応答し、`CLIPBOARD_OFFERED <token>` を記録する。
   テキストの後に所有者が無くなった読み取りは `CLIPBOARD_CLEARED` を記録する。xrandr ループは `Virtual-1` の
   推奨モードが変わるたびに適用し、`XRANDR_MODE WxH` を記録する。

`run.sh` は従来どおり `GUEST monitoring` 行を待ち、続いて有界で `AGENT_STACK_STARTED` を待つ。
`AGENT_ERROR` か上限では報告して `SPICE_CLIENT_LIVE_PEER_AGENT=0` のまま続行し、そうでなければ
5 秒 settle して `SPICE_CLIENT_LIVE_PEER_AGENT=1` を書く。`gate.sh` は両スイートを走らせ、8 つの受領証
すべてを要求し、エージェントの受領証をゲストログと順序どおりに照合する。大きな initramfs のため QEMU は
`-m 2048`、コンテナは `--memory 3g` にする。

### 2. エージェントのテストが検証すること

`Tests/SpiceClientTests/LiveAgentTests.swift` は `SPICE_CLIENT_LIVE_PEER_AGENT` で有効になり、
メモリ上のペーストボードに対する注入済み `ClipboardBroker(read:write:)` で `SessionController` を
駆動する。操作者の `NSPasteboard` は読みも書きもしない（アクセスを注入すると vendored パッチは
`SpicePasteboardBridge` にフォールバックしない）。

- **ホスト→ゲスト→ホストを、時間ではなく順序で。** 共有 ON でセッションが操作中のとき、ホスト
  テキスト `spice-client host clipboard <a>` にゲストが応答し、その応答がブローカーの write を通じて
  メモリ上のペーストボードに届く。続いてテストは共有を OFF にし、保留される `<b>` を置き、より新しい
  `<c>` を置き、同じ MainActor ターンで共有を ON に戻す。取り消しは同期なのでどのポーリングも `<b>` を
  読めず、再開は ADR-0001 の意図どおり現在のペーストボード、すなわち `<c>` を提供する。フォーカスの
  喪失と回復でも `<d>`、`<e>` で同じ系列を走らせる。テストは `delivered`/`withheld` の token と計測した
  遅延を受領証に記録し、ゲートは受領証をゲストログと順序どおりに歩いて、届いた token の SHA-256 は
  直前の一致より後に、保留した token の SHA-256 はどこにも無いことを要求する。保留したテキストは一度も
  告知されないので、負の判定は時間に依存しない。クライアントの解放自体はこの系列ではゲスト側で観測
  できない。そのときゲストは自身の応答で選択を保持しているからである。解放メッセージは vendored
  パッチの回帰テストが覆う。
- **リサイズはゲストに届く。同一エージェント接続で 2 回。** `resizingAvailable` が真になったら、
  `resize(width: 1024, height: 768)`、間隔を空けて `resize(width: 1280, height: 800)` を、ゲストが
  それぞれ適用しなければならない。ゲートはゲストログの `XRANDR_MODE 1024x768`、次いで
  `XRANDR_MODE 1280x800` をこの順で要求するので、ゲストが起動時に持っていたモードでは 2 回目を
  満たせない。クライアント側では結果を観測できない（理由は上記 Context の virtio-gpu の件）。
  注入したキーと同様、ゲストログが観測手段である。重要なのは 2 回目の要求で、virtio-gpu では
  モニタ構成に応答が無いため、応答待ちの送信側ならそこで止まる。間隔の待ちは fail-closed である。
  短すぎれば順序検査が通るのではなく落ちる。
- **R7。** クリップボードのテストは、ゲストが最後の応答で X の選択を保持している間にセッションを
  閉じる。`closed` は既存の上限内に到達しなければならない。
- 診断サマリに token もホストも含まれない（カウンタのみのサマリに対する仕掛け線であり、証拠ではない）。

`LivePeerTests`（トランスポート、TLS）は共有ブローカーのまま同じゲストに対して変更なく走る。共有を
有効にしないので、ゲストにエージェントが付いても操作者のペーストボードは読まれない。フレームの assert
（30 秒以内に 1 リビジョン以上）は静的デスクトップでも成り立つ。ゲートは 8 テスト全部の受領証を
要求する。1 セッションでは示せないこと、2 セッション間のゲスト→ゲスト中継の禁止は、ブローカーの
ユニットテストに残す。`Tests/test_live_peer.py` はゲートの新しい検査を fixture で覆う: ログからの
エージェント状態、漏れた保留 token と後の要求を満たしてはならない起動時モード行を含む順序付きの
受領証の歩行、ゲストソース変更時の再ビルド判定。

### 3. 出所と限界

ADR-0002 と同じ: 両イメージ digest 固定、パッケージは固定せず記録、`guest.json` にエージェント
パッケージを列挙、合格記録がそれを埋め込む。対象外: 音声、H.264、Ravada ポータル、ファイル転送、
デスクトップ環境固有のクリップボードマネージャ、USB。

## 実装時の記録（2026-09-18）

設計時に想定していなかった実測が 3 件ある。

1. **クライアントは同時に 1 つ。** QEMU の SPICE サーバーは同時に 1 クライアントしか扱わず、
   `swift test` はスイートを並列に走らせるため、トランスポートのスイートとエージェントのスイートが
   1 つの枠を奪い合い、接続が失敗しフレーム観測が飢えた。ゲートは 2 回の逐次 `swift test` として走らせる。
2. **表示ヘッド 2 つで QEMU が落ちる。** `max_outputs=2` では、エージェントがいる状態で
   クライアントが接続と切断を繰り返す間に QEMU が core を吐いた（exit 139）。`qemu-system-arm`
   8.2.2（Ubuntu 24.04）と 10.0.13（Debian 13）の両方で起きたので版数の問題ではない。
   本アプリが提示するのは単一の表示ストリームなので（ADR-0001 は複数ゲスト表示ストリームを対象外と
   している）`max_outputs=1` にしたところ、連続 11 回ピアは生存した。ADR-0002 フェーズ 1b で 1 度だけ
   記録した原因不明のピア終了も、ほぼ確実にこれである。
3. **2 回目のリサイズは製品の欠陥だった。2026-09-18 に [ADR-0004](0004-display-configuration-liveness.ja.md)
   で修正し、ゲートの固定は肯定的な assert に反転した。** エージェント接続で 2 回目以降の
   `resize` はゲストに届かない。`SpiceDisplayConfigurationState.nextToSend` は構成が in flight の間は
   何も返さず、in flight は `didReceiveReply`、エージェント切断、`stop()` でしか解除されない。
   virtio-gpu では QEMU が `VD_AGENT_MONITORS_CONFIG` を自身の `client_monitors_config` で消費し、
   応答を返さないため、最初のリサイズがエージェント接続の寿命いっぱい送信側を掛け金で止める。その間も
   `resizingAvailable` は真のままなので、操作者には無言の故障になる。修正は vendored バックエンド側の
   話であり、その局所パッチは ADR-0001 がクリップボード権限に限定しているので、広げるかは別の判断だった。
   その判断が ADR-0004 であり、送信窓に期限が入った。ゲートは 1 本目の後に 2 本目のモードが順序どおり
   適用されることを要求する。

4. **音声は検証済み。ただし専用ピアで。** ゲストは `virtio_snd` 経由で無音 PCM を流し（Alpine の virt
   カーネルに HDA ドライバは無い）、ピアはそのフェーズでだけ `-audiodev spice` と `virtio-sound-pci` を
   持つ。セッションの診断サマリに sink 自身のカウンタ由来の `audio_packets` と `audio_frames` を追加した。
   これらは描画コールバックではなくパケットを積む箇所で増えるので、ヘッドレスのテストでも動く。無音は
   意図的で、経路は与えられた PCM を何であれ運ぶため、ゲートを走らせるマシンから音を出さずに済む。
   再生デバイスは、クライアントの接続・切断の反復で QEMU の spice サーバーを落としもする（デバイス
   ありで 12 回中 3 回、無しで 18 回中 0 回、8.2.2。10.0.13 では 5 回中 2 回なので版数の問題ではない）。
   そのため反復の多いスイートはデバイス無しのピアを使い、音声は専用ピアで 1 接続だけ行う。その形なら
   5 回中 5 回クリーンだった。
5. **ファイル転送は検証しない。アプリが実装していないからである。** 依存側には機能があるが、`Sources/`
   には配線が一切無く、README も対象外として挙げている。依存を直接駆動するゲートは upstream のコードを
   証明するだけで本アプリのものを証明しないので、ファイル転送が製品機能になるまでは upstream 自身の
   テストに委ねる。

残件: クリップボードの待ちが 10 秒の上限に 1 度だけ達した（11 回中 1 回、ピアは生存、ログは未保存）。
以後 10 回連続では再現していない。`SPICE_CLIENT_LIVE_PEER_KEEP_LOG=<path>` でゲストログ全体を残せる
ようにしたので、再発時には証拠が残る。

## Consequences

- クリップボードブローカーとリサイズ経路が、参照元クライアントが漏らした境界で、実物の
  `spice-vdagent 0.22` に対して、2 つの取り消し辺（共有 OFF、フォーカス喪失）を含めて検証される。
- ゲスト成果物は 8 MB から約 113 MB に増え、このホストでの起動は 4 秒から 7 秒になる。Xorg が
  可動部に加わるが、層構造の init で Xorg の失敗は帰属可能なまま。ゲートの所要時間は settle 分を
  足してほぼ同じ。
- 実フレーム流は静的デスクトップになる。フレームの assert は 1 リビジョンの閾値を保ち、
  ADR-0002 のコンソール tick の計測値は置き換えられる。

## Alternatives considered

1. **最小ゲストとエージェントゲストの 2 本** — 豊かなフレーム流と、Xorg が壊れたときの
   トランスポートだけの合格を保てるが、成果物 2 組とゲートごとの起動 2 回が要る。層構造の init が
   トランスポートの結果と帰属を起動 1 回で保つ。ゲートはそれでも失敗する。それがゲートの役目である。
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
