/*
 * Wi-Fi устройства: точка доступа (WPA2/WPA3) и подключение к сети (клиент).
 * Точка доступа и клиент могут работать одновременно.
 *
 * Радио одно: когда клиент подключается к сети на другом канале, точка доступа
 * переходит на тот же канал, и её клиенты могут на несколько секунд отключиться.
 *
 * До первого вызова должны быть выполнены nvs_flash_init(), esp_netif_init()
 * и esp_event_loop_create_default(). Функции, меняющие режим (start/stop/connect/scan),
 * не вызывать одновременно из разных задач; wcs_wifi_sta_get_status() — из любой.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_netif_ip_addr.h"

/* ---- точка доступа ---- */

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

/* ---- поиск сетей ---- */

typedef struct {
    char ssid[33];
    int8_t rssi;  /* дБм */
    bool secured; /* нужен пароль */
} wcs_wifi_network_t;

/*
 * Ищет сети (блокирует на 2–4 с). Скрытые сети пропускаются, одинаковые
 * имена объединяются, результат отсортирован по уровню сигнала.
 */
esp_err_t wcs_wifi_scan(wcs_wifi_network_t *networks, size_t max, size_t *count);

/* ---- клиент ---- */

typedef enum {
    WCS_WIFI_STA_IDLE,
    WCS_WIFI_STA_CONNECTING,
    WCS_WIFI_STA_CONNECTED,
    WCS_WIFI_STA_FAILED, /* только без auto_reconnect */
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
    esp_ip4_addr_t ip;       /* при WCS_WIFI_STA_CONNECTED */
    wcs_wifi_fail_t fail;    /* при WCS_WIFI_STA_FAILED */
    uint8_t fail_reason;     /* код причины от драйвера, для логов */
} wcs_wifi_sta_status_t;

/*
 * Начинает подключение и сразу возвращается; ход — через wcs_wifi_sta_get_status().
 * password — пустая строка для открытой сети.
 * auto_reconnect = false: после нескольких неудачных попыток — WCS_WIFI_STA_FAILED
 * (проверка сети при настройке). true: переподключаться бесконечно с нарастающей паузой.
 */
esp_err_t wcs_wifi_sta_connect(const char *ssid, const char *password, bool auto_reconnect);
esp_err_t wcs_wifi_sta_disconnect(void);
void wcs_wifi_sta_get_status(wcs_wifi_sta_status_t *status);
