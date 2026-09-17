# ADR-0002: 実ピアゲート — Podman 上の QEMU と実物の spice-server（TCG）

| Field | Value |
|-------|-------|
| Status | **Accepted** — 2026-09-18 ユーザー承認。同日、独立の設計検証パスを受けて改訂（改訂注記を参照） |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | v0.1.0 をループバックシミュレーションのみで公開した。QEMU / Ravada の実ピアが無く、ビルド機は upstream の nested virtualization ハーネスを動かせない |

改訂注記（2026-09-18）: 設計検証パスで、`frames_presented` は Metal の描画回数でありヘッドレスの
テストでは 0 のままであること、ゲストが入力デバイスの監視を始める前に注入したキーは失われること、
ゲートが自身の実行を証明できないことが指摘された。下の §1〜§4 は改訂後の本文。改訂前の初回実走で
フレームの指摘は再現していた。

## Context

SPICE に関する検証はすべて `scripts/simulate.py`（セッション確立に必要な範囲だけ
ワイヤプロトコルを話す疑似ピア）に対して行ってきた。これでは、実物の spice-server が
このクライアントのハンドシェイクとチケットを受理すること、実物の表示フレームが Metal
経路に届くこと、注入した入力が実物のゲスト内部に到達することは示せない。
[検証記録](../verification.ja.md)はその旨を明記し、ユーザーはこのギャップを残したまま
v0.1.0 の公開を決めた。

SwiftSpice には Apple/container の中で KVM 付きの nested QEMU ゲストを起動する
ハーネス（`Vendor/SwiftSpice/Integration/AppleContainer`）がある。これは nested
virtualization（M3 以降）を要する。ビルド機は Apple M2 Max で、ローカルの Podman
machine（`podman 6.1.2`、applehv、6 CPU、7.45 GiB）には `/dev/kvm` が無い。
upstream のリモート fixture（`Integration/RemoteRocky`）は KVM を持つ Linux ホストを
前提とするが、そのようなホストは無い。

2026-09-18 の実測（scratch でのスパイク。コミットしていない）:

- upstream の `Containerfile`（`ubuntu:24.04` + `qemu-system-arm` +
  `qemu-system-modules-spice`）は Podman でビルド・実行できた。QEMU 8.2.2
  （`1:8.2.2+ds-0ubuntu1.18`）、`libspice-server1 0.15.1`、`ui-spice-core` /
  `chardev-spice` / `audio-spice` モジュール、アクセラレータとして `tcg` を確認。
- `alpine:3.22` コンテナ内で `linux-virt` パッケージ（カーネル `6.12.110-0-virt`、
  9.6 MB）と刈り込んだモジュール群（3.6 MB。`virtio-gpu`、`virtio_input`、`evdev`、
  `drm`）に Alpine 自身のユーザランドを合わせた 8.4 MB の initramfs を作り、2 回の起動
  とも `podman run` から 4 秒で init のマーカーに到達した。`virtio_pci` と
  `virtio_console` は組み込み。
- upstream の `spice-probe`（vendored パッケージからビルド）は公開ポート経由でチケット付きで
  接続し、8 秒の観測で `frames=113`、6 秒で `frames=90`、`cursors=1`、`keyboard=1`、
  `motion-acks=2`、`gpu-errors=0` を報告した。フレームはゲストが `tty0` に書くコンソール
  出力を virtio-gpu のフレームバッファが描いたもの。
- ゲストに `evdev` を加えた後、ゲストの生イベントダンプに注入した A キー
  （`01 00 1e 00 01 00 00 00`）が現れた。

macOS ネイティブの QEMU は選択肢にならない。Homebrew の `qemu` formula（11.1.1）は
spice 依存を持たず、spice-server バックエンドを含まない。

## Decision

### 1. 配置と構成要素

このリポジトリに `Integration/LivePeer/` を追加する:

- `Containerfile` — digest で固定した `ubuntu:24.04` に `qemu-system-arm` と
  `qemu-system-modules-spice` だけを入れる。
- `build-guest.sh` — digest で固定した `alpine:3.22` の中で動く。`linux-virt` を入れ、
  モジュール群を virtio・DRM・input とその依存に刈り込み、`guest/init` を加えて
  `Artifacts/vmlinuz-virt`、`Artifacts/initramfs.cpio.gz`、`Artifacts/guest.json`
  （カーネル版数、ベースイメージ digest、両成果物の SHA-256）を書く。`Artifacts/` は
  git 管理外。
- `guest/init` — 本プロジェクトの init。upstream の MIT ライセンス init から派生
  （`NOTICE.md` に帰属表記）: マウント、`modprobe`、表示を変化させ続けるための `tty0` への
  tick 出力、`/dev/input/event*` 全部の生ダンプ（hex 行）。
- `run.sh` / `stop.sh` — 実行ごとに `--cpus`、`--memory` 上限付きの detached コンテナを
  1 つ起動し（`stop.sh` が消すまで残す。途中で死んだピアの終了コードとログをゲートが
  報告できるようにするため）、ゲスト成果物を読み取り専用でマウント、SPICE ポートを
  `127.0.0.1` に ephemeral なホストポートで公開して `podman port` で読み戻す（Podman machine
  が前回の転送を保持していても今回のものと取り違えない）。実行ごとの乱数チケットは
  `~/.cache/spice-client/live-peer/` 配下の `0600` ファイルに書き、引数ではなく `secret,file=`
  で QEMU に渡す。QEMU は 30 分の `timeout` の下で動く。準備待ちは 120 秒で打ち切り、コンテナが
  死んだら即座に諦め、`GUEST monitoring /dev/input/event*` の 2 行（evdev はまだ居ない読者の
  ために溜めない）と公開ポートの到達を待つ。ポート、チケット、チケットファイル、コンテナ名は
  テスト用の一時環境ファイルに書く。`stop.sh` はコンテナとチケットファイルを消し、冪等で、
  trap ハンドラも兼ねる。
- `make live-peer` — イメージとゲストが無ければ作り、ピアを起動し、`make test` と同じフラグで
  `swift test --filter LivePeerTests` を実行し、スイートの受領証（各テストが
  `SPICE_CLIENT_LIVE_PEER_RECEIPT` のファイルに自分の名前を追記する。環境変数が無いスイートは
  黙ってスキップされ `swift test` は 0 で終わる）を要求し、ゲストログに注入したキーが含まれる
  ことを要求し、`Artifacts/last-pass.json`（コミット、ツリーが dirty だったか、ゲストと
  イメージの出所）を書き、必ずコンテナを停止する。`make package` は `require-pass.sh` を実行し、
  そのコミットでのクリーンな合格記録が無いリリースを拒否する。`make live-peer-clean` は
  イメージと成果物を消す。
- `lib.sh` は 3 つの検査（ゲストログ、受領証、合格記録）を関数として持ち、
  `Tests/test_live_peer.py` が fixture ファイルで駆動する。成果物が無いとき `run.sh` が Podman に
  触れる前に失敗すること、全スクリプトの構文、digest 固定も検査する。これらは Podman 無しで
  `make test` で走るので、ゲート自身の論理がテストされる。

### 2. ゲートが検証すること

`Tests/SpiceClientTests/LivePeerTests.swift` は `SPICE_CLIENT_LIVE_PEER_PORT` が
設定されているときだけ有効で、probe ではなくアプリ自身の経路
`ConnectionPlan` → `SessionController` → SwiftSpice を駆動する:

- メモリ上で解析した `.vv` テキスト（host `127.0.0.1`、ポート、チケット。ディスクには書かない）で
  接続し、セッションが `connected` に達し、`inputAvailable` が真になる。実物の表示フレームは
  ウィンドウと同じ方法で観測する: セッションの desktop source への visible な購読で異なるフレーム
  リビジョンを数え、30 秒以内に 1 以上になること。`SessionController` の `frames_presented` は
  Metal の描画回数で、ビューが無ければ 0 のままなので使わない。
- テストはゲストが両方の入力デバイスの監視を報告してから A キーの down / up を送り、ホスト側は
  テスト後のゲストログに `01 00 1e 00 01 00 00 00` を要求する。
- 誤ったチケットは実サーバー相手に `failure == .authentication` と `closed` で終わり、
  ピアは次の接続まで生きている。
- `disconnect()` は既存の停止上限内に `closed` に達し、その後同じピアへの 2 本目の
  セッションが接続できる。
- 診断サマリにチケットとホストが含まれない。

音声、H.264、Ravada ポータル、ゲストエージェント（クリップボード、リサイズ）は
このゲートでは検証しない。フェーズ 1b（2026-09-18 実装）: ピアは `tls-port` でも待ち受け、
実行ごとの CA とサーバー証明書をホスト側の `lib.sh` が生成して QEMU の `x509-dir` に読み取り専用で
マウントする。ゲートは `.vv` の `ca` 経路、`ca` + `host-subject` 経路で接続し、囮の CA と誤った
サブジェクトが拒否されてピアが生き残ることを示す。フェーズ 2 のエージェント付きゲスト（upstream と同様に Alpine パッケージの Xorg と
`spice-vdagent`）は、フェーズ 1 を 1 リリース分運用してから別途決める。その際は upstream の
スクリプトが既定にしている第三者ミラーではなく、Alpine 公式 CDN から取得する。

### 3. 出所の記録

両ベースイメージは使用するファイル内で digest 固定し、`check-project.py` は
`Integration/` 配下のすべての `docker.io` 参照に `@sha256:` を要求する。ベース層より上の
パッケージは固定しない。`apt` も `apk` も安定版では現行版しか置かないため、固定すると数週間で
壊れる。代わりに記録する: `Artifacts/image.json` にイメージ ID とビルド済みイメージから読んだ
`qemu-system-arm`、`qemu-system-modules-spice`、`libspice-server1` の版、`Artifacts/guest.json` に
カーネルパッケージと両ゲスト成果物の SHA-256。合格記録は両方を埋め込むので、どの結果も相手にした
ソフトウェアに紐付けられる。成果物はコミットせず、イメージはレジストリに push しない。

### 4. 運用と安全

コンテナがマウントするのは成果物ディレクトリ、チケットファイル、TLS 素材だけ（すべて読み取り専用）、
公開はループバックのみ、trap による停止が除去する（`-no-reboot` でゲストの再起動時に QEMU は終了）。
trap は SIGKILL やホストのスリープでは走らないため、上限が 2 つある: QEMU は 30 分の `timeout` の下で動き、
ゲートと同名の古いコンテナは次回起動時に除去される。チケットは 1 回の実行のチケットファイルと
環境ファイルにだけ存在し（いずれもリポジトリ外で停止時に削除）、コンテナのコマンドラインには
現れない。コンテナ内で QEMU は `0.0.0.0` にバインドする。これは Podman machine のポート転送に
必要で、ホスト側の公開は `127.0.0.1` であることをこのホストの `lsof` で 1 回確認した。machine VM
内の他コンテナからは到達しうるが、このゲートの脅威モデルの外とする。

このゲートは `make test` の一部ではない。Podman と 1 分程度の CPU を要する。`make package` は
リリースコミットの合格記録を要求し、結果はシミュレーション結果と並べて検証記録に載せる。

## Consequences

- トランスポート、チケット、表示、カーソル、入力、停止の各経路で、疑似ピアの代わりに
  実物の spice-server と実物の Linux ゲストが相手になる。README の相互運用の記述は
  「未検証」から「QEMU 8.2 / spice-server 0.15 と最小ゲストに対して検証済み」に変わる。
  Ravada でもデスクトップゲストでもない点は変わらない。
- Podman がこのゲート、したがって `make package` の開発依存になる。TCG はハードウェア支援を
  要しない。このホストではゲストが 2 回中 2 回とも 4 秒でマーカーに達し、毎秒数十フレームを
  届けた。テストの待ち時間はその 10 倍に取ってある。他のホストでも動く見込みだが未計測。
- ゲスト成果物（約 18 MB）は必要時に再生成し、リポジトリにもリリースにも含めない。
- 本アプリが参照元と最も異なるクリップボードブローカーとリサイズ経路は、フェーズ 2 まで
  シミュレーションのみのまま。

## Alternatives considered

1. **upstream の Apple/container ハーネス** — nested virtualization（M3 以降）と
   Apple/container を要し、ビルド機では動かない。再利用するのはゲスト init の複製だけで、
   スクリプトは呼ばない。`Vendor/` 配下に書き込み、そのファイル集合は `check-project.py` が
   ハッシュ検査するからである。
2. **KVM 付きリモート Linux ホスト**（upstream の `RemoteRocky` fixture）— そのような
   ホストは無い。用意するのはインフラ整備であってテストではない。
3. **macOS ネイティブの QEMU** — Homebrew formula に spice-server バックエンドが無く、
   macOS 向けにパッケージされた spice-server も無い。
4. **UTM 等のデスクトップハイパーバイザ** — 自前の表示用に Unix ソケット上の SPICE を
   同梱する。TCP リスナーを出すには独自引数が要り、アプリ自身のサーバーと競合する。未計測。
   手動で機体依存になるためゲートとしては不採用。
5. **シミュレーションのみを継続** — 現状。実サーバーがこのクライアントを受理するかには
   答えられない。

## References

- [ADR-0001](0001-native-client-port.ja.md) §8 段階 6（実ピア）と
  [検証記録](../verification.ja.md)。
- [SwiftSpice Apple/container ガイド](../../../Vendor/SwiftSpice/Integration/AppleContainer/APPLE_CONTAINER.md)
  とそのゲスト init（MIT で再利用）。
- [Testing](https://github.com/nlink-jp/knowledge/blob/main/docs/ja/testing.md):
  全緑のユニットテストにも実データ E2E が要る。手動でしか走らないゲートには自身のテストが要る。
  「計測済み」と言う前にプローブ入力が実物を代表するかを問う。
- [Containers and infrastructure](https://github.com/nlink-jp/knowledge/blob/main/docs/ja/containers-and-infra.md):
  Podman machine はコンテナ内 `0.0.0.0` バインド、公開ポートはホスト側で転送。
- pcap-analyzer-mcp ADR-0003: digest 固定のベースイメージとドリフトテスト。組織の Podman
  ランタイムの先例。
