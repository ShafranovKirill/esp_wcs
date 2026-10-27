#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_log.h"
#include "esp_netif_ip_addr.h"
#include "wcs_bastion.h"
#include "wcs_link.h"
#include "wcs_wifi.h"
#include "web_priv.h"

#define BODY_MAX         640
#define SCAN_MAX         24
#define SCAN_ITEM_JSON   (WCS_SSID_MAX_LEN * 6 + 64)
#define FORM_SSID_MAX    (WCS_SSID_MAX_LEN * 3 + 1)
#define FORM_PASS_MAX    (WCS_WIFI_PASSWORD_MAX_LEN * 3 + 1)
#define FORM_ADDR_MAX    (WCS_BASTION_ADDR_MAX_LEN * 3 + 1)

static const char *TAG = "wcs_web_setup";

static struct {
    char addr[WCS_BASTION_ADDR_MAX_LEN + 1];
    char code[WCS_BASTION_CODE_LEN + 1];
    char ca_pem[WCS_BASTION_CA_PEM_MAX];
} s_checked;

static const char *mode_name(wcs_mode_t mode)
{
    switch (mode) {
    case WCS_MODE_DIRECT:
        return "direct";
    case WCS_MODE_BASTION:
        return "bastion";
    default:
        return "factory";
    }
}

static bool bastion_addr_valid(const char *addr)
{
    wcs_bastion_addr_t parsed;
    return wcs_bastion_parse_addr(addr, &parsed);
}

static esp_err_t setup_get(httpd_req_t *req)
{
    return web_send_file(req, "pages/setup.html");
}

static esp_err_t info_get(httpd_req_t *req)
{
    wcs_settings_t saved;
    if (wcs_storage_load(&saved) != ESP_OK) {
        memset(&saved, 0, sizeof(saved));
    }

    char ssid[WCS_SSID_MAX_LEN * 6 + 1];
    char password[WCS_WIFI_PASSWORD_MAX_LEN * 6 + 1];
    char url[96];
    char sta_ssid[WCS_SSID_MAX_LEN * 6 + 1];
    char bastion[WCS_BASTION_ADDR_MAX_LEN * 6 + 1];
    web_json_escape(web_config.direct.ssid, ssid, sizeof(ssid));
    web_json_escape(web_config.direct.password, password, sizeof(password));
    web_json_escape(web_config.direct.url, url, sizeof(url));
    web_json_escape(saved.sta_ssid, sta_ssid, sizeof(sta_ssid));
    web_json_escape(saved.bastion_addr, bastion, sizeof(bastion));
    memset(&saved.sta_password, 0, sizeof(saved.sta_password));

    char device_code[WCS_LINK_CODE_LEN + 1] = "";
    char device_id[WCS_LINK_DEVICE_ID_LEN + 1] = "";
    wcs_link_device_code(device_code);
    wcs_link_device_id(device_id);

    char json[2048];
    snprintf(json, sizeof(json),
             "{\"direct\":{\"ssid\":\"%s\",\"password\":\"%s\",\"url\":\"%s\"},"
             "\"saved\":{\"mode\":\"%s\",\"sta_ssid\":\"%s\",\"bastion\":\"%s\"},"
             "\"bastion_default_port\":%d,\"device\":{\"id\":\"%s\",\"code\":\"%s\"}}",
             ssid, password, url, mode_name(saved.mode), sta_ssid, bastion, CONFIG_WCS_BASTION_DEFAULT_PORT,
             device_id, device_code);
    return web_send_json(req, NULL, json);
}

static esp_err_t scan_get(httpd_req_t *req)
{
    wcs_wifi_network_t *networks = calloc(SCAN_MAX, sizeof(*networks));
    char *json = malloc(SCAN_MAX * SCAN_ITEM_JSON + 32);
    if (!networks || !json) {
        free(networks);
        free(json);
        return web_send_json(req, "500 Internal Server Error", "{\"error\":\"no_memory\"}");
    }

    size_t count = 0;
    esp_err_t err = wcs_wifi_scan(networks, SCAN_MAX, &count);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "scan failed: %s", esp_err_to_name(err));
        free(networks);
        free(json);
        return web_send_json(req, "503 Service Unavailable", "{\"error\":\"scan_failed\"}");
    }

    size_t n = sprintf(json, "{\"networks\":[");
    for (size_t i = 0; i < count; i++) {
        char ssid[WCS_SSID_MAX_LEN * 6 + 1];
        web_json_escape(networks[i].ssid, ssid, sizeof(ssid));
        n += sprintf(json + n, "%s{\"ssid\":\"%s\",\"rssi\":%d,\"secured\":%s}",
                     i ? "," : "", ssid, networks[i].rssi, networks[i].secured ? "true" : "false");
    }
    sprintf(json + n, "]}");

    err = web_send_json(req, NULL, json);
    free(networks);
    free(json);
    return err;
}

static esp_err_t connect_post(httpd_req_t *req)
{
    char body[BODY_MAX];
    char ssid[FORM_SSID_MAX];
    char password[FORM_PASS_MAX] = "";
    if (web_read_body(req, body, sizeof(body)) != ESP_OK || !web_form_value(body, "ssid", ssid, sizeof(ssid))) {
        return web_send_json(req, "400 Bad Request", "{\"error\":\"bad_request\"}");
    }
    web_form_value(body, "password", password, sizeof(password));
    memset(body, 0, sizeof(body));

    esp_err_t err = wcs_wifi_sta_connect(ssid, password, false);
    memset(password, 0, sizeof(password));
    if (err == ESP_ERR_INVALID_ARG) {
        return web_send_json(req, "400 Bad Request", "{\"error\":\"invalid_credentials\"}");
    }
    if (err != ESP_OK) {
        return web_send_json(req, "503 Service Unavailable", "{\"error\":\"connect_failed\"}");
    }
    return web_send_json(req, "202 Accepted", "{\"ok\":true}");
}

static esp_err_t status_get(httpd_req_t *req)
{
    static const char *const states[] = {
        [WCS_WIFI_STA_IDLE] = "idle",
        [WCS_WIFI_STA_CONNECTING] = "connecting",
        [WCS_WIFI_STA_CONNECTED] = "connected",
        [WCS_WIFI_STA_FAILED] = "failed",
    };
    static const char *const fails[] = {
        [WCS_WIFI_FAIL_NONE] = "",
        [WCS_WIFI_FAIL_WRONG_PASSWORD] = "wrong_password",
        [WCS_WIFI_FAIL_NOT_FOUND] = "not_found",
        [WCS_WIFI_FAIL_OTHER] = "other",
    };

    wcs_wifi_sta_status_t st;
    wcs_wifi_sta_get_status(&st);
    char ssid[WCS_SSID_MAX_LEN * 6 + 1];
    web_json_escape(st.ssid, ssid, sizeof(ssid));

    char json[320];
    snprintf(json, sizeof(json),
             "{\"state\":\"%s\",\"ssid\":\"%s\",\"ip\":\"" IPSTR "\",\"fail\":\"%s\",\"reason\":%u}",
             states[st.state], ssid, IP2STR(&st.ip), fails[st.fail], st.fail_reason);
    return web_send_json(req, NULL, json);
}

static esp_err_t bastion_check_post(httpd_req_t *req)
{
    char body[BODY_MAX];
    char addr[FORM_ADDR_MAX];
    if (web_read_body(req, body, sizeof(body)) != ESP_OK || !web_form_value(body, "bastion", addr, sizeof(addr))) {
        return web_send_json(req, "400 Bad Request", "{\"error\":\"bad_request\"}");
    }

    wcs_wifi_sta_status_t st;
    wcs_wifi_sta_get_status(&st);
    if (st.state != WCS_WIFI_STA_CONNECTED) {
        return web_send_json(req, "409 Conflict", "{\"error\":\"wifi_not_connected\"}");
    }

    wcs_bastion_probe_t *probe = malloc(sizeof(*probe));
    if (!probe) {
        return web_send_json(req, "500 Internal Server Error", "{\"error\":\"no_memory\"}");
    }
    if (wcs_bastion_probe(addr, CONFIG_WCS_BASTION_PROBE_TIMEOUT_MS, probe) != ESP_OK) {
        free(probe);
        return web_send_json(req, "400 Bad Request", "{\"error\":\"invalid_bastion\"}");
    }

    if (probe->result == WCS_BASTION_PROBE_OK) {
        strlcpy(s_checked.addr, addr, sizeof(s_checked.addr));
        strlcpy(s_checked.code, probe->code, sizeof(s_checked.code));
        strlcpy(s_checked.ca_pem, probe->ca_pem, sizeof(s_checked.ca_pem));
    }

    static const char *const results[] = {
        [WCS_BASTION_PROBE_OK] = "ok",
        [WCS_BASTION_PROBE_NOT_RESOLVED] = "not_resolved",
        [WCS_BASTION_PROBE_REFUSED] = "refused",
        [WCS_BASTION_PROBE_TIMEOUT] = "timeout",
        [WCS_BASTION_PROBE_UNREACHABLE] = "unreachable",
        [WCS_BASTION_PROBE_NOT_BASTION] = "not_bastion",
    };
    char json[160];
    snprintf(json, sizeof(json),
             "{\"result\":\"%s\",\"ip\":\"" IPSTR "\",\"port\":%u,\"time_ms\":%" PRIu32 ",\"code\":\"%s\"}",
             results[probe->result], IP2STR(&probe->ip), probe->port, probe->time_ms,
             probe->result == WCS_BASTION_PROBE_OK ? probe->code : "");
    free(probe);
    return web_send_json(req, NULL, json);
}

static esp_err_t apply_post(httpd_req_t *req)
{
    char body[BODY_MAX];
    char mode[16];
    if (web_read_body(req, body, sizeof(body)) != ESP_OK || !web_form_value(body, "mode", mode, sizeof(mode))) {
        return web_send_json(req, "400 Bad Request", "{\"error\":\"bad_request\"}");
    }

    wcs_settings_t settings;
    if (wcs_storage_load(&settings) != ESP_OK) {
        memset(&settings, 0, sizeof(settings));
    }

    if (strcmp(mode, "direct") == 0) {
        settings.mode = WCS_MODE_DIRECT;
    } else if (strcmp(mode, "bastion") == 0) {
        char ssid[FORM_SSID_MAX];
        char password[FORM_PASS_MAX] = "";
        char addr[FORM_ADDR_MAX];
        bool ok = web_form_value(body, "ssid", ssid, sizeof(ssid)) &&
                  web_form_value(body, "bastion", addr, sizeof(addr));
        web_form_value(body, "password", password, sizeof(password));
        memset(body, 0, sizeof(body));

        if (!ok || !bastion_addr_valid(addr)) {
            memset(password, 0, sizeof(password));
            return web_send_json(req, "400 Bad Request", "{\"error\":\"invalid_bastion\"}");
        }
        wcs_wifi_sta_status_t st;
        wcs_wifi_sta_get_status(&st);
        if (st.state != WCS_WIFI_STA_CONNECTED || strcmp(st.ssid, ssid) != 0 ||
            strlen(password) > WCS_WIFI_PASSWORD_MAX_LEN) {
            memset(password, 0, sizeof(password));
            return web_send_json(req, "409 Conflict", "{\"error\":\"wifi_not_connected\"}");
        }

        if (strcmp(s_checked.addr, addr) != 0 || s_checked.code[0] == '\0') {
            memset(password, 0, sizeof(password));
            return web_send_json(req, "409 Conflict", "{\"error\":\"bastion_not_checked\"}");
        }
        if (wcs_storage_save_bastion_ca(s_checked.ca_pem) != ESP_OK) {
            memset(password, 0, sizeof(password));
            return web_send_json(req, "500 Internal Server Error", "{\"error\":\"apply_failed\"}");
        }
        ESP_LOGI(TAG, "bastion %s pinned, code %s", addr, s_checked.code);

        settings.mode = WCS_MODE_BASTION;
        strlcpy(settings.sta_ssid, ssid, sizeof(settings.sta_ssid));
        strlcpy(settings.sta_password, password, sizeof(settings.sta_password));
        strlcpy(settings.bastion_addr, addr, sizeof(settings.bastion_addr));
        memset(password, 0, sizeof(password));
    } else {
        return web_send_json(req, "400 Bad Request", "{\"error\":\"bad_mode\"}");
    }

    esp_err_t err = web_config.apply(&settings);
    memset(&settings, 0, sizeof(settings));
    if (err != ESP_OK) {
        return web_send_json(req, "500 Internal Server Error", "{\"error\":\"apply_failed\"}");
    }
    ESP_LOGI(TAG, "applied mode %s", mode);
    return web_send_json(req, NULL, "{\"ok\":true}");
}

static const web_route_t s_routes[] = {
    { .uri = "/setup", .method = HTTP_GET, .handler = setup_get, .access = WEB_ACCESS_PAGE },
    { .uri = "/api/setup/info", .method = HTTP_GET, .handler = info_get },
    { .uri = "/api/setup/apply", .method = HTTP_POST, .handler = apply_post },
    { .uri = "/api/wifi/scan", .method = HTTP_GET, .handler = scan_get },
    { .uri = "/api/wifi/connect", .method = HTTP_POST, .handler = connect_post },
    { .uri = "/api/wifi/status", .method = HTTP_GET, .handler = status_get },
    { .uri = "/api/bastion/check", .method = HTTP_POST, .handler = bastion_check_post },
};

esp_err_t web_setup_register(httpd_handle_t server)
{
    return WEB_REGISTER_ROUTES(server, s_routes);
}
