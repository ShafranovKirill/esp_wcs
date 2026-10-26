/*
 * Настройки устройства в NVS (пространство имён "wcs").
 *
 * Перед использованием должен быть выполнен nvs_flash_init().
 */
#pragma once

#include <stddef.h>

#include "esp_err.h"

#define WCS_SSID_MAX_LEN          32
#define WCS_WIFI_PASSWORD_MAX_LEN 64
#define WCS_BASTION_ADDR_MAX_LEN  128

typedef enum {
    WCS_MODE_FACTORY = 0, /* режим не выбран */
    WCS_MODE_DIRECT = 1,
    WCS_MODE_BASTION = 2,
} wcs_mode_t;

typedef struct {
    wcs_mode_t mode;
    /* Wi-Fi сеть и бастион — для WCS_MODE_BASTION */
    char sta_ssid[WCS_SSID_MAX_LEN + 1];
    char sta_password[WCS_WIFI_PASSWORD_MAX_LEN + 1];
    char bastion_addr[WCS_BASTION_ADDR_MAX_LEN + 1];
} wcs_settings_t;

/* Отсутствующие значения заполняются заводскими (режим не выбран, строки пустые) */
esp_err_t wcs_storage_load(wcs_settings_t *settings);
esp_err_t wcs_storage_save(const wcs_settings_t *settings);

/*
 * Корневой сертификат бастиона (PEM), закреплённый в мастере настройки после
 * сверки кода: дальше устройство подключается только к бастиону с этим CA.
 * Сбрасывается вместе с настройками. ESP_ERR_NOT_FOUND — не закреплён.
 */
esp_err_t wcs_storage_save_bastion_ca(const char *pem);
esp_err_t wcs_storage_load_bastion_ca(char *pem, size_t size);

/* Сброс до заводских: стирает все настройки */
esp_err_t wcs_storage_erase(void);
