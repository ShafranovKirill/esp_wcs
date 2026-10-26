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
mix phx.server                # http://localhost:4000
```

Тесты: `mix test` (БД из того же docker compose). Перед коммитом: `mix precommit`.

Phoenix-специфичные правила для ИИ-агентов — [`AGENTS.md`](AGENTS.md) (сгенерирован Phoenix).
