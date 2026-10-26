#include "wcs_wifi.h"

#include <string.h>

#include "esp_check.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_wifi.h"

static const char *TAG = "wcs_wifi";

static esp_netif_t *s_ap_netif;
static bool s_ap_running;
static char s_captive_portal_uri[64]; /* DHCP-сервер хранит указатель, а не копию */

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (id == WIFI_EVENT_AP_STACONNECTED) {
        const wifi_event_ap_staconnected_t *e = data;
        ESP_LOGI(TAG, "client " MACSTR " connected, aid=%d", MAC2STR(e->mac), e->aid);
    } else if (id == WIFI_EVENT_AP_STADISCONNECTED) {
        const wifi_event_ap_stadisconnected_t *e = data;
        ESP_LOGI(TAG, "client " MACSTR " disconnected, reason=%d", MAC2STR(e->mac), e->reason);
    }
}

/* Драйвер Wi-Fi поднимается один раз, при первом запуске точки доступа */
static esp_err_t wifi_init_once(void)
{
    if (s_ap_netif) {
        return ESP_OK;
    }

    s_ap_netif = esp_netif_create_default_wifi_ap();
    ESP_RETURN_ON_FALSE(s_ap_netif, ESP_FAIL, TAG, "netif create failed");

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "esp_wifi_init failed");
    /* Настройки Wi-Fi хранит наше приложение, драйверу писать в NVS незачем */
    ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), TAG, "set storage failed");
    ESP_RETURN_ON_ERROR(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, on_wifi_event, NULL),
                        TAG, "event register failed");
    return ESP_OK;
}

/* Телефоны и ноутбуки с поддержкой RFC 8910 открывают портал сразу по этой опции,
 * не дожидаясь проверки доступа в интернет */
static esp_err_t set_captive_portal_uri(const char *uri)
{
    if (!uri) {
        return ESP_OK;
    }
    ESP_RETURN_ON_FALSE(strlen(uri) < sizeof(s_captive_portal_uri), ESP_ERR_INVALID_ARG, TAG, "captive portal URI too long");
    strcpy(s_captive_portal_uri, uri);

    esp_netif_dhcps_stop(s_ap_netif);
    ESP_RETURN_ON_ERROR(esp_netif_dhcps_option(s_ap_netif, ESP_NETIF_OP_SET, ESP_NETIF_CAPTIVEPORTAL_URI,
                                               s_captive_portal_uri, strlen(s_captive_portal_uri)),
                        TAG, "set captive portal URI failed");
    return esp_netif_dhcps_start(s_ap_netif);
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
    ESP_RETURN_ON_ERROR(set_captive_portal_uri(config->captive_portal_uri), TAG, "DHCP setup failed");

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

    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_AP), TAG, "set mode failed");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_AP, &wifi_config), TAG, "set config failed");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start failed");

    s_ap_running = true;
    ESP_LOGI(TAG, "AP \"%s\" started, channel %u, max clients %u",
             config->ssid, config->channel, config->max_clients);
    return ESP_OK;
}

esp_err_t wcs_wifi_ap_stop(void)
{
    if (!s_ap_running) {
        return ESP_OK;
    }
    ESP_RETURN_ON_ERROR(esp_wifi_stop(), TAG, "wifi stop failed");
    s_ap_running = false;
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
