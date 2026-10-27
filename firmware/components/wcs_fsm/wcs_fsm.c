#include "wcs_fsm.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "esp_app_desc.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "wcs_auth.h"
#include "wcs_button.h"
#include "wcs_defaults.h"
#include "wcs_led.h"
#include "wcs_link.h"
#include "wcs_storage.h"
#include "wcs_tls.h"
#include "wcs_web.h"
#include "wcs_wifi.h"

#define WEB_HOST                "192.168.4.1"
#define WEB_URL                 "https://" WEB_HOST "/"
#define DEVICE_NAME_PREFIX      "esp-wcs-"

#define APPLY_DELAY_MS          1500
#define FACTORY_RESET_DELAY_MS  1000
#define CMD_QUEUE_LEN           8
#define TASK_PRIORITY           5

typedef enum {
    CMD_BUTTON_CLICK,
    CMD_BUTTON_LONG,
    CMD_BUTTON_VERY_LONG,
    CMD_BUTTON_TRIPLE_CLICK,
    CMD_AP_CLIENT_JOINED,
    CMD_AP_CLIENT_LEFT,
    CMD_AP_IDLE_TIMEOUT,
    CMD_APPLY,
    CMD_LINK_STATE,
} app_cmd_t;

typedef enum {
    INDICATION_FACTORY,
    INDICATION_SETUP_WAITING,
    INDICATION_SETUP_CONNECTED,
    INDICATION_DIRECT_IDLE,
    INDICATION_DIRECT_WAITING,
    INDICATION_DIRECT_CONNECTED,
    INDICATION_BASTION_CONNECTING,
    INDICATION_BASTION_PENDING,
    INDICATION_BASTION_ONLINE,
    INDICATION_BASTION_OFFLINE,
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
    [INDICATION_BASTION_PENDING] = { WCS_LED_YELLOW, WCS_LED_BREATHE },
    [INDICATION_BASTION_ONLINE] = { WCS_LED_PURPLE, WCS_LED_SOLID },
    [INDICATION_BASTION_OFFLINE] = { WCS_LED_RED, WCS_LED_BREATHE },
    [INDICATION_ERROR] = { WCS_LED_RED, WCS_LED_BLINK_FAST },
};

static const wcs_led_indication_t s_hint_setup = { WCS_LED_BLUE, WCS_LED_BLINK_FAST };
static const wcs_led_indication_t s_hint_reset = { WCS_LED_RED, WCS_LED_BLINK_FAST };

static const char *TAG = "wcs_fsm";

static QueueHandle_t s_cmd_queue;
static esp_timer_handle_t s_ap_idle_timer;
static volatile wcs_fsm_state_t s_state;
static int s_ap_clients;
static bool s_error;
static char s_setup_ssid[33];
static char s_direct_ssid[33];
static char s_direct_ap_ssid[WCS_SSID_MAX_LEN + 1];
static char s_direct_ap_password[WCS_WIFI_PASSWORD_MAX_LEN + 1];
static char s_device_name[33];

static void update_led(void)
{
    indication_t ind;

    if (s_error) {
        ind = INDICATION_ERROR;
    } else {
        switch (s_state) {
        case WCS_FSM_STATE_SETUP:
            ind = s_ap_clients ? INDICATION_SETUP_CONNECTED : INDICATION_SETUP_WAITING;
            break;
        case WCS_FSM_STATE_DIRECT:
            ind = !wcs_wifi_ap_is_running() ? INDICATION_DIRECT_IDLE
                  : s_ap_clients            ? INDICATION_DIRECT_CONNECTED
                                            : INDICATION_DIRECT_WAITING;
            break;
        case WCS_FSM_STATE_BASTION:
            switch (wcs_link_get_state()) {
            case WCS_LINK_STATE_PENDING:
                ind = INDICATION_BASTION_PENDING;
                break;
            case WCS_LINK_STATE_ONLINE:
                ind = INDICATION_BASTION_ONLINE;
                break;
            case WCS_LINK_STATE_OFFLINE:
                ind = INDICATION_BASTION_OFFLINE;
                break;
            default:
                ind = INDICATION_BASTION_CONNECTING;
                break;
            }
            break;
        case WCS_FSM_STATE_FACTORY:
        default:
            ind = INDICATION_FACTORY;
            break;
        }
    }
    wcs_led_set_base(s_indications[ind]);
}

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
        send_cmd(CMD_BUTTON_VERY_LONG);
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

static void on_link(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    send_cmd(CMD_LINK_STATE);
}

static void on_ap_idle_timer(void *arg)
{
    send_cmd(CMD_AP_IDLE_TIMEOUT);
}

static esp_err_t on_web_apply(const wcs_settings_t *settings)
{
    esp_err_t err = wcs_storage_save(settings);
    if (err == ESP_OK) {
        send_cmd(CMD_APPLY);
    }
    return err;
}

static void make_ssid(const char *prefix, char out[33])
{
    uint8_t mac[6];
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP));
    snprintf(out, 33, "%s%02X%02X", prefix, mac[4], mac[5]);
}

static void update_ap_idle_timer(void)
{
    esp_timer_stop(s_ap_idle_timer);
    if (wcs_wifi_ap_is_running() && s_ap_clients == 0) {
        esp_timer_start_once(s_ap_idle_timer, (uint64_t)CONFIG_WCS_FSM_AP_IDLE_TIMEOUT_MIN * 60 * 1000000);
    }
}

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
        .channel = CONFIG_WCS_FSM_AP_CHANNEL,
        .max_clients = CONFIG_WCS_FSM_AP_MAX_CLIENTS,
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

static void load_direct_credentials(void)
{
    wcs_settings_t settings;
    if (wcs_storage_load(&settings) != ESP_OK) {
        memset(&settings, 0, sizeof(settings));
    }
    strlcpy(s_direct_ap_ssid, settings.direct_ssid[0] ? settings.direct_ssid : s_direct_ssid,
            sizeof(s_direct_ap_ssid));
    strlcpy(s_direct_ap_password,
            settings.direct_password[0] ? settings.direct_password : wcs_defaults.direct_ap_password,
            sizeof(s_direct_ap_password));
    memset(&settings, 0, sizeof(settings));
}

static void enter_setup(void)
{
    ESP_LOGI(TAG, "-> setup");
    wcs_link_stop();
    stop_access_point();
    wcs_wifi_sta_disconnect();
    s_error = false;
    s_state = WCS_FSM_STATE_SETUP;

    load_direct_credentials();
    const wcs_web_config_t web = {
        .mode = WCS_WEB_MODE_SETUP,
        .host = WEB_HOST,
        .direct = { .ssid = s_direct_ap_ssid, .password = s_direct_ap_password, .url = WEB_URL },
        .apply = on_web_apply,
    };
    start_access_point(s_setup_ssid, wcs_defaults.setup_ap_password, &web);
}

static void start_direct_access_point(void)
{
    load_direct_credentials();
    const wcs_web_config_t web = { .mode = WCS_WEB_MODE_DIRECT, .host = WEB_HOST };
    start_access_point(s_direct_ap_ssid, s_direct_ap_password, &web);
}

static void enter_direct(bool raise_ap)
{
    ESP_LOGI(TAG, "-> direct");
    wcs_link_stop();
    stop_access_point();
    wcs_wifi_sta_disconnect();
    s_error = false;
    s_state = WCS_FSM_STATE_DIRECT;
    if (raise_ap) {
        start_direct_access_point();
    }
}

static void enter_bastion(const wcs_settings_t *settings)
{
    ESP_LOGI(TAG, "-> bastion, network \"%s\", bastion %s", settings->sta_ssid, settings->bastion_addr);
    stop_access_point();
    s_error = false;
    s_state = WCS_FSM_STATE_BASTION;
    if (wcs_wifi_sta_connect(settings->sta_ssid, settings->sta_password, true) != ESP_OK) {
        s_error = true;
        return;
    }

    wcs_link_stop();
    const wcs_link_config_t link = {
        .bastion_addr = settings->bastion_addr,
        .name = s_device_name,
        .firmware = esp_app_get_description()->version,
    };
    if (wcs_link_start(&link) != ESP_OK) {
        s_error = true;
    }
}

static void switch_to_direct(void)
{
    if (s_state == WCS_FSM_STATE_DIRECT) {
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
        wcs_link_stop();
        stop_access_point();
        wcs_wifi_sta_disconnect();
        s_state = WCS_FSM_STATE_FACTORY;
        break;
    }
}

static void factory_reset(void)
{
    ESP_LOGW(TAG, "factory reset");
    wcs_link_stop();
    stop_access_point();
    wcs_wifi_sta_disconnect();
    if (wcs_storage_erase() != ESP_OK) {
        ESP_LOGE(TAG, "settings erase failed");
    }
    if (wcs_link_forget_identity() != ESP_OK) {
        ESP_LOGE(TAG, "device identity erase failed");
    }
    vTaskDelay(pdMS_TO_TICKS(FACTORY_RESET_DELAY_MS));
    esp_restart();
}

static void handle(app_cmd_t cmd)
{
    switch (cmd) {
    case CMD_BUTTON_CLICK:
        if (s_state == WCS_FSM_STATE_DIRECT && !wcs_wifi_ap_is_running()) {
            start_direct_access_point();
        }
        break;
    case CMD_BUTTON_LONG:
        if (s_state != WCS_FSM_STATE_SETUP) {
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
        if (!wcs_wifi_ap_is_running() || s_ap_clients > 0) {
            break;
        }
        ESP_LOGI(TAG, "access point idle for %d min, closing", CONFIG_WCS_FSM_AP_IDLE_TIMEOUT_MIN);
        if (s_state == WCS_FSM_STATE_SETUP) {
            enter_saved_mode(false);
        } else {
            stop_access_point();
        }
        break;
    case CMD_LINK_STATE:
        break;
    case CMD_APPLY:
        if (s_state == WCS_FSM_STATE_SETUP) {
            vTaskDelay(pdMS_TO_TICKS(APPLY_DELAY_MS));
            enter_saved_mode(true);
        }
        break;
    }
    update_led();
}

static void fsm_task(void *arg)
{
    for (;;) {
        app_cmd_t cmd;
        if (xQueueReceive(s_cmd_queue, &cmd, portMAX_DELAY) == pdTRUE) {
            handle(cmd);
        }
    }
}

static void init_tls(void)
{
    wcs_tls_identity_t tls = { .common_name = s_device_name };
    esp_netif_str_to_ip4(WEB_HOST, &tls.ip);
    if (wcs_tls_init(&tls) != ESP_OK) {
        ESP_LOGE(TAG, "TLS init failed, web interface unavailable");
        s_error = true;
    }
}

esp_err_t wcs_fsm_start(const wcs_fsm_config_t *config)
{
    ESP_RETURN_ON_FALSE(config, ESP_ERR_INVALID_ARG, TAG, "config is NULL");
    ESP_RETURN_ON_FALSE(!s_cmd_queue, ESP_ERR_INVALID_STATE, TAG, "already started");

    make_ssid(wcs_defaults.setup_ap_ssid_prefix, s_setup_ssid);
    make_ssid(wcs_defaults.direct_ap_ssid_prefix, s_direct_ssid);
    make_ssid(DEVICE_NAME_PREFIX, s_device_name);
    for (char *p = s_device_name; *p; p++) {
        *p = (char)tolower((unsigned char)*p);
    }
    init_tls();
    if (wcs_link_identity_init() != ESP_OK) {
        ESP_LOGE(TAG, "device identity init failed, Bastion mode unavailable");
        s_error = true;
    }

    s_cmd_queue = xQueueCreate(CMD_QUEUE_LEN, sizeof(app_cmd_t));
    ESP_RETURN_ON_FALSE(s_cmd_queue, ESP_ERR_NO_MEM, TAG, "queue create failed");
    ESP_RETURN_ON_ERROR(esp_event_handler_register(WCS_BUTTON_EVENT, ESP_EVENT_ANY_ID, on_button, NULL),
                        TAG, "button handler");
    ESP_RETURN_ON_ERROR(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi, NULL),
                        TAG, "wifi handler");
    ESP_RETURN_ON_ERROR(esp_event_handler_register(WCS_LINK_EVENT, WCS_LINK_EVENT_STATE, on_link, NULL),
                        TAG, "link handler");
    const esp_timer_create_args_t idle_timer = { .callback = on_ap_idle_timer, .name = "ap_idle" };
    ESP_RETURN_ON_ERROR(esp_timer_create(&idle_timer, &s_ap_idle_timer), TAG, "timer create failed");

    enter_saved_mode(false);
    update_led();

    const wcs_button_config_t button = {
        .gpio = config->button_gpio,
        .active_level = config->button_active_level,
        .click_max_ms = CONFIG_WCS_FSM_BUTTON_CLICK_MAX_MS,
        .long_press_ms = CONFIG_WCS_FSM_BUTTON_LONG_MS,
        .very_long_press_ms = CONFIG_WCS_FSM_BUTTON_VERY_LONG_MS,
        .multi_click_gap_ms = CONFIG_WCS_FSM_MULTI_CLICK_GAP_MS,
    };
    ESP_RETURN_ON_ERROR(wcs_button_init(&button), TAG, "button init failed");

    BaseType_t ok = xTaskCreate(fsm_task, "wcs_fsm", CONFIG_WCS_FSM_TASK_STACK_SIZE, NULL, TASK_PRIORITY, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "task create failed");

    ESP_LOGI(TAG, "ready: hold button %d s for setup, %d s for factory reset, triple click for direct",
             CONFIG_WCS_FSM_BUTTON_LONG_MS / 1000, CONFIG_WCS_FSM_BUTTON_VERY_LONG_MS / 1000);
    return ESP_OK;
}

wcs_fsm_state_t wcs_fsm_get_state(void)
{
    return s_state;
}
