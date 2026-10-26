# Бастион ESP WCS

Сервер, к которому подключаются устройства ESP WCS в режиме Bastion connection.
Устройство, решения и архитектура — [`docs/bastion.md`](../docs/bastion.md),
протокол — [`docs/protocol.md`](../docs/protocol.md).

## Запуск для разработки

Нужны Elixir 1.20 / OTP 28 (`.tool-versions`, через asdf) и Docker.

```bash
cd bastion
cp .env.example .env          # и поменять пароли
docker compose up -d db       # PostgreSQL на 127.0.0.1:5434
mix setup                     # зависимости, БД, сборка ассетов
mix phx.server                # https://localhost:4443
```

При первом запуске бастион создаёт свой корневой сертификат в `data/` (ключ
зашифрован паролем `BASTION_CA_PASSPHRASE`). Чтобы браузер не предупреждал,
установите `data/ca.crt` как доверенный корневой сертификат — или примите
предупреждение один раз.

В разработке веб-интерфейс слушает только `127.0.0.1:4443`; в релизе — 443
(HTTPS) и 80 (только перенаправление на HTTPS), порты меняются через
`BASTION_HTTPS_PORT` / `BASTION_HTTP_PORT`.

Тесты: `mix test` (БД из того же docker compose). Перед коммитом: `mix precommit`.

Phoenix-специфичные правила для ИИ-агентов — [`AGENTS.md`](AGENTS.md) (сгенерирован Phoenix).
