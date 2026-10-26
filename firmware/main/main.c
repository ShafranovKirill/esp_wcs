/*
 * ESP WCS — беспроводной консольный сервер.
 * Точка входа прошивки и машина состояний устройства (ТЗ, «Состояния и кнопка»).
 *
 *   Заводское ──5 с──▶ Настройка ──применить──▶ Direct / Bastion
 *        ▲                ▲                          │
 *        └──── 15 с ──────┴────────── 5 с ───────────┘
 *
 * Три быстрых нажатия из любого состояния — сразу Direct с поднятой точкой
 * доступа, без веб-интерфейса настройки (настройки бастиона сохраняются).
 *
 * Все переходы выполняются в основной задаче: события кнопки, Wi-Fi, таймера и
 * веб-сервера приходят командами через очередь. Индикация — docs/led.md.
 *
 * Точка доступа (настройка или Direct) выключается, если к ней 10 минут никто
 * не подключён; отсчёт начинается заново, когда отключается последний клиент.
 * Позже машина состояний переедет в компонент wcs_fsm.
 */
#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "board.h"
#include "esp_app_desc.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_psram.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "nvs_flash.h"
#include "wcs_auth.h"
#include "wcs_button.h"
#include "wcs_defaults.h"
#include "wcs_led.h"
#include "wcs_storage.h"
#include "wcs_tls.h"
#include "wcs_web.h"
#include "wcs_wifi.h"

/* Длительности нажатий кнопки (ТЗ, «Состояния и кнопка») */
#define BUTTON_CLICK_MAX_MS     1000
#define BUTTON_LONG_MS          5000
#define BUTTON_VERY_LONG_MS     15000
#define BUTTON_MULTI_CLICK_GAP_MS 500

#define AP_CHANNEL              1
#define AP_MAX_CLIENTS          1
#define AP_IDLE_TIMEOUT_MS      (10 * 60 * 1000)
/* Адрес точки доступа ESP-IDF по умолчанию; веб-интерфейс — только HTTPS */
#define WEB_HOST                "192.168.4.1"
#define WEB_URL                 "https://" WEB_HOST "/"
/* Имя устройства в сертификате HTTPS: esp-wcs-8580 */
#define DEVICE_NAME_PREFIX      "esp-wcs-"

#define BOOT_FLASH_MS           500
/* Пауза перед сменой режима, чтобы браузер успел получить ответ */
#define APPLY_DELAY_MS          1500
#define FACTORY_RESET_DELAY_MS  1000

typedef enum {
    STATE_FACTORY,
    STATE_SETUP,
    STATE_DIRECT,
    STATE_BASTION,
} app_state_t;

typedef enum {
    CMD_BUTTON_CLICK,
    CMD_BUTTON_LONG,
    CMD_BUTTON_VERY_LONG,
    CMD_BUTTON_TRIPLE_CLICK,
    CMD_AP_CLIENT_JOINED,
    CMD_AP_CLIENT_LEFT,
    CMD_AP_IDLE_TIMEOUT,
    CMD_APPLY,
} app_cmd_t;

/* Что показывает светодиод (docs/led.md) */
typedef enum {
    INDICATION_FACTORY,
    INDICATION_SETUP_WAITING,
    INDICATION_SETUP_CONNECTED,
    INDICATION_DIRECT_IDLE,
    INDICATION_DIRECT_WAITING,
    INDICATION_DIRECT_CONNECTED,
    INDICATION_BASTION_CONNECTING,
    INDICATION_ERROR,
} indication_t;

static const wcs_led_indication_t s_indications[] = {
    [INDICATION_FACTORY] = { WCS_LED_WHITE, WCS_LED_SOLID },
    [INDICATION_SETUP_WAITING] = { WCS_LED_BLUE, WCS_LED_BREATHE },
    [INDICATION_SETUP_CONNECTED] = { WCS_LED_BLUE, WCS_LED_SOLID },
    [INDICATION_DIRECT_IDLE] = { WCS_LED_GREEN, WCS_LED_DIM },
    [INDICATION_DIRECT_WAITING] = { WCS_LED_GREEN, WCS_LED_BREATHE },
    [INDICATION_DIRECT_CONNECTED] = { WCS_LED_GREEN, WCS_LED_SOLID },
    [INDICATION_BASTION_CONNECTING] = { WCS_LED_PURPLE, WCS_LED_BREATHE },
    [INDICATION_ERROR] = { WCS_LED_RED, WCS_LED_BLINK_FAST },
};

/* Подсказки при удержании кнопки */
static const wcs_led_indication_t s_hint_setup = { WCS_LED_BLUE, WCS_LED_BLINK_FAST };
static const wcs_led_indication_t s_hint_reset = { WCS_LED_RED, WCS_LED_BLINK_FAST };

static const char *TAG = "wcs";

static QueueHandle_t s_cmd_queue;
static esp_timer_handle_t s_ap_idle_timer;
static app_state_t s_state;
static int s_ap_clients;
static bool s_error;
static char s_setup_ssid[33];
static char s_direct_ssid[33];

/* ---- индикация ---- */

static void update_led(void)
{
    indication_t ind;

    if (s_error) {
        ind = INDICATION_ERROR;
    } else {
        switch (s_state) {
        case STATE_SETUP:
            ind = s_ap_clients ? INDICATION_SETUP_CONNECTED : INDICATION_SETUP_WAITING;
            break;
        case STATE_DIRECT:
            ind = !wcs_wifi_ap_is_running() ? INDICATION_DIRECT_IDLE
                  : s_ap_clients            ? INDICATION_DIRECT_CONNECTED
                                            : INDICATION_DIRECT_WAITING;
            break;
        case STATE_BASTION:
            /* Связь с бастионом — этап 2; пока всегда «подключение» */
            ind = INDICATION_BASTION_CONNECTING;
            break;
        case STATE_FACTORY:
        default:
            ind = INDICATION_FACTORY;
            break;
        }
    }
    wcs_led_set_base(s_indications[ind]);
}

/* ---- команды из других задач ---- */

static void send_cmd(app_cmd_t cmd)
{
    if (xQueueSend(s_cmd_queue, &cmd, 0) != pdTRUE) {
        ESP_LOGW(TAG, "command queue full, cmd %d dropped", cmd);
    }
}

static void on_button(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    switch (id) {
    case WCS_BUTTON_EVENT_HOLD_LONG:
        wcs_led_set_overlay(s_hint_setup, 0);
        break;
    case WCS_BUTTON_EVENT_HOLD_VERY_LONG:
        wcs_led_set_overlay(s_hint_reset, 0);
        break;
    case WCS_BUTTON_EVENT_CLICK:
        send_cmd(CMD_BUTTON_CLICK);
        break;
    case WCS_BUTTON_EVENT_LONG:
        wcs_led_clear_overlay();
        send_cmd(CMD_BUTTON_LONG);
        break;
    case WCS_BUTTON_EVENT_VERY_LONG:
        send_cmd(CMD_BUTTON_VERY_LONG); /* подсказка горит до перезагрузки */
        break;
    case WCS_BUTTON_EVENT_TRIPLE_CLICK:
        send_cmd(CMD_BUTTON_TRIPLE_CLICK);
        break;
    default:
        break;
    }
}

static void on_wifi(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (id == WIFI_EVENT_AP_STACONNECTED) {
        send_cmd(CMD_AP_CLIENT_JOINED);
    } else if (id == WIFI_EVENT_AP_STADISCONNECTED) {
        send_cmd(CMD_AP_CLIENT_LEFT);
    }
}

static void on_ap_idle_timer(void *arg)
{
    send_cmd(CMD_AP_IDLE_TIMEOUT);
}

/* Вызывается веб-сервером из своей задачи */
static esp_err_t on_web_apply(const wcs_settings_t *settings)
{
    esp_err_t err = wcs_storage_save(settings);
    if (err == ESP_OK) {
        send_cmd(CMD_APPLY);
    }
    return err;
}

/* ---- переходы ---- */

static void make_ssid(const char *prefix, char out[33])
{
    uint8_t mac[6];
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP));
    snprintf(out, 33, "%s%02X%02X", prefix, mac[4], mac[5]);
}

/* Отсчёт бездействия идёт, пока точка доступа поднята и к ней никто не подключён */
static void update_ap_idle_timer(void)
{
    esp_timer_stop(s_ap_idle_timer);
    if (wcs_wifi_ap_is_running() && s_ap_clients == 0) {
        esp_timer_start_once(s_ap_idle_timer, (uint64_t)AP_IDLE_TIMEOUT_MS * 1000);
    }
}

/* Останавливает точку доступа и веб-сервер, завершает сессии прежнего режима */
static void stop_access_point(void)
{
    esp_timer_stop(s_ap_idle_timer);
    wcs_web_stop();
    wcs_wifi_ap_stop();
    wcs_auth_logout_all();
    s_ap_clients = 0;
}

static bool start_access_point(const char *ssid, const char *password, const wcs_web_config_t *web)
{
    const wcs_wifi_ap_config_t ap = {
        .ssid = ssid,
        .password = password,
        .channel = AP_CHANNEL,
        .max_clients = AP_MAX_CLIENTS,
    };
    if (wcs_wifi_ap_start(&ap) != ESP_OK || wcs_web_start(web) != ESP_OK) {
        ESP_LOGE(TAG, "access point \"%s\" start failed", ssid);
        stop_access_point();
        s_error = true;
        return false;
    }
    ESP_LOGI(TAG, "access point \"%s\", " WEB_URL, ssid);
    update_ap_idle_timer();
    return true;
}

static void enter_setup(void)
{
    ESP_LOGI(TAG, "-> setup");
    stop_access_point();
    wcs_wifi_sta_disconnect();
    s_error = false;
    s_state = STATE_SETUP;

    const wcs_web_config_t web = {
        .mode = WCS_WEB_MODE_SETUP,
        .host = WEB_HOST,
        .direct = { .ssid = s_direct_ssid, .password = wcs_defaults.direct_ap_password, .url = WEB_URL },
        .apply = on_web_apply,
    };
    start_access_point(s_setup_ssid, wcs_defaults.setup_ap_password, &web);
}

static void start_direct_access_point(void)
{
    const wcs_web_config_t web = { .mode = WCS_WEB_MODE_DIRECT, .host = WEB_HOST };
    start_access_point(s_direct_ssid, wcs_defaults.direct_ap_password, &web);
}

/* raise_ap — сразу поднять точку доступа (после настройки), иначе ждать нажатия */
static void enter_direct(bool raise_ap)
{
    ESP_LOGI(TAG, "-> direct");
    stop_access_point();
    wcs_wifi_sta_disconnect();
    s_error = false;
    s_state = STATE_DIRECT;
    if (raise_ap) {
        start_direct_access_point();
    }
}

static void enter_bastion(const wcs_settings_t *settings)
{
    ESP_LOGI(TAG, "-> bastion, network \"%s\", bastion %s", settings->sta_ssid, settings->bastion_addr);
    stop_access_point();
    s_error = false;
    s_state = STATE_BASTION;
    if (wcs_wifi_sta_connect(settings->sta_ssid, settings->sta_password, true) != ESP_OK) {
        s_error = true;
    }
}

/* Тройное нажатие: сохранить режим Direct и сразу поднять точку доступа */
static void switch_to_direct(void)
{
    if (s_state == STATE_DIRECT) {
        if (!wcs_wifi_ap_is_running()) {
            start_direct_access_point();
        }
        return;
    }

    wcs_settings_t settings;
    if (wcs_storage_load(&settings) != ESP_OK) {
        memset(&settings, 0, sizeof(settings));
    }
    settings.mode = WCS_MODE_DIRECT;
    esp_err_t err = wcs_storage_save(&settings);
    memset(&settings, 0, sizeof(settings));
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "settings save failed: %s", esp_err_to_name(err));
        s_error = true;
        return;
    }
    enter_direct(true);
}

/* Режим по сохранённым настройкам */
static void enter_saved_mode(bool raise_direct_ap)
{
    wcs_settings_t settings;
    if (wcs_storage_load(&settings) != ESP_OK) {
        ESP_LOGE(TAG, "settings load failed, using factory state");
        settings.mode = WCS_MODE_FACTORY;
    }

    switch (settings.mode) {
    case WCS_MODE_DIRECT:
        enter_direct(raise_direct_ap);
        break;
    case WCS_MODE_BASTION:
        enter_bastion(&settings);
        break;
    default:
        ESP_LOGI(TAG, "-> factory");
        stop_access_point();
        wcs_wifi_sta_disconnect();
        s_state = STATE_FACTORY;
        break;
    }
}

static void factory_reset(void)
{
    ESP_LOGW(TAG, "factory reset");
    stop_access_point();
    wcs_wifi_sta_disconnect();
    if (wcs_storage_erase() != ESP_OK) {
        ESP_LOGE(TAG, "settings erase failed");
    }
    vTaskDelay(pdMS_TO_TICKS(FACTORY_RESET_DELAY_MS));
    esp_restart();
}

static void handle(app_cmd_t cmd)
{
    switch (cmd) {
    case CMD_BUTTON_CLICK:
        /* Direct: короткое нажатие поднимает точку доступа */
        if (s_state == STATE_DIRECT && !wcs_wifi_ap_is_running()) {
            start_direct_access_point();
        }
        break;
    case CMD_BUTTON_LONG:
        if (s_state != STATE_SETUP) {
            enter_setup();
        }
        break;
    case CMD_BUTTON_VERY_LONG:
        factory_reset();
        break;
    case CMD_BUTTON_TRIPLE_CLICK:
        switch_to_direct();
        break;
    case CMD_AP_CLIENT_JOINED:
        s_ap_clients++;
        update_ap_idle_timer();
        break;
    case CMD_AP_CLIENT_LEFT:
        if (s_ap_clients > 0) {
            s_ap_clients--;
        }
        update_ap_idle_timer();
        break;
    case CMD_AP_IDLE_TIMEOUT:
        /* Таймер мог сработать до смены режима или подключения — проверяем заново */
        if (!wcs_wifi_ap_is_running() || s_ap_clients > 0) {
            break;
        }
        ESP_LOGI(TAG, "access point idle for %d min, closing", AP_IDLE_TIMEOUT_MS / 60000);
        if (s_state == STATE_SETUP) {
            enter_saved_mode(false);
        } else {
            stop_access_point();
        }
        break;
    case CMD_APPLY:
        if (s_state == STATE_SETUP) {
            vTaskDelay(pdMS_TO_TICKS(APPLY_DELAY_MS));
            enter_saved_mode(true);
        }
        break;
    }
    update_led();
}

/* ---- запуск ---- */

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

    const wcs_led_config_t led = { .gpio = BOARD_RGB_LED_GPIO, .brightness = BOARD_RGB_LED_BRIGHTNESS };
    ESP_ERROR_CHECK(wcs_led_init(&led));
    wcs_led_set_overlay((wcs_led_indication_t){ WCS_LED_WHITE, WCS_LED_SOLID }, BOOT_FLASH_MS);

    ESP_LOGI(TAG, "%s %s (ESP-IDF %s)", app->project_name, app->version, app->idf_ver);
    ESP_LOGI(TAG, "PSRAM: %u bytes, free heap: internal %u, PSRAM %u",
             (unsigned)esp_psram_get_size(),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));

    init_nvs();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(wcs_auth_init());

    make_ssid(wcs_defaults.setup_ap_ssid_prefix, s_setup_ssid);
    make_ssid(wcs_defaults.direct_ap_ssid_prefix, s_direct_ssid);

    /* Сертификат HTTPS: при первом запуске создаётся, дальше берётся из NVS */
    char device_name[33];
    make_ssid(DEVICE_NAME_PREFIX, device_name);
    for (char *p = device_name; *p; p++) {
        *p = (char)tolower((unsigned char)*p);
    }
    wcs_tls_identity_t tls = { .common_name = device_name };
    esp_netif_str_to_ip4(WEB_HOST, &tls.ip);
    if (wcs_tls_init(&tls) != ESP_OK) {
        ESP_LOGE(TAG, "TLS init failed, web interface unavailable");
        s_error = true;
    }

    s_cmd_queue = xQueueCreate(8, sizeof(app_cmd_t));
    ESP_ERROR_CHECK(s_cmd_queue ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(esp_event_handler_register(WCS_BUTTON_EVENT, ESP_EVENT_ANY_ID, on_button, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi, NULL));
    const esp_timer_create_args_t idle_timer = { .callback = on_ap_idle_timer, .name = "ap_idle" };
    ESP_ERROR_CHECK(esp_timer_create(&idle_timer, &s_ap_idle_timer));

    enter_saved_mode(false);
    update_led();

    const wcs_button_config_t button = {
        .gpio = BOARD_BUTTON_GPIO,
        .active_level = BOARD_BUTTON_ACTIVE_LEVEL,
        .click_max_ms = BUTTON_CLICK_MAX_MS,
        .long_press_ms = BUTTON_LONG_MS,
        .very_long_press_ms = BUTTON_VERY_LONG_MS,
        .multi_click_gap_ms = BUTTON_MULTI_CLICK_GAP_MS,
    };
    ESP_ERROR_CHECK(wcs_button_init(&button));
    ESP_LOGI(TAG, "ready: hold BOOT 5 s for setup, 15 s for factory reset, triple click for direct");

    for (;;) {
        app_cmd_t cmd;
        if (xQueueReceive(s_cmd_queue, &cmd, portMAX_DELAY) == pdTRUE) {
            handle(cmd);
        }
    }
}
