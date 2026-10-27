#pragma once

#include "esp_err.h"
#include "esp_event.h"

#define WCS_LINK_DEVICE_ID_LEN 12
#define WCS_LINK_CODE_LEN      24

ESP_EVENT_DECLARE_BASE(WCS_LINK_EVENT);

typedef enum {
    WCS_LINK_EVENT_STATE,
} wcs_link_event_t;

typedef enum {
    WCS_LINK_STATE_STOPPED,
    WCS_LINK_STATE_CONNECTING,
    WCS_LINK_STATE_PENDING,
    WCS_LINK_STATE_ONLINE,
    WCS_LINK_STATE_OFFLINE,
} wcs_link_state_t;

esp_err_t wcs_link_identity_init(void);

esp_err_t wcs_link_device_id(char out[WCS_LINK_DEVICE_ID_LEN + 1]);

esp_err_t wcs_link_device_code(char out[WCS_LINK_CODE_LEN + 1]);

esp_err_t wcs_link_forget_certificate(void);

esp_err_t wcs_link_forget_identity(void);

typedef struct {
    const char *bastion_addr;
    const char *name;
    const char *firmware;
} wcs_link_config_t;

esp_err_t wcs_link_start(const wcs_link_config_t *config);

esp_err_t wcs_link_stop(void);

wcs_link_state_t wcs_link_get_state(void);
