# nginx - syslog-appliance リバースプロキシ設定

## 役割

- HTTP(80) → HTTPS(443) への永続リダイレクト
- 静的ファイル（`/opt/syslog-appliance/frontend/dist/`）の直接配信
- `/api/`、`/healthz`、`/docs` を FastAPI（127.0.0.1:8080）へリバースプロキシ

## ファイル

| リポジトリパス              | 配置先                                         |
|-----------------------------|------------------------------------------------|
| `nginx/syslog-appliance.conf` | `/etc/nginx/conf.d/syslog-appliance.conf`    |

## 証明書配置先

```
/etc/syslog-appliance/ssl/
├─ server.crt   (パーミッション 0644, root:root)
└─ server.key   (パーミッション 0600, root:root)
```

証明書は `scripts/generate-self-signed-cert.sh` で生成する。

## default.conf との競合について

Rocky Linux の nginx パッケージには `/etc/nginx/conf.d/default.conf` が含まれており、
ポート 80 を listen している。`syslog-appliance.conf` もポート 80/443 を listen するため、
同時に有効化すると nginx の起動に失敗することがある。

`scripts/setup-mvp1-frontend.sh` は `default.conf` をバックアップとして残すが、
コンフリクトが発生する場合は手動で名前を変更すること。

```bash
# 競合する default.conf を無効化する（必要な場合のみ）
sudo mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
sudo nginx -t && sudo systemctl reload nginx
```

## SELinux の考慮

nginx から localhost:8080（FastAPI）へのプロキシには SELinux の
`httpd_can_network_connect` boolean が `on` である必要がある。

`setup-mvp1-frontend.sh` が自動的に設定するが、手動で確認する場合:

```bash
getsebool httpd_can_network_connect
# → httpd_can_network_connect --> on  であれば OK
```
