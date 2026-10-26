/*
 * Wi-Fi устройства. Пока только точка доступа (WPA2/WPA3).
 *
 * До первого вызова должны быть выполнены nvs_flash_init(), esp_netif_init()
 * и esp_event_loop_create_default().
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_netif_ip_addr.h"

typedef struct {
    const char *ssid;     /* до 32 символов */
    const char *password; /* от 8 до 63 символов */
    uint8_t channel;
    uint8_t max_clients;
} wcs_wifi_ap_config_t;

esp_err_t wcs_wifi_ap_start(const wcs_wifi_ap_config_t *config);
esp_err_t wcs_wifi_ap_stop(void);
bool wcs_wifi_ap_is_running(void);

/* Адрес устройства в сети точки доступа (по умолчанию 192.168.4.1) */
esp_err_t wcs_wifi_ap_get_ip(esp_ip4_addr_t *ip);
