#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_netif_ip_addr.h"

typedef struct {
    const char *ssid;
    const char *password;
    uint8_t channel;
    uint8_t max_clients;
} wcs_wifi_ap_config_t;

esp_err_t wcs_wifi_ap_start(const wcs_wifi_ap_config_t *config);
esp_err_t wcs_wifi_ap_stop(void);
bool wcs_wifi_ap_is_running(void);

esp_err_t wcs_wifi_ap_get_ip(esp_ip4_addr_t *ip);

typedef struct {
    char ssid[33];
    int8_t rssi;
    bool secured;
} wcs_wifi_network_t;

esp_err_t wcs_wifi_scan(wcs_wifi_network_t *networks, size_t max, size_t *count);

typedef enum {
    WCS_WIFI_STA_IDLE,
    WCS_WIFI_STA_CONNECTING,
    WCS_WIFI_STA_CONNECTED,
    WCS_WIFI_STA_FAILED,
} wcs_wifi_sta_state_t;

typedef enum {
    WCS_WIFI_FAIL_NONE,
    WCS_WIFI_FAIL_WRONG_PASSWORD,
    WCS_WIFI_FAIL_NOT_FOUND,
    WCS_WIFI_FAIL_OTHER,
} wcs_wifi_fail_t;

typedef struct {
    wcs_wifi_sta_state_t state;
    char ssid[33];
    esp_ip4_addr_t ip;
    wcs_wifi_fail_t fail;
    uint8_t fail_reason;
} wcs_wifi_sta_status_t;

esp_err_t wcs_wifi_sta_connect(const char *ssid, const char *password, bool auto_reconnect);
esp_err_t wcs_wifi_sta_disconnect(void);
void wcs_wifi_sta_get_status(wcs_wifi_sta_status_t *status);
