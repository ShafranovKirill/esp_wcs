/*
 * Связь с бастионом.
 *
 * Пока только адрес и проверка доступности (TCP-подключение к порту бастиона).
 * Протокол ESP ↔ бастион появится на этапе 2.
 *
 * Адрес: IPv4, домен или имя .local (mDNS), с необязательным портом через двоеточие.
 * Без порта — CONFIG_WCS_BASTION_DEFAULT_PORT.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_netif_ip_addr.h"
#include "wcs_storage.h"

typedef struct {
    char host[WCS_BASTION_ADDR_MAX_LEN + 1];
    uint16_t port;
} wcs_bastion_addr_t;

/* Разбирает адрес; false — недопустимые символы, пустой хост или неверный порт */
bool wcs_bastion_parse_addr(const char *addr, wcs_bastion_addr_t *out);

typedef enum {
    WCS_BASTION_PROBE_OK,           /* порт принимает подключения */
    WCS_BASTION_PROBE_NOT_RESOLVED, /* имя не нашлось ни в DNS, ни через mDNS */
    WCS_BASTION_PROBE_REFUSED,      /* хост ответил, но порт закрыт */
    WCS_BASTION_PROBE_TIMEOUT,      /* нет ответа */
    WCS_BASTION_PROBE_UNREACHABLE,  /* нет маршрута или другая ошибка сети */
} wcs_bastion_probe_result_t;

typedef struct {
    wcs_bastion_probe_result_t result;
    esp_ip4_addr_t ip; /* если имя нашлось */
    uint16_t port;
    uint32_t time_ms;  /* время подключения при WCS_BASTION_PROBE_OK */
} wcs_bastion_probe_t;

/*
 * Проверяет, что бастион доступен: находит адрес и открывает TCP-подключение
 * (сразу закрывает). Блокирует до нескольких секунд на поиск имени плюс timeout_ms
 * на подключение. Не вызывать одновременно из разных задач.
 * ESP_ERR_INVALID_ARG — адрес не разбирается.
 */
esp_err_t wcs_bastion_probe(const char *addr, uint32_t timeout_ms, wcs_bastion_probe_t *out);
