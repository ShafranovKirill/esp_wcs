BASTION := bastion
FIRMWARE := firmware
PORT ?= /dev/ttyACM0
ARGS ?=

.DEFAULT_GOAL := help
.PHONY: help db db-stop setup admin admin-reset run device test precommit db-reset seed fw-build fw-flash

help:
	@echo "Бастион:"
	@echo "  make setup        .env из шаблона (если нет), БД, зависимости, миграции, ассеты, администратор"
	@echo "  make run          запустить бастион: https://localhost:4443, устройства — порт 7443"
	@echo "  make device       тестовое устройство WCS Link (ARGS=\"--id 7c2c678c8580 --name lab-1\")"
	@echo "  make admin        создать администратора, если его нет"
	@echo "  make admin-reset  перезаписать пароль администратора из bastion/.env"
	@echo "  make db           поднять PostgreSQL (127.0.0.1:5434)"
	@echo "  make db-stop      остановить PostgreSQL"
	@echo "  make db-reset     пересоздать пустую БД и администратора (все устройства пропадут)"
	@echo "  make seed         добавить тестовые папки и устройства (MAC aabbcc…)"
	@echo "  make test         тесты бастиона"
	@echo "  make precommit    компиляция без предупреждений, формат, тесты"
	@echo "Прошивка (сначала get_idf):"
	@echo "  make fw-build     собрать"
	@echo "  make fw-flash     прошить (PORT=$(PORT))"

db:
	cd $(BASTION) && docker compose up -d --wait db

db-stop:
	cd $(BASTION) && docker compose stop db

setup: db
	test -f $(BASTION)/.env || cp $(BASTION)/.env.example $(BASTION)/.env
	cd $(BASTION) && mix setup && mix bastion.admin

admin: db
	cd $(BASTION) && mix bastion.admin

admin-reset: db
	cd $(BASTION) && mix bastion.admin --reset

run: db
	cd $(BASTION) && mix phx.server

device:
	cd $(BASTION) && mix bastion.device $(ARGS)

db-reset: db
	cd $(BASTION) && mix ecto.reset && mix bastion.admin

seed: db
	cd $(BASTION) && mix run priv/repo/seeds.exs

test: db
	cd $(BASTION) && mix test

precommit: db
	cd $(BASTION) && mix precommit

fw-build:
	cd $(FIRMWARE) && idf.py build

fw-flash:
	cd $(FIRMWARE) && idf.py -p $(PORT) flash
