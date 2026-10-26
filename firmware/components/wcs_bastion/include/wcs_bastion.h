/*
 * Связь с бастионом.
 *
 * Адрес бастиона, проверка (TLS-рукопожатие с получением корневого сертификата
 * и кода бастиона для сверки человеком) и коды ключей (docs/protocol.md).
 *
 * Адрес: IPv4, домен или имя .local (mDNS), с необязательным портом через двоеточие.
 * Без порта — CONFIG_WCS_BASTION_DEFAULT_PORT.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_netif_ip_addr.h"
#include "wcs_storage.h"

/* Код ключа для сверки человеком: 7F3A-91C2-B4E0 */
#define WCS_BASTION_CODE_LEN    14
/* Корневой сертификат бастиона (PEM, ECDSA P-256 — около 700 байт) */
#define WCS_BASTION_CA_PEM_MAX  1536

typedef struct {
    char host[WCS_BASTION_ADDR_MAX_LEN + 1];
    uint16_t port;
} wcs_bastion_addr_t;

/* Разбирает адрес; false — недопустимые символы, пустой хост или неверный порт */
bool wcs_bastion_parse_addr(const char *addr, wcs_bastion_addr_t *out);

typedef enum {
    WCS_BASTION_PROBE_OK,           /* это бастион: TLS прошёл, корневой сертификат получен */
    WCS_BASTION_PROBE_NOT_RESOLVED, /* имя не нашлось ни в DNS, ни через mDNS */
    WCS_BASTION_PROBE_REFUSED,      /* хост ответил, но порт закрыт */
    WCS_BASTION_PROBE_TIMEOUT,      /* нет ответа */
    WCS_BASTION_PROBE_UNREACHABLE,  /* нет маршрута или другая ошибка сети */
    WCS_BASTION_PROBE_NOT_BASTION,  /* порт открыт, но TLS 1.3 с корневым сертификатом не получился */
} wcs_bastion_probe_result_t;

typedef struct {
    wcs_bastion_probe_result_t result;
    esp_ip4_addr_t ip; /* если имя нашлось */
    uint16_t port;
    uint32_t time_ms;  /* время подключения при WCS_BASTION_PROBE_OK */
    /* При WCS_BASTION_PROBE_OK: код бастиона и его корневой сертификат */
    char code[WCS_BASTION_CODE_LEN + 1];
    char ca_pem[WCS_BASTION_CA_PEM_MAX];
} wcs_bastion_probe_t;

/*
 * Проверяет бастион: находит адрес, подключается и проходит TLS 1.3 без проверки
 * сертификата, чтобы получить корневой сертификат и код бастиона. Доверие
 * устанавливает человек, сверив код с бастионом. Блокирует до нескольких секунд
 * на поиск имени плюс timeout_ms на подключение и рукопожатие.
 * Не вызывать одновременно из разных задач. Структура большая (~1,7 КБ).
 * ESP_ERR_INVALID_ARG — адрес не разбирается.
 */
esp_err_t wcs_bastion_probe(const char *addr, uint32_t timeout_ms, wcs_bastion_probe_t *out);

/* Код ключа по SubjectPublicKeyInfo (DER): SHA-256, первые 6 байт */
esp_err_t wcs_bastion_code(const uint8_t *spki_der, size_t len, char out[WCS_BASTION_CODE_LEN + 1]);

/* IPv4 по имени: IP, DNS или .local (mDNS). ESP_ERR_NOT_FOUND — не нашлось */
esp_err_t wcs_bastion_resolve(const char *host, esp_ip4_addr_t *ip);
