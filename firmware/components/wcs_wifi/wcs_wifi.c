#include "wcs_wifi.h"

#include <stdlib.h>
#include <string.h>

#include "esp_check.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_wifi.h"

#define SCAN_MAX_RECORDS       32
#define STA_CHECK_ATTEMPTS     3     /* попыток при проверке сети без auto_reconnect */
#define STA_RETRY_MIN_MS       1000
#define STA_RETRY_MAX_MS       30000

static const char *TAG = "wcs_wifi";

static esp_netif_t *s_ap_netif;
static esp_netif_t *s_sta_netif;
static esp_timer_handle_t s_retry_timer;
static bool s_started;
static bool s_ap_running;
static bool s_sta_enabled;

/* Состояние клиента меняется в задаче событий, читается из любой */
static portMUX_TYPE s_sta_lock = portMUX_INITIALIZER_UNLOCKED;
static wcs_wifi_sta_status_t s_sta;
static bool s_sta_auto_reconnect;
static bool s_sta_connect_pending;
static int s_sta_attempts;
static uint32_t s_sta_retry_ms;

static void set_sta_state(wcs_wifi_sta_state_t state, wcs_wifi_fail_t fail, uint8_t reason)
{
    portENTER_CRITICAL(&s_sta_lock);
    s_sta.state = state;
    s_sta.fail = fail;
    s_sta.fail_reason = reason;
    if (state != WCS_WIFI_STA_CONNECTED) {
        s_sta.ip.addr = 0;
    }
    portEXIT_CRITICAL(&s_sta_lock);
}

static wcs_wifi_fail_t classify_reason(uint8_t reason)
{
    switch (reason) {
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_AUTH_FAIL:
    case WIFI_REASON_AUTH_EXPIRE:
    case WIFI_REASON_MIC_FAILURE:
        return WCS_WIFI_FAIL_WRONG_PASSWORD;
    case WIFI_REASON_NO_AP_FOUND:
    case WIFI_REASON_NO_AP_FOUND_W_COMPATIBLE_SECURITY:
    case WIFI_REASON_NO_AP_FOUND_IN_AUTHMODE_THRESHOLD:
    case WIFI_REASON_NO_AP_FOUND_IN_RSSI_THRESHOLD:
        return WCS_WIFI_FAIL_NOT_FOUND;
    default:
        return WCS_WIFI_FAIL_OTHER;
    }
}

static void sta_try_connect(void)
{
    s_sta_attempts++;
    if (esp_wifi_connect() == ESP_OK) {
        s_sta_connect_pending = false;
    } else {
        s_sta_connect_pending = true; /* подключимся по WIFI_EVENT_STA_START */
    }
}

static void on_retry_timer(void *arg)
{
    if (s_sta_enabled) {
        sta_try_connect();
    }
}

static void on_sta_disconnected(const wifi_event_sta_disconnected_t *e)
{
    /* Отключение по нашей команде (новое подключение или остановка) — не ошибка */
    if (e->reason == WIFI_REASON_ASSOC_LEAVE || !s_sta_enabled) {
        return;
    }
    ESP_LOGW(TAG, "STA disconnected from \"%.*s\", reason %u", e->ssid_len, e->ssid, e->reason);

    if (s_sta_auto_reconnect) {
        set_sta_state(WCS_WIFI_STA_CONNECTING, WCS_WIFI_FAIL_NONE, e->reason);
        esp_timer_start_once(s_retry_timer, (uint64_t)s_sta_retry_ms * 1000);
        s_sta_retry_ms = s_sta_retry_ms * 2 > STA_RETRY_MAX_MS ? STA_RETRY_MAX_MS : s_sta_retry_ms * 2;
        return;
    }

    wcs_wifi_fail_t fail = classify_reason(e->reason);
    if (fail != WCS_WIFI_FAIL_WRONG_PASSWORD && s_sta_attempts < STA_CHECK_ATTEMPTS) {
        sta_try_connect();
        return;
    }
    set_sta_state(WCS_WIFI_STA_FAILED, fail, e->reason);
}

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    switch (id) {
    case WIFI_EVENT_AP_STACONNECTED: {
        const wifi_event_ap_staconnected_t *e = data;
        ESP_LOGI(TAG, "client " MACSTR " connected, aid=%d", MAC2STR(e->mac), e->aid);
        break;
    }
    case WIFI_EVENT_AP_STADISCONNECTED: {
        const wifi_event_ap_stadisconnected_t *e = data;
        ESP_LOGI(TAG, "client " MACSTR " disconnected, reason=%d", MAC2STR(e->mac), e->reason);
        break;
    }
    case WIFI_EVENT_STA_START:
        if (s_sta_connect_pending && s_sta_enabled) {
            sta_try_connect();
        }
        break;
    case WIFI_EVENT_STA_DISCONNECTED:
        on_sta_disconnected(data);
        break;
    default:
        break;
    }
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    const ip_event_got_ip_t *e = data;
    portENTER_CRITICAL(&s_sta_lock);
    s_sta.state = WCS_WIFI_STA_CONNECTED;
    s_sta.fail = WCS_WIFI_FAIL_NONE;
    s_sta.ip = e->ip_info.ip;
    portEXIT_CRITICAL(&s_sta_lock);
    s_sta_retry_ms = STA_RETRY_MIN_MS;
    ESP_LOGI(TAG, "STA connected, ip " IPSTR, IP2STR(&e->ip_info.ip));
}

/* Драйвер Wi-Fi поднимается один раз, при первом использовании */
static esp_err_t wifi_init_once(void)
{
    if (s_ap_netif) {
        return ESP_OK;
    }

    s_ap_netif = esp_netif_create_default_wifi_ap();
    s_sta_netif = esp_netif_create_default_wifi_sta();
    ESP_RETURN_ON_FALSE(s_ap_netif && s_sta_netif, ESP_FAIL, TAG, "netif create failed");

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "esp_wifi_init failed");
    /* Настройки Wi-Fi хранит наше приложение, драйверу писать в NVS незачем */
    ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), TAG, "set storage failed");
    ESP_RETURN_ON_ERROR(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi_event, NULL),
                        TAG, "event register failed");
    ESP_RETURN_ON_ERROR(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_ip_event, NULL),
                        TAG, "event register failed");

    const esp_timer_create_args_t timer_args = { .callback = on_retry_timer, .name = "wcs_wifi_retry" };
    ESP_RETURN_ON_ERROR(esp_timer_create(&timer_args, &s_retry_timer), TAG, "timer create failed");
    return ESP_OK;
}

/* Режим драйвера по тому, что сейчас нужно: точка доступа и/или клиент */
static esp_err_t apply_mode(void)
{
    wifi_mode_t mode = WIFI_MODE_NULL;
    if (s_ap_running && s_sta_enabled) {
        mode = WIFI_MODE_APSTA;
    } else if (s_ap_running) {
        mode = WIFI_MODE_AP;
    } else if (s_sta_enabled) {
        mode = WIFI_MODE_STA;
    }

    if (mode == WIFI_MODE_NULL) {
        if (s_started) {
            ESP_RETURN_ON_ERROR(esp_wifi_stop(), TAG, "wifi stop failed");
            s_started = false;
        }
        return ESP_OK;
    }

    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(mode), TAG, "set mode failed");
    if (!s_started) {
        ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start failed");
        s_started = true;
    }
    return ESP_OK;
}

esp_err_t wcs_wifi_ap_start(const wcs_wifi_ap_config_t *config)
{
    ESP_RETURN_ON_FALSE(config && config->ssid && config->password, ESP_ERR_INVALID_ARG, TAG, "invalid config");
    size_t ssid_len = strlen(config->ssid);
    size_t pass_len = strlen(config->password);
    ESP_RETURN_ON_FALSE(ssid_len >= 1 && ssid_len <= 32, ESP_ERR_INVALID_ARG, TAG, "SSID length must be 1..32");
    ESP_RETURN_ON_FALSE(pass_len >= 8 && pass_len <= 63, ESP_ERR_INVALID_ARG, TAG, "password length must be 8..63");
    ESP_RETURN_ON_FALSE(!s_ap_running, ESP_ERR_INVALID_STATE, TAG, "AP already running");

    ESP_RETURN_ON_ERROR(wifi_init_once(), TAG, "wifi init failed");

    wifi_config_t wifi_config = {
        .ap = {
            .ssid_len = ssid_len,
            .channel = config->channel,
            .max_connection = config->max_clients,
            .authmode = WIFI_AUTH_WPA2_WPA3_PSK,
            .sae_pwe_h2e = WPA3_SAE_PWE_BOTH,
            .pmf_cfg = { .capable = true, .required = false },
        },
    };
    memcpy(wifi_config.ap.ssid, config->ssid, ssid_len);
    memcpy(wifi_config.ap.password, config->password, pass_len);

    s_ap_running = true;
    esp_err_t err = apply_mode();
    if (err == ESP_OK) {
        err = esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    }
    if (err != ESP_OK) {
        s_ap_running = false;
        apply_mode();
        return err;
    }

    ESP_LOGI(TAG, "AP \"%s\" started, channel %u, max clients %u",
             config->ssid, config->channel, config->max_clients);
    return ESP_OK;
}

esp_err_t wcs_wifi_ap_stop(void)
{
    if (!s_ap_running) {
        return ESP_OK;
    }
    s_ap_running = false;
    ESP_RETURN_ON_ERROR(apply_mode(), TAG, "mode change failed");
    ESP_LOGI(TAG, "AP stopped");
    return ESP_OK;
}

bool wcs_wifi_ap_is_running(void)
{
    return s_ap_running;
}

esp_err_t wcs_wifi_ap_get_ip(esp_ip4_addr_t *ip)
{
    ESP_RETURN_ON_FALSE(ip, ESP_ERR_INVALID_ARG, TAG, "ip is NULL");
    ESP_RETURN_ON_FALSE(s_ap_netif, ESP_ERR_INVALID_STATE, TAG, "AP not initialized");

    esp_netif_ip_info_t info;
    ESP_RETURN_ON_ERROR(esp_netif_get_ip_info(s_ap_netif, &info), TAG, "get ip failed");
    *ip = info.ip;
    return ESP_OK;
}

static int compare_rssi(const void *a, const void *b)
{
    return ((const wcs_wifi_network_t *)b)->rssi - ((const wcs_wifi_network_t *)a)->rssi;
}

esp_err_t wcs_wifi_scan(wcs_wifi_network_t *networks, size_t max, size_t *count)
{
    ESP_RETURN_ON_FALSE(networks && count, ESP_ERR_INVALID_ARG, TAG, "invalid args");
    ESP_RETURN_ON_FALSE(s_started, ESP_ERR_INVALID_STATE, TAG, "wifi not started");
    *count = 0;

    /* Поиск идёт через интерфейс клиента */
    if (!s_sta_enabled) {
        s_sta_enabled = true;
        set_sta_state(WCS_WIFI_STA_IDLE, WCS_WIFI_FAIL_NONE, 0);
        ESP_RETURN_ON_ERROR(apply_mode(), TAG, "enable STA failed");
    }

    ESP_RETURN_ON_ERROR(esp_wifi_scan_start(NULL, true), TAG, "scan failed");

    uint16_t found = SCAN_MAX_RECORDS;
    wifi_ap_record_t *records = calloc(found, sizeof(*records));
    ESP_RETURN_ON_FALSE(records, ESP_ERR_NO_MEM, TAG, "no memory for scan results");
    esp_err_t err = esp_wifi_scan_get_ap_records(&found, records);
    if (err != ESP_OK) {
        free(records);
        return err;
    }

    for (uint16_t i = 0; i < found; i++) {
        const char *ssid = (const char *)records[i].ssid;
        if (ssid[0] == '\0') {
            continue; /* скрытая сеть */
        }
        size_t j = 0;
        while (j < *count && strcmp(networks[j].ssid, ssid) != 0) {
            j++;
        }
        if (j < *count) {
            if (records[i].rssi > networks[j].rssi) {
                networks[j].rssi = records[i].rssi;
            }
            continue;
        }
        if (*count == max) {
            continue;
        }
        wcs_wifi_network_t *n = &networks[(*count)++];
        strlcpy(n->ssid, ssid, sizeof(n->ssid));
        n->rssi = records[i].rssi;
        n->secured = records[i].authmode != WIFI_AUTH_OPEN && records[i].authmode != WIFI_AUTH_OWE;
    }
    free(records);

    qsort(networks, *count, sizeof(*networks), compare_rssi);
    ESP_LOGI(TAG, "scan: %u networks", (unsigned)*count);
    return ESP_OK;
}

esp_err_t wcs_wifi_sta_connect(const char *ssid, const char *password, bool auto_reconnect)
{
    ESP_RETURN_ON_FALSE(ssid && password, ESP_ERR_INVALID_ARG, TAG, "invalid args");
    size_t ssid_len = strlen(ssid);
    size_t pass_len = strlen(password);
    ESP_RETURN_ON_FALSE(ssid_len >= 1 && ssid_len <= 32, ESP_ERR_INVALID_ARG, TAG, "SSID length must be 1..32");
    ESP_RETURN_ON_FALSE(pass_len == 0 || (pass_len >= 8 && pass_len <= 64), ESP_ERR_INVALID_ARG, TAG,
                        "password length must be 0 or 8..64");

    ESP_RETURN_ON_ERROR(wifi_init_once(), TAG, "wifi init failed");
    esp_timer_stop(s_retry_timer);
    if (s_sta_enabled) {
        esp_wifi_disconnect();
    }

    wifi_config_t wifi_config = {
        .sta = {
            .threshold.authmode = pass_len ? WIFI_AUTH_WPA_PSK : WIFI_AUTH_OPEN,
            .sae_pwe_h2e = WPA3_SAE_PWE_BOTH,
            .pmf_cfg = { .capable = true, .required = false },
        },
    };
    memcpy(wifi_config.sta.ssid, ssid, ssid_len);
    memcpy(wifi_config.sta.password, password, pass_len);

    s_sta_enabled = true;
    s_sta_auto_reconnect = auto_reconnect;
    s_sta_attempts = 0;
    s_sta_retry_ms = STA_RETRY_MIN_MS;

    portENTER_CRITICAL(&s_sta_lock);
    memset(&s_sta, 0, sizeof(s_sta));
    s_sta.state = WCS_WIFI_STA_CONNECTING;
    memcpy(s_sta.ssid, ssid, ssid_len);
    portEXIT_CRITICAL(&s_sta_lock);

    ESP_RETURN_ON_ERROR(apply_mode(), TAG, "enable STA failed");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &wifi_config), TAG, "set config failed");
    ESP_LOGI(TAG, "STA connecting to \"%s\"%s", ssid, auto_reconnect ? " (auto reconnect)" : "");
    sta_try_connect();
    return ESP_OK;
}

esp_err_t wcs_wifi_sta_disconnect(void)
{
    if (!s_sta_enabled) {
        return ESP_OK;
    }
    esp_timer_stop(s_retry_timer);
    s_sta_enabled = false;
    s_sta_connect_pending = false;
    esp_wifi_disconnect();
    set_sta_state(WCS_WIFI_STA_IDLE, WCS_WIFI_FAIL_NONE, 0);
    ESP_RETURN_ON_ERROR(apply_mode(), TAG, "mode change failed");
    ESP_LOGI(TAG, "STA stopped");
    return ESP_OK;
}

void wcs_wifi_sta_get_status(wcs_wifi_sta_status_t *status)
{
    portENTER_CRITICAL(&s_sta_lock);
    *status = s_sta;
    portEXIT_CRITICAL(&s_sta_lock);
}
