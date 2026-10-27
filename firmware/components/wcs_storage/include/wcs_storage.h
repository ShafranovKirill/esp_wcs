#pragma once

#include <stddef.h>

#include "esp_err.h"

#define WCS_SSID_MAX_LEN          32
#define WCS_WIFI_PASSWORD_MAX_LEN 64
#define WCS_BASTION_ADDR_MAX_LEN  128

typedef enum {
    WCS_MODE_FACTORY = 0,
    WCS_MODE_DIRECT = 1,
    WCS_MODE_BASTION = 2,
} wcs_mode_t;

typedef struct {
    wcs_mode_t mode;
    char sta_ssid[WCS_SSID_MAX_LEN + 1];
    char sta_password[WCS_WIFI_PASSWORD_MAX_LEN + 1];
    char bastion_addr[WCS_BASTION_ADDR_MAX_LEN + 1];
} wcs_settings_t;

esp_err_t wcs_storage_load(wcs_settings_t *settings);
esp_err_t wcs_storage_save(const wcs_settings_t *settings);

esp_err_t wcs_storage_save_bastion_ca(const char *pem);
esp_err_t wcs_storage_load_bastion_ca(char *pem, size_t size);

esp_err_t wcs_storage_erase(void);
