#pragma once

#include "esp_err.h"
#include "wcs_storage.h"

typedef enum {
    WCS_WEB_MODE_SETUP,
    WCS_WEB_MODE_DIRECT,
} wcs_web_mode_t;

typedef struct {
    const char *ssid;
    const char *password;
    const char *url;
} wcs_web_direct_info_t;

typedef struct {
    wcs_web_mode_t mode;
    const char *host;

    wcs_web_direct_info_t direct;
    esp_err_t (*apply)(const wcs_settings_t *settings);
} wcs_web_config_t;

esp_err_t wcs_web_start(const wcs_web_config_t *config);
esp_err_t wcs_web_stop(void);
