/*
 * WCS Link — связь устройства с бастионом (docs/protocol.md).
 *
 * Идентичность устройства: ключ ECDSA P-256 (создаётся один раз, хранится в NVS
 * в пространстве "wcs_link", сброс до заводских его не трогает), ID — базовый
 * MAC, код устройства — для сверки с заявкой на бастионе.
 *
 * Сеанс (своя задача): подключение wss://<бастион>/link с проверкой по
 * закреплённому корневому сертификату бастиона; без сертификата устройства —
 * заявка и ожидание одобрения, с сертификатом — mTLS, heartbeat, время от
 * бастиона. Обрыв — переподключение с паузой 1 с … 60 с (±20 %).
 * Смена состояния — событие WCS_LINK_EVENT_STATE (данные — wcs_link_state_t).
 *
 * До использования: nvs_flash_init(), esp_netif_init(), esp_event_loop_create_default().
 */
#pragma once

#include "esp_err.h"
#include "esp_event.h"

#define WCS_LINK_DEVICE_ID_LEN 12 /* 7c2c678c8580 */
#define WCS_LINK_CODE_LEN      14 /* 7F3A-91C2-B4E0 */

ESP_EVENT_DECLARE_BASE(WCS_LINK_EVENT);

typedef enum {
    WCS_LINK_EVENT_STATE, /* данные — wcs_link_state_t */
} wcs_link_event_t;

typedef enum {
    WCS_LINK_STATE_STOPPED,
    WCS_LINK_STATE_CONNECTING, /* подключение ещё не удавалось */
    WCS_LINK_STATE_PENDING,    /* заявка ждёт одобрения администратора */
    WCS_LINK_STATE_ONLINE,     /* сеанс устройства, heartbeat идёт */
    WCS_LINK_STATE_OFFLINE,    /* связь потеряна, переподключение */
} wcs_link_state_t;

/* Загружает ключ устройства или создаёт его (~0,3 с при первом запуске) */
esp_err_t wcs_link_identity_init(void);

/* ID устройства — базовый MAC, 12 hex строчными */
esp_err_t wcs_link_device_id(char out[WCS_LINK_DEVICE_ID_LEN + 1]);

/* Код устройства для сверки с заявкой на бастионе */
esp_err_t wcs_link_device_code(char out[WCS_LINK_CODE_LEN + 1]);

/* Забыть сертификат устройства (при новой привязке к бастиону) */
esp_err_t wcs_link_forget_certificate(void);

typedef struct {
    const char *bastion_addr; /* как в мастере: хост[:порт] */
    const char *name;         /* имя по умолчанию для заявки */
    const char *firmware;     /* версия прошивки */
} wcs_link_config_t;

/* Запускает сеанс; корневой сертификат бастиона берётся из wcs_storage. Строки копируются */
esp_err_t wcs_link_start(const wcs_link_config_t *config);

/* Останавливает сеанс и ждёт завершения задачи (до нескольких секунд) */
esp_err_t wcs_link_stop(void);

wcs_link_state_t wcs_link_get_state(void);
