# spice-client

Spice Client は、`.vv` 接続ファイルと HTTPS の Ravada ポータルから仮想デスクトップを開く
macOS アプリです。spice-mac のアプリ本体を、接続内容の明示的な確認を中心に再設計しました。
プロトコル、画面、入力、音声、ゲスト連携には SwiftSpice を継続利用しています。

[English](README.md)

## インストール

macOS 向けリリースは **Developer ID 署名と Apple 公証（staple 済み）**を施しています。
Gatekeeper の警告なしに起動し、オフラインでも動作します。

```sh
brew tap nlink-jp/tap
brew install --cask nlink-jp/tap/spice-client
```

または [Releases](https://github.com/nlink-jp/spice-client/releases) から
`spice-client-vX.Y.Z-darwin-arm64.zip` をダウンロードして展開し、`Spice Client.app` を
アプリケーションフォルダへ移動してください。

## 状態

Spice Client は Apple Silicon / macOS 26 以降を対象とします。接続、チケット、表示フレーム、カーソル、
キーボード入力、停止は、`make live-peer` により実物の spice-server（QEMU 8.2、spice-server 0.15）と
Xorg と spice-vdagent が動く Linux ゲストに対して検証しています。同じゲートで、共有とフォーカスの変化を
伴う双方向のクリップボード共有、リサイズ経路、音声再生も検証します。ポータルの境界はループバック
シミュレーションで検証しています。Ravada ポータル、デスクトップ環境のクリップボードマネージャ、H.264 は
未検証です。実施範囲と限界は[検証記録](docs/ja/verification.ja.md)を参照してください。

## 使い方

1. Spice Client を開きます。
2. `.vv` ファイルを開くかドロップします。ポータルの場合は HTTPS URL を入力してログインします。
3. アプリ側の確認画面で送信元、接続先、ポート、通信の保護を確認します。
   クリップボード共有は初期 OFF です。「接続」で表示された内容への接続を開始します。
4. 接続ごとに専用ウィンドウが開きます。「セッション」メニューから Ctrl-Alt-Delete、
   入力捕捉の解除、フルスクリーン、切断を操作できます。ウィンドウを閉じると通信を閉じ、関連資源を解放します。

平文 TCP、システム検証による TLS、`.vv` 内の認証局および任意の証明書サブジェクトを使った TLS に対応します。
不正な TLS 指定、未対応の必須設定、曖昧なファイルは、暗号化を弱めずエラーにします。
ファイルは UTF-8 の通常の `.vv` ファイル、上限 1 MiB です。シンボリックリンクは拒否します。
無効ポートは `-1` と指定でき、有効な TLS ポートがある場合はそちらを優先します。

ポータルからの引き渡しはメインフレームと、ポートを含む同一 HTTPS origin に限定します。
リダイレクトごとに Cookie を再選別します。自動遷移やフォーム送信で候補が表示されても、接続は承認されません。
拡張子のないダウンロード URL は未対応です。`.vv` を保存して手動で開いてください。
自己発行のポータル証明書は、フィンガープリントを確認して、そのポータルウィンドウの間だけ承認できます。
その場合も接続先名と有効期限の検証を行います。

クリップボードはテキスト共有で、操作対象のセッションウィンドウだけが利用できます。
共有解除は実際の読み書き時にも確認し、あるゲストから受け取った内容を別ゲストへ自動中継しません。
新たにローカルでコピーした内容は共有できます。
設定で、選択した接続ファイルを**接続成功後**にゴミ箱へ移すことができます（初期 OFF）。
変更・差し替えされたファイルは保全します。ポータル経由の接続ファイルはメモリ内で扱います。
ポータルのログイン情報は Maspice と別の保存領域を使い、設定から消去できます。
旧設定や保存済み SPICE パスワードの移行は行いません。

ゲストエージェントが対応していれば表示領域の大きさを解像度へ反映します。
音声はサーバーが提示する再生チャンネルを利用します。高度な映像形式の初回表示前にコーデックが利用不能になった場合、
MJPEG で一度だけ再接続します。診断情報は任意に有効化する集計値で、認証情報、入力キー、クリップボードの内容、
画面内容は集計に含めません。英語・日本語の UI を用意しています。

自動更新、USB 転送、マイク入力、WebDAV 共有、プロキシ接続、複数ディスプレイストリーム、Intel ビルドは含めません。

## ビルドとテスト

Apple Silicon、macOS 26 以降、Swift 6.3 以降の Xcode、Metal Toolchain、Python 3 が必要です。
シミュレーションには OpenSSL も使用します。`make doctor` は実際に Metal シェーダーをコンパイルします。
実行ファイルの代理コマンドが存在するだけでは成功扱いにしません。

```sh
make doctor
make test          # アプリ回帰、依存関係の出所、文書リンク、不正 ZIP の拒否
make test-vendor   # SwiftSpice の全テスト。共有 fixture の競合を避けて順次実行
make simulate      # 実 WebKit、ローカル HTTPS、SPICE 通信の疑似サーバー
make live-peer     # Podman 上の QEMU（TCG）で実物の spice-server + spice-vdagent 付きゲスト
make build         # dist/Spice Client.app を作成。ローカル用のアドホック署名
open "dist/Spice Client.app"
```

`make simulate` は一時的なループバック接続先、短命の合成証明書とチケットを作ります。
VM は不要で、システムの信頼設定を書き換えず、利用者の実クリップボードにもアクセスしません。
アプリには `.vv` パスを引数でも渡せます。`--version`、`--resource-check`、`--smoke-test`、
`--portal-smoke=<https url>`（そのバンドルでポータルを開き、WebKit が描画したかを報告）はローカル検証用です。
`make live-peer` には起動済みの Podman machine が必要です。初回に QEMU イメージと小さな Alpine ゲスト
（約 18 MB、git 管理外）を作り、SPICE をループバックだけに公開するコンテナを実行ごとのチケット付きで
1 つ起動し、アプリ自身のセッション経路で平文 TCP と TLS（実行ごとの認証局による `.vv` の `ca` と
`host-subject` 経路。誤った認証局の拒否を含む）の両方で接続し、注入したキーがゲストに届いたことを
確認し、共有とフォーカスの変化を伴ってゲストの spice-vdagent とクリップボードのテキストを交換し、
ゲストの表示をリサイズし、2 つ目のピアでゲストの無音ストリームから音声再生を受け取ってから、
コンテナを停止します。H.264 と Ravada ポータルは対象外で、ファイル転送は本アプリの機能ではありません。
`make package` は、そのコミットで `make live-peer` が（クリーンなツリーで）合格した記録が無ければ拒否します。
独自アイコンの再生成は `swift scripts/create-icon.swift`、続いて
`iconutil -c icns dist/AppIcon.iconset -o Resources/AppIcon.icns` を実行します。

`make package` は別途実施するリリース操作です。組織の署名スクリプトによる Developer ID 署名と
公証成功が必要で、アドホック署名へ切り替えて成功扱いにはしません。
`make verify-release` は最終 ZIP 自体を展開し、アプリ ID、版数、署名、公証チケット、Metal リソース、
バイナリがリンクされた macOS SDK を確認します。`make build` はインストール済み SDK を明示してリンクし、
それ以外の結果を拒否します。古い SDK にリンクされたアプリは、macOS が旧世代のウィンドウ外観で描画するためです。
ローカルビルドを公証済みリリースとして配布しないでください。

## 構成とレビュー

- `ConnectionCore`: 変更不能な `.vv` 解析結果、origin と Cookie の規則。
- `SessionCore`: 一度限りの接続承認とセッションの状態。
- `SwiftSpiceAdapter`: 通信の所有・終了、順序付き入力、クリップボード管理。
- `SpiceClient`: ネイティブウィンドウ、ポータル、ファイル入力、設定、言語切り替え。
- `Vendor/SwiftSpice`: v0.4.2 固定版と、クリップボード実アクセス境界およびモニタ構成の送信窓に
  関する 2 本の局所パッチ。

[承認済み設計](docs/ja/adr/0001-native-client-port.ja.md) ·
[元プロジェクト全76ファイルの対応表](docs/ja/source-map.ja.md) ·
[レビューと修正](docs/ja/review.ja.md) ·
[検証](docs/ja/verification.ja.md)

## ライセンス

アプリ本体は MIT です（[LICENSE](LICENSE)）。[Maspice](https://github.com/BeriBeli/spice-mac)（Ching367436 / BeriBeli）から
仕様と一部の互換処理を継承し、[SwiftSpice](https://github.com/BeriBeli/spice-swift)を利用しています。
[NOTICE.md](NOTICE.md)、[依存ライセンス](THIRD_PARTY_NOTICES.md)、`Vendor/` の固定ファイルハッシュとパッチを参照してください。
LGPL を含むネイティブライブラリのライセンスはそのまま維持し、MIT への変更はしていません。
