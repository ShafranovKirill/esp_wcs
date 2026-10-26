/*
 * Ключ и сертификат HTTPS-сервера устройства.
 *
 * При первом запуске генерируется ключ ECDSA P-256 и самоподписанный сертификат
 * (срок до 2099 года), оба хранятся в NVS в отдельном пространстве имён "wcs_tls".
 * Сброс до заводских (wcs_storage_erase) их не трогает, чтобы браузеры, уже
 * принявшие сертификат, не показывали предупреждение заново.
 *
 * Сертификат перевыпускается, только если поменялось имя или адрес устройства.
 * Перед использованием должен быть выполнен nvs_flash_init().
 */
#pragma once

#include <stddef.h>

#include "esp_err.h"
#include "esp_netif_ip_addr.h"

typedef struct {
    const char *common_name; /* имя устройства, оно же DNS-имя в сертификате (+ ".local") */
    esp_ip4_addr_t ip;       /* адрес веб-интерфейса, попадает в сертификат */
} wcs_tls_identity_t;

/* Загружает ключ и сертификат из NVS или создаёт новые (доли секунды). Вызывать один раз. */
esp_err_t wcs_tls_init(const wcs_tls_identity_t *identity);

/* PEM с завершающим нулём; длины включают ноль (так их ждёт esp_https_server) */
typedef struct {
    const char *cert_pem;
    size_t cert_len;
    const char *key_pem;
    size_t key_len;
} wcs_tls_server_cred_t;

/* ESP_ERR_INVALID_STATE — wcs_tls_init() не вызывался или завершился ошибкой */
esp_err_t wcs_tls_get_server_cred(wcs_tls_server_cred_t *cred);
