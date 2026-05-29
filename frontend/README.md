# frontend - syslog-appliance 管理画面

## 役割

素の HTML + Bootstrap 5（CDN）+ Fetch API + Vanilla JS で構成されたシングルページアプリ。
機器の一覧・追加・編集・削除（CRUD）を 1 画面で完結させる。

## ディレクトリ構成

```
frontend/
├─ dist/                 # nginx が静的配信するディレクトリ
│  ├─ index.html         # メインページ（全 UI を含む）
│  ├─ css/
│  │  └─ app.css         # Bootstrap を補う固有スタイル
│  └─ js/
│     ├─ api.js          # API クライアント（window.api に公開）
│     └─ devices.js      # 機器管理ロジック
└─ README.md             # このファイル
```

## 配信先

本番環境では nginx が以下のパスから静的配信する。

| リポジトリパス        | 配置先                                       |
|-----------------------|----------------------------------------------|
| `frontend/dist/`      | `/opt/syslog-appliance/frontend/dist/`       |

`scripts/setup-mvp1-frontend.sh` が配置を行う。

## API との通信

- API は `/api/v1/` へのリクエストとして送信される
- nginx が `http://127.0.0.1:8080` へリバースプロキシする
- ブラウザの Basic 認証ダイアログで認証（`credentials: 'include'`）

```
ブラウザ → https://[アプライアンス IP]/api/v1/* → nginx → http://127.0.0.1:8080/api/v1/*
```

## ローカル開発（動作確認）

フロントエンドの静的ファイルだけを確認したい場合は、`dist/` ディレクトリで
Python の簡易 HTTP サーバーを使う。

```bash
cd frontend/dist
python3 -m http.server 8000
# ブラウザで http://localhost:8000/ を開く
```

**注意**: この方法では API 呼び出しは失敗する（CORS 制限と nginx がないため）。
UI の見た目確認のみに使うこと。

API まで含めて確認するには、アプライアンス本体で `setup-mvp1-frontend.sh` を
実行してから `https://[アプライアンス IP]/` にアクセスする。

## 注意事項

- `api.js` より後に `devices.js` を読み込むこと（`index.html` で順序指定済み）
- Bootstrap 5 / Bootstrap Icons は CDN から読み込む（オフライン環境では注意）
- XSS 対策として `devices.js` 内の `esc()` 関数で DOM 挿入前に HTML エスケープしている
