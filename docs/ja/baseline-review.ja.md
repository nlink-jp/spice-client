# spice-mac / Maspice レビュー

レビュー日: 2026-09-17

追補: 同日、Metal Toolchain導入後に全体テストと配布用ビルドを再実行。いずれも成功。主要な指摘7件は未修正。

対象: `spice-mac ローカル作業コピー`、Maspice 0.5.4、commit `4631b0cf43032671fe01e994db5613e78a91037a`。

## 評価

確認したソースに、意図的なバックドア、隠れた第三者への情報送信、永続化処理、ダウンロードしたコードの無断実行を示す根拠は見つからなかった。一方、ユーザー操作判定の回避、既知の脆弱性を含む更新ライブラリ、ポータルとTLSの信頼境界の不備、切断処理の停止を確認した。現状を「安全性に問題なし」と評価することはできない。

主要な指摘は7件。P1は優先修正、P2は通常の修正対象を意味し、CVSSの重大度ではない。以下では、実装を実行して確認した事実、模擬環境での再現、外部の公式アドバイザリを区別する。

## 主要な指摘

### R1 — P1: JavaScriptによる自動遷移がユーザー操作と判定される

対象: [RavadaNavigationDecider.swift:209](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/RavadaNavigationDecider.swift#L209)

`isUserInitiated` は `.formSubmitted` 等を無条件に許可し、`.other` では `buttonNumber == 0` を実クリックの証拠にしている。しかし、ユーザー入力を一切与えず `window.onload` から遷移させても、WebKitはこの値を返す。

アプリと同じ `WebPage` API、実際の `RavadaNavigationDecider.isUserInitiated` を用いた再現結果:

```text
window.location.href による自動遷移:
  type=-1 (.other), button=0, main=true, host=portal.example
  ACTUAL isUserInitiated=true allowedURL=true
form.submit() による自動送信:
  type=1 (.formSubmitted), button=0, main=true, host=portal.example
  ACTUAL isUserInitiated=true allowedURL=true
```

その後の処理には別のユーザー確認がなく、ダウンロードした `.vv` は `openDownloadedConnection` → `SessionModel.start` に渡される。ポータル上の悪意あるスクリプトやXSS等により、選択していないSPICE接続を開始できる。接続先が成立すれば、既定で有効なクリップボード共有にも影響する。任意コード実行を実証したものではない。

**修正方針:** `buttonNumber` や遷移種別だけを承認根拠にしない。公開APIで信頼できるユーザー操作を証明できない場合は、ネイティブ側で接続先を示して接続承認を取る等、Webコンテンツだけでは成立しない承認境界を設ける。自動フォーム・自動location変更を拒否する動作テストを追加する。

### R2 — P1: Sparkle 2.9.4が既知の脆弱性の対象

対象: [Package.swift:17](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Package.swift#L17)、[Package.resolved](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Package.resolved)

自動更新用のSparkleが2.9.4に固定されている。2026-09-17時点の公式情報では、次の修正を含まない。

| アドバイザリ | 対象と修正版 | 悪用条件・影響 |
|---|---|---|
| [GHSA-3x7w-j75x-ppq5](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5) | 2.9.5以下、2.9.6で修正 | ローカルでパスを差し替える競合。システム領域の更新など、インストーラーがrootで動く場合に保護されたファイルの移動や権限昇格につながる。ファイル名等の追加条件がある。 |
| [GHSA-gmj2-gq3j-vqmj](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-gmj2-gq3j-vqmj) | 2.9.4以下、2.9.5で修正 | 署名検証を通る悪意ある差分更新が必要。盗まれた署名鍵等が前提で、通常のネットワーク攻撃だけでは成立しない。展開先外のファイル上書き。 |
| [GHSA-4v99-qgq9-6pxp](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp) | 2.2.0〜2.9.5、2.9.6で修正 | 更新元のCLI/デーモン自体がrootで動く場合のキャッシュ処理。通常ユーザーで起動するMaspiceに、その条件が当然成立するわけではない。 |

アプリはEdDSA公開鍵を持ち、展開前検証も有効。この点は適切だが、上記の修正済み脆弱性を残す理由にはならない。今回、権限昇格や悪意ある更新の実行は行っていない。

**修正方針:** 少なくとも2.9.6相当の修正を含む版へ更新し、固定リビジョン・ライセンス記載・更新動作を確認する。2.9.6の修正内容は[公式リリース](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6)に記載されている。

### R3 — P2: same-originの判定にポートと送信元スキームが含まれない

対象: [RavadaNavigationDecider.swift:197](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/RavadaNavigationDecider.swift#L197)、同ファイル204行・259行付近。

設定URLから保持するのはホスト名のみ。ダウンロード先はHTTPS＋ホスト名、送信元はメインフレーム＋ホスト名、リダイレクト先もHTTPS＋ホスト名しか比較しない。

実際の判定を呼んだ結果、設定が `https://portal.example/` でも `https://portal.example:8443/test.vv` は許可された。別ホストとHTTP宛ては拒否された。同じホストで動く別ポートのアプリを、設定したポータルと同等に扱ってしまう。READMEの「same-origin」という説明とも一致しない。

**修正方針:** 設定URLのscheme・正規化したhost・実効portを保持し、送信元、最初のダウンロード先、全リダイレクトで同じ判定を使う。なお、HTTP Cookie自体はポートで分離される仕組みではないため、これは主にネイティブ接続への引き渡し許可範囲の問題である。

### R4 — P2: リダイレクト後にCookieのパス制限が適用されない

対象: [RavadaNavigationDecider.swift:121](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/RavadaNavigationDecider.swift#L121)、[同:259](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/RavadaNavigationDecider.swift#L259)

最初のURLにはCookieのdomain・path・secure・expiryを照合するが、Cookieヘッダーを手動で設定し、自動Cookie処理を無効にした後、リダイレクト要求をそのまま許可する。移動先での再選別がない。

実際の `PortalURLSessionDelegate` とループバックHTTPSサーバーで、`/private/session.vv` → `/public/final.vv` の302リダイレクトを実施した。最初のパスにのみ適用すべき合成Cookieが、最終サーバーで以下のように受信された。

```json
{"path": "/public/final.vv", "cookie": "review_only=synthetic"}
```

アプリの `cookie(appliesTo:)` 自体は、このCookieについて初回URLをtrue、最終URLをfalseと判定する。問題はその判定がリダイレクトに使われないこと。CookieのPathは一般的な同一オリジン内の完全なセキュリティ境界ではないが、通常は送られない別パスのサーバー処理へ認証情報を渡す挙動になっている。

**修正方針:** 各リダイレクトで既存のCookieヘッダーを消し、移動先URLと現在時刻に対して許可Cookieを再構築するか、必要なCookieだけを専用の一時ストアで管理する。ログインCookieの更新が必要なリダイレクトもテストする。

### R5 — P2: 不正なTLSポート指定が平文接続へ切り替わる

対象: [VVConfig.swift:190](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/VVConfig/Sources/VVConfig/VVConfig.swift#L190)、[同:235](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/VVConfig/Sources/VVConfig/VVConfig.swift#L235)、[SpiceClient.swift:541](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/SpiceController/Sources/SpiceController/SpiceClient.swift#L541)

不正な `tls-port` が「指定なし」のnilに変換される。有効な `port` が残っていれば検証が通り、`makeEndpoint` はTLSなしを選ぶ。

実装を用いた再現:

```text
port=5900 + tls-port=5901  -> validated=true, isTLS=true,  selectedPort=5901
port=5900 + tls-port=oops  -> validated=true, isTLS=false, selectedPort=5900
port=5900 + tls-port=65536 -> validated=true, isTLS=false, selectedPort=5900
```

条件は、カスタムCA・host-subjectがなく、平文portが有効なファイル。CAが指定されているケースは別の検証により拒否される。平文接続自体はサポート仕様だが、TLS指定の入力エラーを通知せず平文に変える点が問題。

**修正方針:** 未指定、仕様上の無効化値、構文不正・範囲外を区別する。TLSポートの不正値はエラーとして接続を止める。

### R6 — P2: `secure-channels` の暗号化要求を黙って無視する

対象: [VVConfig.swift:242](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/VVConfig/Sources/VVConfig/VVConfig.swift#L242)、[SpiceConnectionParameters.swift:43](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/VVConfig/Sources/VVConfig/SpiceConnectionParameters.swift#L43)

`raw` に未知のキーを保存するだけで、セキュリティ上重要な `secure-channels` を検証も拒否もしない。TLSポートがなくても、次の入力から平文接続パラメーターを生成できた。

```ini
[virt-viewer]
type=spice
host=example.invalid
port=5900
secure-channels=main;display;inputs
```

結果: `accepted=true, isTLS=false`。

`secure-channels` は暗号化するチャネルの指定である。[virt-viewer公式マニュアル](https://gitlab.com/virt-viewer/virt-viewer/-/raw/master/man/remote-viewer.pod)

**修正方針:** 対応するなら暗号化要求を保証する。未対応なら、proxyやhost-subjectと同様に明示的に拒否する。安全性に関わる他の未対応キーも一覧化し、「保存したから検証した」と扱わない。

### R7 — P2: 入力送信が詰まると実際の切断に到達できない

対象: [SpiceClient.swift:173](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/SpiceController/Sources/SpiceController/SpiceClient.swift#L173)、[OrderedSpiceInputPump.swift:81](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Packages/SpiceController/Sources/SpiceController/OrderedSpiceInputPump.swift#L81)

`disconnect` は表示上の状態を先に切断済みにするが、非同期後処理は `oldInputPump.shutdown()` → Agent停止 → 音声停止 → `session.disconnect()` の順。`shutdown` は送信中タスクの終了を上限なしで待つ。

送信先がデータを受け取らずsendが停止した場合、そのsendを中断するために必要なセッション切断まで進めない。Agentと音声の停止も後回しになる。同様の待機は失敗処理・コーデック再接続にもある。

実際の入力ポンプに制御可能な模擬sendを注入した結果:

```text
blocked send: reached transport disconnect=false
after teardown cancellation: reached transport disconnect=false
after send released: reached transport disconnect=true
```

入力ポンプの本体はそのまま使用し、SwiftSpiceの型と診断出力は最小スタブに置き換えた。実ネットワークの停止やアプリのウィンドウ操作による再現は未実施である。上流の送信経路がNetwork接続のsendをawaitすることはソースで確認した。

**修正方針:** キー解放の送信は有限時間のbest effortとし、時間切れでは送信を打ち切ってトランスポートを閉じる。クリップボード等のホスト連携は、詰まった入力の完了を待たずに無効化する。停止したsendとキャンセルを含む回帰テストを追加する。

## 軽微な不具合・保守性

### P3: 「接続後にTrashへ移す」が接続開始直後に実行される

[SessionModel.swift:80](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Sources/Maspice/SessionModel.swift#L80) は、非同期接続を開始する `client.connect()` の直後にファイルをTrashへ移す。認証失敗や到達不能でも元の場所からファイルがなくなり、再試行しにくい。ユーザーが選択したファイルのTrash移動は `.connected` 到達後に一度だけ実行するのがUI説明に合う。短命チケットを含むポータル一時ファイルの即時削除は、別のポリシーとして維持できる。

### P3: doctorがMetal Toolchainを誤って利用可能と判定する

[doctor.sh:40](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/scripts/doctor.sh#L40) は `xcrun -f metal` で得た実行ファイルの存在だけを見る。初回レビュー時（Metal Toolchain導入前）は転送用の実行ファイルが存在するためdoctorが成功表示した一方、make test / make buildは実際のMetal Toolchainが利用できず失敗した。導入後の再実行ではテスト・ビルドとも成功しており、現在の環境の阻害要因は解消した。ただしdoctorの判定コード自体は変更していない。上流のビルド用スクリプト同様、コンパイラを起動できるかまで確認すべき。

### P3: 同梱ライセンス文書の依存バージョンが古い

[THIRD-PARTY-LICENSES.txt:10](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/THIRD-PARTY-LICENSES.txt#L10) と同文書の再ビルド手順への参照はSwiftSpice 0.2.4のまま。実際には0.4.2で、文書はアプリにコピーされる。監査・依存特定の際に誤った版を案内する。法的な適合性の判定をしたものではなく、バージョン記載の不整合としての指摘。

### テストが実装文字列に依存する範囲が広い

[SwiftUICommandRegistrationTests.swift:403](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/Tests/MaspiceTests/SwiftUICommandRegistrationTests.swift#L403) は、ポータルの安全性についても `source.contains(...)` を多数使い、問題のある `action.buttonNumber == 0` という文字列の存在を要求している。構成の重複防止には一部有効だが、認可・Cookie・リダイレクトの挙動を保証しない。今回のR1・R3・R4を実際に拒否できる動作テストへ置き換える優先度が高い。

### リリースの品質保証が手作業に依存する

[release.sh:62](https://github.com/BeriBeli/spice-mac/blob/4631b0cf43032671fe01e994db5613e78a91037a/scripts/release.sh#L62) はビルドとバージョン検証を行うが、make testや公開対象commitのCI成功確認を実行しない。READMEが別途要求する実機・クリーン環境テストも自動的な公開条件ではない。アドホック署名・公証なしの配布はREADMEでも明示されており、不審な隠し挙動ではないが、一般配布の保証は限定される。最低限、公開前のテスト成功をリリース手順自身で確認できるとよい。

## 良い実装

- UI、接続制御、設定パーサー、ライフサイクルを分離している。入力ポンプにはsendの注入点があり、今回の停止状態を実機なしで検証できた。
- `.vv` のディスク読込とHTTP受信を1 MiBに制限し、UTF-8・ポート範囲・カスタムCAの前提条件を検査する。単純なproxy指定は明示的に拒否する。
- TLS接続の構築ではsystem / per-file CA / host-subjectポリシーを使い分け、アプリから上流の `insecureForTestingOnly` を選ぶ経路は見つからない。
- 診断出力は固定した項目と集計値を中心とし、パスワード、クリップボード本文、入力内容、画面ピクセルを出力する処理は確認されなかった。
- 依存の版とリビジョンを固定し、Sparkleのバイナリ配布にもチェックサムがある。SwiftSpiceのネイティブ依存には元ソースのURL・ハッシュ・再ビルド手順がある。
- ビルド成果物のライブラリ参照を検査し、Homebrew等の絶対パスを後から書き換えて問題を隠す処理はない。ただし、この監査だけで依存ファイルの完全な存在確認や起動成功まで保証するものではない。

## 不審なコードの確認範囲

76の追跡ファイルから構成を確認し、アプリ・ローカルパッケージの実装、テスト、全シェルスクリプト、CI、Info.plist、更新設定、主要ドキュメントを調査した。実行・通信・永続化・ログ・Cookie・クリップボード・ファイル操作の入口を検索し、関連コードを追跡した。

確認された通信先は、設定したRavadaポータル、接続ファイルで指定するSPICEサーバー、GitHub上の更新・ヘルプ・依存取得先。常駐登録、ホストの任意コマンド実行、隠れた分析サービスへの送信を示す処理は、Maspice本体には見つからなかった。公開鍵は更新検証用であり、秘密鍵ではない。追跡ファイルの限定的なパターン検査でも、秘密鍵・典型的なGitHubトークン・AWSアクセスキー・curl-to-shell・LaunchAgent/Daemon登録は検出されなかった。

取得したSwiftSpice 0.4.2では、パッケージ構成、ビルドプラグイン、ネイティブ依存のビルド手順、TLS、セッション送受信、Agent・クリップボード・音声の関連経路を追加確認した。上流の試験用SSHコード等は別の実行ターゲットにあり、Maspice本体の隠れた送信処理と混同していない。

ただし、SwiftSpice全ソースの完全監査、同梱Cバイナリの逆アセンブル・元ソースとの再現ビルド比較、全Git履歴の秘密情報監査、公開済みZIPのソース一致確認は行っていない。したがって「悪意あるコードが絶対に存在しない」との保証ではない。

## 実行した確認

環境: Apple Silicon、macOS 27.0、XcodeのSwift 6.4 / macOS 27 SDK。

| 確認 | 結果 |
|---|---|
| 依存解決 | 成功。SwiftSpice 0.4.2、Sparkle 2.9.4。追跡ファイルの変更なし。 |
| make test 内のVVConfig | 28項目成功。20,000入力の決定的なファズ試験を含む。 |
| make test 内のSpiceSessionLogic | 4テスト成功。 |
| make test のアプリ全体 | Metal Toolchain導入後の再実行で39テスト・4スイート成功。VVConfig 28項目、SpiceSessionLogic 4件を含むmake test全体が終了コード0。 |
| Cookie有効期限の既存テスト | 元ソースとテストを変更せず一時パッケージへコピーし、9テスト成功。WebKitストアの全ライフサイクル試験ではない。 |
| make build | 導入後の再実行で成功。Metalコンパイル、アプリ組立て、組立て前後の動的ライブラリ監査、アドホック署名とcodesignのdeep/strict検証、ZIP・SHA-256ファイル生成まで完了。 |
| make doctor | 成功。導入後は権限のある環境でコンポーネントのinstalled状態と実コンパイル成功も確認。導入前の誤判定は上記のとおり。 |
| make check-version | 成功。 |
| shellcheck --severity=warning -x scripts/*.sh | 成功。 |
| 実際のWebPage＋許可判定 | R1・R3を再現。通信は判定後にキャンセル。 |
| 実際のURLSessionデリゲート＋一時HTTPSサーバー | R4を再現。127.0.0.1と合成Cookieのみ使用。サーバーは停止済み。 |
| 実際のVVConfig＋接続パラメーター | R5・R6を再現。実サーバーへの接続なし。 |
| 入力ポンプ＋停止可能な模擬send | R7を再現。上流の型・診断はスタブ。 |
| 終了時のgit status / diff | 変更なし。修正・コミット・公開は実施していない。 |

ログ: make test（ローカル保管の監査資料）、make build（ローカル保管の監査資料）、Cookie既存テスト（ローカル保管の監査資料）。再現プログラムは evidence（ローカル保管の監査資料） に保存した。プログラムにはレビュー時の元ソースを連結したものが含まれる。合成データだけを使い、元プロジェクトのテスト追加・修正とは区別する。

実際のRavada/QEMUへの接続、切断・再接続・画面・音声・クリップボード・更新の実機試験、およびmacOS 26での互換性確認は未実施。ローカルのフルテスト・配布用ビルドの阻害要因は解消したが、既存テストの成功はR1〜R7の修正を意味しない。

## Metal Toolchain導入後の再検証ログ

- 全体テスト（ローカル保管の監査資料）
- 配布用ビルド（ローカル保管の監査資料）

テスト用バイナリのリンクで `duplicate -rpath` を無視したという警告が1件あった。テスト失敗や配布用ビルドの警告はなかった。初回の失敗ログは履歴として保持している。

生成物: `Maspice.app`（当時のローカル生成物）、`Maspice.app.zip`（当時のローカル生成物）。Developer ID署名・公証は行っていない。アプリの起動・接続・公開は行っていない。
