/*
 * DNS-сервер captive portal: на любой A-запрос отвечает адресом устройства.
 * Телефон или ноутбук после подключения к точке доступа сам открывает страницу входа.
 */
#pragma once

#include "esp_err.h"
#include "esp_netif_ip_addr.h"

esp_err_t wcs_dns_start(esp_ip4_addr_t answer_ip);
void wcs_dns_stop(void);
