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

Тестовые данные для разработки — `mix bastion.demo`: дерево папок, одобренные, отозванное
и новые устройства, группа «Сетевики А» и сотрудники с ролями (их пароли команда
печатает). Добавляет к тому, что уже есть; повторно не создаёт. Устройства из демо
офлайн; онлайн-устройство — `mix bastion.device` (заявку одобрить на главной).

При первом запуске бастион создаёт свой корневой сертификат в `data/` (ключ
зашифрован паролем `BASTION_CA_PASSPHRASE`). Чтобы браузер не предупреждал,
установите `data/ca.crt` как доверенный корневой сертификат — или примите
предупреждение один раз.

В разработке веб-интерфейс слушает только `127.0.0.1:4443`; в релизе — 443
(HTTPS) и 80 (только перенаправление на HTTPS), порты меняются через
`BASTION_HTTPS_PORT` / `BASTION_HTTP_PORT`.

Тесты: `mix test` (БД из того же docker compose). Перед коммитом: `mix precommit`.

Phoenix-специфичные правила для ИИ-агентов — [`AGENTS.md`](AGENTS.md) (сгенерирован Phoenix).

## Сервер на Linux (Docker Compose)

Бастион и PostgreSQL в контейнерах; бастион — в сети машины (`network_mode: host`),
чтобы в его сертификат попали настоящие IP, а устройства подключались к ним напрямую.

```bash
cd bastion
cp .env.example .env          # пароли, SECRET_KEY_BASE (mix phx.gen.secret), PHX_HOST, BASTION_HOSTS
docker compose --profile server up -d --build
docker compose --profile server run --rm bastion /app/bin/bastion eval "Bastion.Release.admin()"
```

Порты: 443 — веб-интерфейс, 80 — перенаправление на HTTPS, 7443 — устройства.
Ключ корневого сертификата и сертификаты — в томе `bastion_data`: потеря тома или
`BASTION_CA_PASSPHRASE` = все устройства регистрировать заново.

На macOS/Windows host-сеть Docker работает ограниченно — там бастион запускают без
Docker (`mix phx.server` или собранный релиз), а в Docker оставляют только БД.
