/*
 * Веб-интерфейс устройства: вход администратора и страница настроек.
 *
 * Работает как captive portal: любой неизвестный адрес перенаправляется на
 * страницу входа. Пока HTTP; HTTPS — отдельный этап (ТЗ, этап 1, пункт 3).
 */
#pragma once

#include "esp_err.h"
#include "esp_netif_ip_addr.h"

typedef struct {
    esp_ip4_addr_t portal_ip; /* адрес, на который перенаправлять неизвестные запросы */
} wcs_web_config_t;

esp_err_t wcs_web_start(const wcs_web_config_t *config);
esp_err_t wcs_web_stop(void);
