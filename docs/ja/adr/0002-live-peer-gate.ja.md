# ADR-0002: 実ピアゲート — Podman 上の QEMU と実物の spice-server（TCG）

| Field | Value |
|-------|-------|
| Status | Proposed |
| Date | 2026-09-18 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | v0.1.0 をループバックシミュレーションのみで公開した。QEMU / Ravada の実ピアが無く、ビルド機は upstream の nested virtualization ハーネスを動かせない |

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
- `run.sh` / `stop.sh` — 実行ごとに `--rm`、`--cpus`、`--memory` 上限付きの
  detached コンテナを 1 つ起動し、ゲスト成果物を読み取り専用でマウント、SPICE ポートを
  `127.0.0.1` だけに公開、実行ごとの乱数チケットを QEMU の secret object として渡す。
  リスナーとゲストマーカーを待ち、ポートとチケットをテスト用の環境変数として出力する。
  `stop.sh` は冪等で、trap ハンドラも兼ねる。
- `make live-peer` — イメージとゲストが無ければ作り、ピアを起動し、環境変数付きで
  `swift test --filter LivePeerTests` を実行し、ゲストログに注入したキーが含まれることを
  要求し、必ずコンテナを停止する。`make live-peer-clean` はイメージと成果物を消す。

### 2. ゲートが検証すること

`Tests/SpiceClientTests/LivePeerTests.swift` は `SPICE_CLIENT_LIVE_PEER_PORT` が
設定されているときだけ有効で、probe ではなくアプリ自身の経路
`ConnectionPlan` → `SessionController` → SwiftSpice を駆動する:

- 生成した `.vv`（host `127.0.0.1`、ポート、チケット）が解析でき、セッションが
  `connected` に達し、`inputAvailable` が真、`desktop` が存在し、診断カウンタ
  `frames_presented` が有限の待ち時間内に増える。
- テストは A キーの down / up を送り、ホスト側はテスト後のゲストログに
  `01 00 1e 00 01 00 00 00` を要求する。
- 誤ったチケットは実サーバー相手に `failure == .authentication` と `closed` で終わり、
  ピアは次の接続まで生きている。
- `disconnect()` は既存の停止上限内に `closed` に達し、その後同じピアへの 2 本目の
  セッションが接続できる。
- 診断サマリにチケットとホストが含まれない。

音声、H.264、Ravada ポータル、ゲストエージェント（クリップボード、リサイズ）は
このゲートでは検証しない。フェーズ 1b で TLS リスナー（コンテナ起動時に生成し読み取り
専用で書き出す CA を使う `tls-port`）を加え、`.vv` の CA 経路を実サーバー相手に通す。
フェーズ 2 のエージェント付きゲスト（upstream と同様に Alpine パッケージの Xorg と
`spice-vdagent`）は、フェーズ 1 を 1 リリース分運用してから別途決める。

### 3. 出所の記録

両ベースイメージは使用するファイル内で digest 固定し、`check-project.py` は
`Integration/` 配下のすべての `FROM` 行に `@sha256:` を要求する。カーネル版数は
Alpine 3.22 の `linux-virt` に追随して変わる。ビルドは生成物を `Artifacts/guest.json`
に記録し、ゲートはそれを表示するので、どの結果もカーネルに紐付けられる。成果物は
コミットせず、イメージはレジストリに push しない。

### 4. 運用と安全

コンテナがマウントするのは成果物ディレクトリだけ（読み取り専用）、公開はループバックのみ、
実行と共に消える（`--rm`、trap による停止、QEMU の `-no-reboot`）。同名の古いコンテナは
起動前に除去するので、中断された実行が CPU を食い続ける孤児 QEMU を残せない。チケットは
1 回の実行のプロセス環境にだけ存在し、リポジトリ配下には書かない。コンテナ内で QEMU は
`0.0.0.0` にバインドする。これは Podman machine のポート転送に必要で、ホストの外からは
到達できない。

このゲートは `make test` の一部ではない。Podman と 1 分程度の CPU を要する。リリース前に
実行し、結果はシミュレーション結果と並べて検証記録に載せる。

## Consequences

- トランスポート、チケット、表示、カーソル、入力、停止の各経路で、疑似ピアの代わりに
  実物の spice-server と実物の Linux ゲストが相手になる。README の相互運用の記述は
  「未検証」から「QEMU 8.2 / spice-server 0.15 と最小ゲストに対して検証済み」に変わる。
  Ravada でもデスクトップゲストでもない点は変わらない。
- Podman がこのゲートに限った任意の開発依存になる。TCG はこのゲストには十分速く
  （マーカーまで 4 秒、毎秒数十フレーム）、ハードウェア支援を要しないので、Podman のある
  Apple silicon 機ならどこでも動く。
- ゲスト成果物（約 18 MB）は必要時に再生成し、リポジトリにもリリースにも含めない。
- 本アプリが参照元と最も異なるクリップボードブローカーとリサイズ経路は、フェーズ 2 まで
  シミュレーションのみのまま。

## Alternatives considered

1. **upstream の Apple/container ハーネス** — nested virtualization（M3 以降）と
   Apple/container を要し、ビルド機では動かない。ゲストイメージとスクリプトは使える範囲で
   再利用する。
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
