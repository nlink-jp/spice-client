# ADR-0001: spice-client のネイティブアプリ再実装

| Field | Value |
|-------|-------|
| Status | **Accepted** — 2026-09-17 ユーザーが進行承認 |
| Date | 2026-09-17 |
| Binds | spice-client |
| Decision makers | nlink-jp maintainers |
| Triggered by | spice-mac 全体レビューに続く、新規移植と不具合修正の依頼 |

改訂（2026-09-18）: ユーザーは §1 の `util-series` ではなく `lab-series` に配置することを決め、実ピアのゲートを未完のまま[検証記録](../verification.ja.md)に明記したうえで、シミュレーションによる検証で v0.1.0 を公開することを決定した。

## Context

Apple Silicon の Mac から標準 QEMU / Ravada の仮想マシンに接続するための
SPICE クライアントを作る。既存の spice-mac（Maspice）を参照しつつ、入力検証、
Web とネイティブ接続の境界、セッションの所有権を再設計する。
ユーザーはプロジェクト名 `spice-client` と SwiftSpice の継続利用を指定済み。
本書の製品・実装方針は、2026-09-17 の「進行承認」により承認された。

参照基準は spice-mac のコミット `4631b0cf43032671fe01e994db5613e78a91037a`。
既存プロジェクトには明確な悪意ある処理を確認していないが、Web ページによる
接続開始、TLS 指定の黙殺、切断処理の停止などを再現した。
Metal Toolchain 導入後、元プロジェクトの `make test` と `make build` は成功した。
これは新実装の検証結果ではなく、実通信・配布バイナリの安全性の証明でもない。

## Decision

### 1. 製品と配置

- リポジトリ名 `spice-client`、アプリ名 **Spice Client**、実行ファイル名
  `SpiceClient`、Bundle ID `jp.nlink.spice-client`。
- 組織の `_wip/spice-client/` で開発する。所属は `lab-series`（2026-09-18 改訂。
  原文は既存のネイティブ GUI 群と同じ `util-series` としていた）。元の spice-mac
  作業コピーは参照用に残す。
- Swift 6.3 / Swift 6 strict concurrency、SwiftUI + 必要な AppKit、WebKit、Metal。
  初期対象は macOS 26 以降・arm64。SwiftSpice 0.4.2 のコミット
  `3f8de33a3c91fd7ed42d42b5970e644a8abf94b6` を検証済み基準として固定し、
  下記の clipboard 境界変更だけを追跡可能なローカル依存へ適用する。
  更新時は基準コミット・パッチ・ネイティブ成果物の差分を再レビューする。
- 通信、TLS、コーデック、Metal 描画は SwiftSpice に委ねる。アプリ層を再実装し、
  プロトコルやバイナリライブラリを独自に作り直すことは本計画に含めない。

### 2. 操作仕様

ランチャーから `.vv` ファイルを選択、ドロップ、Finder で開く、または HTTPS の
Ravada ポータルを開く。いずれの経路も解析後にアプリ自身の接続確認画面へ進む。
確認画面には送信元、接続ホスト、ポート、暗号化方式、証明書検証方式、
クリップボード共有を表示し、明示的な「接続」操作で開始する。
パスワードやチケットは表示しない。平文 TCP は互換性のため残すが、暗号化なしと
明示する。TLS エラーから平文へ切り替える処理は作らない。

複数のセッションウィンドウを扱い、各セッションは一つのディスプレイストリームを
表示する。キーボード、マウス、カーソル、音声再生、ゲストの解像度変更、
フルスクリーン、診断情報の表示・コピーを移植する。H.264 が最初の描画前に
利用不能な場合の MJPEG 再接続は同じ承認済み接続先に一度だけ許し、前の接続を
停止してから実施する。通常の接続失敗や認証失敗を無制限に再試行しない。

クリップボード共有は新アプリでは初期 OFF。確認画面またはセッション操作で
明示的に有効化できる。有効なセッションでも、そのウィンドウが操作対象である間
だけホストのクリップボードに接続する。フォーカス喪失、共有 OFF、切断開始で
読み書きを停止し、他のセッションへ内容を中継しない。解像度変更用の agent と
クリップボードアクセスの許可を分ける。

**依存 API の変更が必要であることを確認済み。** SwiftSpice 0.4.2 の
`SpicePasteboardBridge` は `.general` 固定で、`SpiceAgentManager` は共有再有効化時に
その内容を即座に送る。このままでは A が書いた内容を B へ中継し、取消前に予約された
MainActor の書込みも実行し得る。アプリ側のフラグ操作だけで解決したとは扱わない。
通信・描画の再実装はせず、clipboard の読み書きを注入できる最小の依存変更を行う。
実アクセス時に MainActor 上で session ID・許可世代・focus を照合し、拒否は空文字の
コピーと区別する。アプリ共通の broker がゲスト書込みの pasteboard changeCount と
送信元 session を記録し、他の session へ自動再送しない。他のアプリで利用者が新たに
コピーした内容は別の変更として扱う。共有取消時には保留中の clipboard action も
世代不一致で破棄する。取消前にネットワークへ送出済みの内容は撤回できない。

この変更は `Vendor/SwiftSpice` のローカル SwiftPM package として保持し、基準 URL・
tag・コミット、変更ファイル一覧、再適用できるパッチ、ネイティブ成果物のハッシュを
記録する。未変更の upstream 0.4.2 と同一だとは表示しない。依存側の追加テストと
既存テストを実行する。上流への修正提案は作成できるが、公開・送信は別途扱う。
受入検証には「A→host 書込み→B への focus 移動」と「MainActor の読み書き待機中の
取消」を含め、実装で契約を満たせない場合は clipboard を無効のままにして報告する。

設定は新しいアプリ固有の領域に保存する。ポータル URL と非機密の UI 設定を扱い、
旧アプリの UserDefaults、証明書例外、更新設定は自動移行しない。WebKit のログイン
情報はアプリ固有の WebKit データストアに委ね、「ポータルのログイン情報を消去」
操作を設ける。SPICE チケットや接続ファイル本文は設定・履歴・ログに保存しない。
日本語・英語の UI と文書を揃え、標準の編集メニュー、Command-O / Command-W、
設定とバージョン表示を提供する。

### 3. モジュールと所有権

| Target / 領域 | 責務 | 主な検証 |
|---|---|---|
| ConnectionCore | `.vv` の解析、検証、接続計画、origin、Cookie の選択 | 外部入力から期待結果までの単体・生成テスト |
| SessionCore | セッション状態、世代、入力順序、共有許可、終了処理 | fake transport と制御可能なイベントで失敗・競合を検証 |
| SwiftSpiceAdapter | 接続計画を SwiftSpice に渡し、イベント・音声・描画を接続 | 本物の公開 API を使う統合テスト |
| SpiceClient | SwiftUI、AppKit、WebKit、ファイル受付、設定、確認画面 | 実 WebKit / URLSession と組み立て済みアプリで検証 |

Core は AppKit / WebKit / SwiftSpice に依存させない。時計、送信、ファイル操作、
クリップボード、設定の副作用を注入する。画面状態は MainActor に所有させ、
接続ごとに transport、agent、audio、入力キュー、タスクの所有者を一つにする。
独立したタスクには停止・回収の経路を設ける。

`received → awaitingConfirmation → connecting → connected → stopping → closed`
を基本とし、失敗理由は型付きで保持する。取消済み確認、古い接続世代、閉じた画面の
callback は新しい接続や共有を開始できない。接続確認は解析済みの不変な接続計画に
結びつけ、確認後に同じパスを再読込して別内容に置き換えない。

### 4. レビュー指摘を閉じる仕様と受入条件

| ID | 原因・新実装での対処 | 必須の回帰検証 |
|---|---|---|
| R1 | `buttonNumber == 0` は人間の操作の証明にならない。WebKit のナビゲーション種別を接続許可にせず、ネイティブ確認を必須にする | 実 WebKit で自動 navigation / form submit を発生させ、確認前の connect 呼出しとホストの clipboard アクセスがゼロであること。取消・古い確認も拒否 |
| R2 | 既存の Sparkle 2.9.4 と旧アプリの更新先を継承しない。初期版には自動更新機構を組み込まない | 解決依存・Info.plist・組み立て済み `.app` に旧 updater / feed / key がなく、アプリ起動が更新先へ接続しないこと |
| R3 | host 単独比較を廃し、scheme・正規化 host・実効 port の origin 値でハンドオフを検証する | 443 と省略は同一、8443 は別。HTTP、userinfo、iframe、別 origin からの `.vv` とリダイレクトを拒否 |
| R4 | URLSession の手動 Cookie ヘッダーを転送先へ持ち越さない | 実 HTTPS リダイレクトで path / domain / secure / expiry を再評価し、`/private` の Cookie が `/public` に届かないこと |
| R5 | port の「未指定・無効化・不正」を別状態として解析し、不正値で平文に落とさない | `tls-port=oops`、範囲外、空値の明示を失敗させる。許容する無効化表現は仕様に基づく fixture で固定 |
| R6 | `secure-channels` 等の通信保護要求を黙殺しない | TLS 必須チャネルを含む設定は全チャネル TLS で保証できる場合のみ接続。未知のチャネル指定、保証できない保護要求はエラー |
| R7 | 入力送信の完了を transport close の前提にしない | 送信を故意に止めても clipboard を直ちに遮断し、transport close が呼ばれ、切断が完了すること。再接続・終了・失敗の経路も対象 |
| R8 | 元ファイルを接続開始直後に Trash へ移さない | 明示的な設定があるときだけ接続成功後に一度移動。失敗・取消では保存。同じパスの別ファイルに差し替わっていたら移動しない |
| R9 | doctor の Metal 検査を shim の存在確認で済ませない | 小さな shader の実コンパイルを行い、未導入・利用不能を明確な失敗として返す |
| R10 | ライセンス記載と実依存を一致させ、配布物へ収録する | lockfile・依存棚卸し・bundle 内の notices とネイティブ成果物を突合する |
| R11 | ソース文字列の一致を中心にしたテストを振る舞いテストへ置き換える | 既存の再現入力を使い、旧挙動では失敗、新挙動では成功する回帰テストにする |
| R12 | リリース経路に実行可能な検証ゲートを設ける | テスト失敗、署名・公証不足、リソース不足、依存監査失敗で package / verify-release が停止する |

R1〜R7 は元レビューの主要指摘。R8〜R12 は同レビューの補足を追跡可能な ID にした。
これらの表だけで全体レビューを完了したとは扱わない。元コード全ファイルを
「新実装へ対応」「依存へ委譲」「廃止・理由あり」「未確認」で台帳化し、
潜在的な追加不具合を調査しながら更新する。

### 5. Web・TLS・ファイルの境界

- ポータルのハンドオフ対象 origin は利用者が登録した HTTPS URL から決める。
  ページ遷移で登録 origin を自動的に変更しない。通常のログイン遷移と
  `.vv` のネイティブハンドオフ許可を別に判定する。
- `.vv` の取得は origin 制約を持つ専用 URLSession。全リダイレクトで origin と
  Cookie を再評価する。最大 1 MiB、有限のタイムアウトとリダイレクト回数を設定し、
  HTTP エラー、非 UTF-8、本文切れを拒否する。Cookie や認証を別 origin に渡さない。
  同 origin の Set-Cookie は取得セッション内だけに適用し、暗黙の共有 cookie jar を
  混在させない。Ravada の時刻差補正は期限切れ Cookie の一般的な延命には使わず、
  既存の狭い条件と fixture を確認して移植する。
- サーバー起因のポップアップやダウンロードから確認画面を無制限に生成しない。
  一つの保留候補を表示し、別候補で承認対象を差し替えない。新しい候補は明示的に
  再選択する。拒否理由は秘密を含めず画面に示す。
- ポータル TLS は OS の検証を既定にする。自己署名証明書の例外はネイティブ画面で
  origin と SHA-256 fingerprint を表示して一時承認し、そのポータルを閉じると失効。
  初期版は恒久例外を持たない。例外は origin と証明書に束縛し、他の TLS エラーや
  他の接続先を包括的に無視しない。
- SPICE TLS は system trust、ファイル CA、CA + host-subject の既存機能を移植する。
  不正な CA、証明書不一致、未知のセキュリティ指定は明示的なエラーにする。
  `.vv` のキーは virt-viewer の仕様と SwiftSpice の実装に照合し、機密・保護に関わる
  キーの不正や重複は曖昧に解釈しない。単なる表示ヒントとの区別を文書化する。
- ポータルの本文はメモリで解析し、接続チケットの一時ファイル作成を不要にする。
  利用者が選んだファイルはサイズを制限して一度読み、通常はそのまま保存する。
  `delete-this-file` 単独では削除せず、利用者の設定と接続成功・同一ファイル確認を
  要求する。削除失敗は接続成功と区別して通知する。

### 6. 停止と機密情報

切断開始時に新規入力とホスト clipboard 読み書きを同期的に無効化し、接続世代を
無効にする。キー解放の送信は短時間の best effort とし、その完了を待たずに
transport の明示的な close/cancel を進める。その後 agent/audio/input の終了を回収。
Swift の Task.cancel だけでは停止保証にならないことを前提にする。
タイムアウト用 TaskGroup が止まらない子タスクの終了を待つ形も避ける。
依存 API で停止を保証できないと判明した場合は、見かけ上の disconnected 表示で
隠さず、依存側の修正または公開 API 変更を次の設計判断として扱う。

診断は既定 OFF、メモリ内の上限付き集計のみ。host、URL、ファイルパス、チケット、
Cookie、キー内容、clipboard 内容、画面データを記録しない。エラー文も本文や秘密を
そのまま取り込まない。切断後に最後の集計をコピーできる。コピーは明示操作とする。

### 7. 権限と依存・配布

アプリは選択されたファイルの読み取り、明示設定時の Trash 移動、選択したポータルと
SPICE サーバーへのネットワーク接続を行う。クリップボードは前述の opt-in のみ。
マイク、カメラ、画面収録、Accessibility、Apple Events、USB、管理者権限は製品要件に
含めない。OS が権限判断を要求した場合は意図した操作時に理由を表示する。
OAuth API scope はアプリとして要求せず、ポータルの認証は WebKit 上で行う。

署名は Hardened Runtime を使い、ネイティブ Swift アプリへ JIT 等の例外を
機械的に追加しない。WebKit を含む実バンドルの検証で必要性を確かめる。
アプリサンドボックスの対応と App Store 配布は本計画の対象外。

SwiftSpice の MIT 本文とネイティブ依存の全ライセンス・由来・バージョン・ハッシュを
棚卸しする。LGPL コンポーネントを含む静的成果物は配布要件と再リンク用成果物等を
確認し、単に MIT のアプリだと記載して配布完了にしない。元コードを参照・移植する
箇所には元プロジェクトを明記し、Ching367436 / BeriBeli の著作権表示と許諾本文を
`NOTICE.md` に保持する。ルート LICENSE は標準 MIT 本文とし、依存の全文 notices は
`.app/Contents/Resources/` に収録する。

`make test`、`make lint`、`make doctor`、`make build`、`make package`、
`make verify-release` を用意する。`make build` はローカル検証用 `.app` を `dist/` に
生成。`make package` はテストと依存監査を通し、組織の原本と同一の署名・公証
スクリプトで Developer ID 署名、公証、staple を行い、
`spice-client-v0.1.0-darwin-arm64.zip` の形式で生成する。公証未完了のものを
配布可能なリリースとして扱わない。署名情報は環境・Keychain に置く。
GitHub 作成・公開、インストール、タグ、配布はこの設計作成では実施しない。

### 8. 段階と検証

1. **設計承認と scaffold**: 本書、互換性・廃止一覧、元ソース対応台帳を確定。
   ビルド配線、文書、ライセンス、組織チェックを整える。
2. **ConnectionCore と回帰テスト**: `.vv`、TLS、origin、Cookie を実装。
   既存の正常系 fixture を維持し、既知の不具合を示す fixture を追加する。
3. **SessionCore と SwiftSpiceAdapter**: 接続・切断・再接続、順序付き入力、音声、
   描画、agent と clipboard を実装。送信停止、競合、取消のテストを先に用意する。
4. **アプリとポータル**: ファイル受付、ネイティブ確認、WebKit、設定、診断、
   複数ウィンドウ、日本語・英語、アクセシビリティラベルを接続する。
5. **全体検証**: 台帳の未確認を解消、独立レビュー、実 WebKit / HTTPS 検証、
   組み立てたアプリの起動・リソース解決・標準操作を確認する。
6. **実接続と配布ゲート**: 標準 QEMU / Ravada の TCP・TLS を実接続し、
   画面・音声・入力・clipboard・resize・切断・診断を確認。
   clean 環境、署名、公証、アーカイブ内容、ライセンス収録を検証する。

各段階でテストと英日 README / CHANGELOG / AGENTS を更新し、小さい typed commit
に分ける。実装完了とリリース可能を区別する。実 SPICE サーバーや人による実機 UI
確認がない項目は未検証と記録し、モックや元アプリのビルド成功で代用しない。
配布リポジトリを組織へ統合する段階で umbrella、profile、`check-org.sh` を更新・確認する。

## Consequences

- 元アプリと同じ SPICE backend を使いながら、危険な解釈とライフサイクルを
  アプリ側の単一境界に集約できる。全コードを機械的にコピーする移植にはしない。
- 初期版は自動更新、恒久的なポータル証明書例外を含めない。これらは独立の設計と
  検証を経て追加可能。USB、マイク、WebDAV、Proxmox proxy、多画面ストリーム、
  Intel / Windows / Linux、接続パスワードの永続化も今回の対象外。
- 確認画面と clipboard 初期 OFF は元アプリからの意図的な動作変更。
  チケット期限切れでは再取得を促し、同じチケットを無期限に保持しない。
- SwiftSpice とネイティブ成果物の不具合は依然として影響する。アプリ全体のレビューと
  依存のソース・バイナリ検証の範囲を混同せず、依存の停止 API や配布要件が不足する
  場合はリリースを止める。
- 独立した設計検証で見つかった clipboard API の不足を採用し、最小パッチと
  追加の受入テストを本書に反映した。ローカル依存の保守負担が増えるため、互換な
  upstream 修正が利用可能になれば差分を評価してパッチを外す。

## Alternatives considered

1. **既存 app の fork を最小修正**: 変更量は小さいが、ユーザーの再設計意図と異なり、
   分散した接続許可・停止・ファイル所有権を引き継ぐ。必要な仕様と fixture は残す。
2. **通信・描画も再実装**: ユーザーは SwiftSpice 継続を選択済み。
   相互運用とコーデックの検証負担も大きいため採用しない。
3. **Web の gesture 判定だけを修正**: 確認済みの navigation metadata では人間の意図を
   保証できない。アプリが解析済みの接続を確認する方式を採用する。
4. **Sparkle を修正版へ更新してそのまま移植**: 独自の feed・鍵・配布運用が必要。
   初期版の接続品質を先に固めるため、自動更新は切り離す。
5. **平文を全面禁止**: 既存の直接 TCP 利用を失う。明示確認した TCP は残し、
   TLS 要求の失敗からの降格を禁止する。

## References

- [spice-mac 基準コード](https://github.com/BeriBeli/spice-mac/tree/4631b0cf43032671fe01e994db5613e78a91037a)
- [SwiftSpice 0.4.2](https://github.com/BeriBeli/spice-swift/tree/v0.4.2)
- [組織規約](https://github.com/nlink-jp/.github/blob/main/CONVENTIONS.md): Plan → Scaffold → Develop、ADR、独立検証、署名。
- [knowledge / development-process](https://github.com/nlink-jp/knowledge/blob/main/docs/en/development-process.md): 仕様・fixture を先に確定し、移植元の未適用の教訓も照合する。
- [knowledge / testing](https://github.com/nlink-jp/knowledge/blob/main/docs/en/testing.md): 「期待が誤れば green に意味がない」「本物の境界を通す」を R1/R4 と実機 gate に適用。
- [knowledge / config-and-io](https://github.com/nlink-jp/knowledge/blob/main/docs/en/config-and-io.md): 不正設定を既定値で隠さず、cancel 通知だけで停止を保証しない。
- [knowledge / macos-gui](https://github.com/nlink-jp/knowledge/blob/main/docs/en/macos-gui.md): bundle のリソース解決、版表示、標準編集メニュー、二重起動対策。SwiftPM の開発ディレクトリを隠した起動テストを行う。
- [knowledge / release-engineering](https://github.com/nlink-jp/knowledge/blob/main/docs/en/release-engineering.md): fail-open の公証処理を後段で拒否し、LICENSE 分離後の notices も実アーカイブで確認。

ワークスペース memory の `index_gui_dev`、`feedback_swiftpm_bundle_module_app`、
`feedback_menubar_duplicate_instance_guard` も照合。二重起動 guard は起動前に置き、
Finder のファイル受付を無言で破棄しないことを統合テストする。
参照した menubar-spacer の AGENTS / CLAUDE、および SwiftSpice の AGENTS を読了。
spice-mac 基準ツリーには AGENTS / CLAUDE はなかった。

実装追記（2026-09-17）: 利用者より実接続先がないためシミュレーションでの検証を指定。ローカルアプリ、疑似通信・実WebKit試験、レビューを実施し、実ゲスト検証と署名済みリリースは別の段階として扱います。[検証記録](../verification.ja.md)を参照してください。
