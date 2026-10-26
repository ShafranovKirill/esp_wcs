/*
 * ESP WCS — беспроводной консольный сервер.
 * Точка входа прошивки: инициализация и реакция на кнопку.
 *
 * Пока реализован только вход в настройку: удержание кнопки 5 с поднимает
 * точку доступа с веб-интерфейсом. Полная машина состояний — в wcs_fsm (ТЗ, этап 1, пункт 6).
 */
#include <stdio.h>

#include "board.h"
#include "esp_app_desc.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_psram.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "nvs_flash.h"
#include "wcs_auth.h"
#include "wcs_button.h"
#include "wcs_defaults.h"
#include "wcs_dns.h"
#include "wcs_web.h"
#include "wcs_wifi.h"

/* Длительности нажатий кнопки (ТЗ, «Состояния и кнопка») */
#define BUTTON_CLICK_MAX_MS     1000
#define BUTTON_LONG_MS          5000
#define BUTTON_VERY_LONG_MS     15000

#define SETUP_AP_CHANNEL        1
#define SETUP_AP_MAX_CLIENTS    1
/* Адрес точки доступа ESP-IDF по умолчанию; объявляется клиентам через DHCP */
#define SETUP_PORTAL_URI        "http://192.168.4.1/"

typedef enum {
    APP_CMD_START_SETUP,
} app_cmd_t;

static const char *TAG = "wcs";

static QueueHandle_t s_cmd_queue;

/* Обработчик работает в задаче цикла событий с маленьким стеком,
 * поэтому тяжёлую работу передаём в основную задачу через очередь */
static void on_button(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    app_cmd_t cmd;

    switch (id) {
    case WCS_BUTTON_EVENT_LONG:
        cmd = APP_CMD_START_SETUP;
        xQueueSend(s_cmd_queue, &cmd, 0);
        break;
    case WCS_BUTTON_EVENT_CLICK:
        ESP_LOGI(TAG, "click: no action yet (Direct connection AP)");
        break;
    case WCS_BUTTON_EVENT_VERY_LONG:
        ESP_LOGI(TAG, "very long press: no action yet (factory reset)");
        break;
    default:
        break;
    }
}

static void start_setup_portal(void)
{
    if (wcs_wifi_ap_is_running()) {
        ESP_LOGI(TAG, "setup portal already running");
        return;
    }

    uint8_t mac[6];
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP));
    char ssid[33];
    snprintf(ssid, sizeof(ssid), "%s%02X%02X", wcs_defaults.setup_ap_ssid_prefix, mac[4], mac[5]);

    const wcs_wifi_ap_config_t ap = {
        .ssid = ssid,
        .password = wcs_defaults.setup_ap_password,
        .channel = SETUP_AP_CHANNEL,
        .max_clients = SETUP_AP_MAX_CLIENTS,
        .captive_portal_uri = SETUP_PORTAL_URI,
    };
    if (wcs_wifi_ap_start(&ap) != ESP_OK) {
        ESP_LOGE(TAG, "setup AP start failed");
        return;
    }

    esp_ip4_addr_t ip;
    ESP_ERROR_CHECK(wcs_wifi_ap_get_ip(&ip));
    ESP_ERROR_CHECK(wcs_dns_start(ip));
    ESP_ERROR_CHECK(wcs_web_start(&(wcs_web_config_t){ .portal_ip = ip }));
    ESP_LOGI(TAG, "setup portal: Wi-Fi \"%s\", http://" IPSTR "/", ssid, IP2STR(&ip));
}

static void init_nvs(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS partition is incompatible, erasing");
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

void app_main(void)
{
    const esp_app_desc_t *app = esp_app_get_description();

    ESP_LOGI(TAG, "%s %s (ESP-IDF %s)", app->project_name, app->version, app->idf_ver);
    ESP_LOGI(TAG, "PSRAM: %u bytes, free heap: internal %u, PSRAM %u",
             (unsigned)esp_psram_get_size(),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));

    init_nvs();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(wcs_auth_init());

    s_cmd_queue = xQueueCreate(4, sizeof(app_cmd_t));
    ESP_ERROR_CHECK(s_cmd_queue ? ESP_OK : ESP_ERR_NO_MEM);

    ESP_ERROR_CHECK(esp_event_handler_register(WCS_BUTTON_EVENT, ESP_EVENT_ANY_ID, on_button, NULL));
    const wcs_button_config_t button = {
        .gpio = BOARD_BUTTON_GPIO,
        .active_level = BOARD_BUTTON_ACTIVE_LEVEL,
        .click_max_ms = BUTTON_CLICK_MAX_MS,
        .long_press_ms = BUTTON_LONG_MS,
        .very_long_press_ms = BUTTON_VERY_LONG_MS,
    };
    ESP_ERROR_CHECK(wcs_button_init(&button));
    ESP_LOGI(TAG, "ready: hold BOOT for %d s to open setup", BUTTON_LONG_MS / 1000);

    for (;;) {
        app_cmd_t cmd;
        if (xQueueReceive(s_cmd_queue, &cmd, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        switch (cmd) {
        case APP_CMD_START_SETUP:
            start_setup_portal();
            break;
        }
    }
}
