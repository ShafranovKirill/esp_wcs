#include "wcs_web.h"

#include <ctype.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "esp_app_desc.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "wcs_auth.h"

#define SESSION_COOKIE    "wcs_session"
#define LOGIN_BODY_MAX    256
#define USERNAME_MAX      64
#define PASSWORD_MAX      128
#define SERVER_STACK_SIZE 8192 /* PBKDF2 выполняется в задаче сервера */

static const char *TAG = "wcs_web";

static httpd_handle_t s_server;
static char s_portal_url[32];

/* ---- встроенные файлы ---- */

#define EMBEDDED(name)                                                   \
    extern const uint8_t name##_start[] asm("_binary_" #name "_start"); \
    extern const uint8_t name##_end[] asm("_binary_" #name "_end")

EMBEDDED(login_html);
EMBEDDED(login_js);
EMBEDDED(settings_html);
EMBEDDED(settings_js);
EMBEDDED(style_css);

typedef struct {
    const char *uri;
    const char *type;
    const uint8_t *start;
    const uint8_t *end;
} asset_t;

static const asset_t s_assets[] = {
    { "/assets/login.js", "text/javascript", login_js_start, login_js_end },
    { "/assets/settings.js", "text/javascript", settings_js_start, settings_js_end },
    { "/assets/style.css", "text/css", style_css_start, style_css_end },
};

/* ---- общие помощники ---- */

static void set_security_headers(httpd_req_t *req)
{
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "X-Content-Type-Options", "nosniff");
    httpd_resp_set_hdr(req, "X-Frame-Options", "DENY");
    httpd_resp_set_hdr(req, "Referrer-Policy", "no-referrer");
    httpd_resp_set_hdr(req, "Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'");
}

static esp_err_t send_embedded(httpd_req_t *req, const char *type, const uint8_t *start, const uint8_t *end)
{
    set_security_headers(req);
    httpd_resp_set_type(req, type);
    return httpd_resp_send(req, (const char *)start, end - start);
}

static esp_err_t redirect(httpd_req_t *req, const char *location)
{
    set_security_headers(req);
    httpd_resp_set_status(req, "303 See Other");
    httpd_resp_set_hdr(req, "Location", location);
    return httpd_resp_send(req, NULL, 0);
}

static bool get_session_token(httpd_req_t *req, char token[WCS_AUTH_TOKEN_LEN + 1])
{
    size_t len = WCS_AUTH_TOKEN_LEN + 1;
    return httpd_req_get_cookie_val(req, SESSION_COOKIE, token, &len) == ESP_OK;
}

static bool is_authorized(httpd_req_t *req)
{
    char token[WCS_AUTH_TOKEN_LEN + 1];
    return get_session_token(req, token) && wcs_auth_session_check(token);
}

static int hex_value(char c)
{
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    c = (char)tolower((unsigned char)c);
    return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

/* Декодирует application/x-www-form-urlencoded на месте */
static void url_decode(char *s)
{
    char *out = s;
    for (; *s; s++) {
        if (*s == '+') {
            *out++ = ' ';
        } else if (*s == '%' && hex_value(s[1]) >= 0 && hex_value(s[2]) >= 0) {
            *out++ = (char)(hex_value(s[1]) << 4 | hex_value(s[2]));
            s += 2;
        } else {
            *out++ = *s;
        }
    }
    *out = '\0';
}

static bool form_value(const char *body, const char *key, char *out, size_t out_len)
{
    if (httpd_query_key_value(body, key, out, out_len) != ESP_OK) {
        return false;
    }
    url_decode(out);
    return true;
}

/* ---- обработчики ---- */

static esp_err_t root_get(httpd_req_t *req)
{
    return redirect(req, is_authorized(req) ? "/settings" : "/login");
}

static esp_err_t login_get(httpd_req_t *req)
{
    if (is_authorized(req)) {
        return redirect(req, "/settings");
    }
    return send_embedded(req, "text/html; charset=utf-8", login_html_start, login_html_end);
}

static esp_err_t login_post(httpd_req_t *req)
{
    if (req->content_len == 0 || req->content_len >= LOGIN_BODY_MAX) {
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Bad request");
    }

    char body[LOGIN_BODY_MAX];
    size_t received = 0;
    while (received < req->content_len) {
        int r = httpd_req_recv(req, body + received, req->content_len - received);
        if (r == HTTPD_SOCK_ERR_TIMEOUT) {
            continue;
        }
        if (r <= 0) {
            return ESP_FAIL;
        }
        received += r;
    }
    body[received] = '\0';

    char username[USERNAME_MAX];
    char password[PASSWORD_MAX];
    if (!form_value(body, "username", username, sizeof(username)) ||
        !form_value(body, "password", password, sizeof(password))) {
        memset(body, 0, sizeof(body));
        return redirect(req, "/login?error=bad");
    }

    char token[WCS_AUTH_TOKEN_LEN + 1];
    uint32_t retry_after_s;
    wcs_auth_result_t result = wcs_auth_login(username, password, token, &retry_after_s);
    memset(body, 0, sizeof(body));
    memset(password, 0, sizeof(password));

    if (result == WCS_AUTH_OK) {
        /* Secure добавится вместе с HTTPS */
        char cookie[sizeof(SESSION_COOKIE) + WCS_AUTH_TOKEN_LEN + 48];
        snprintf(cookie, sizeof(cookie), SESSION_COOKIE "=%s; Path=/; HttpOnly; SameSite=Strict", token);
        httpd_resp_set_hdr(req, "Set-Cookie", cookie);
        return redirect(req, "/settings");
    }

    char location[48];
    snprintf(location, sizeof(location), "/login?error=%s&retry=%" PRIu32,
             result == WCS_AUTH_LOCKED ? "locked" : "bad", retry_after_s);
    return redirect(req, location);
}

static esp_err_t logout_post(httpd_req_t *req)
{
    char token[WCS_AUTH_TOKEN_LEN + 1];
    if (get_session_token(req, token)) {
        wcs_auth_logout(token);
    }
    httpd_resp_set_hdr(req, "Set-Cookie", SESSION_COOKIE "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0");
    return redirect(req, "/login");
}

static esp_err_t settings_get(httpd_req_t *req)
{
    if (!is_authorized(req)) {
        return redirect(req, "/login");
    }
    return send_embedded(req, "text/html; charset=utf-8", settings_html_start, settings_html_end);
}

static esp_err_t api_status_get(httpd_req_t *req)
{
    set_security_headers(req);
    httpd_resp_set_type(req, "application/json");
    if (!is_authorized(req)) {
        httpd_resp_set_status(req, "401 Unauthorized");
        return httpd_resp_sendstr(req, "{\"error\":\"unauthorized\"}");
    }

    const esp_app_desc_t *app = esp_app_get_description();
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);

    char json[320];
    snprintf(json, sizeof(json),
             "{\"firmware\":\"%s\",\"idf\":\"%s\",\"mac\":\"" MACSTR "\","
             "\"uptime_s\":%lld,\"heap_internal\":%u,\"heap_psram\":%u}",
             app->version, app->idf_ver, MAC2STR(mac), esp_timer_get_time() / 1000000,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    return httpd_resp_sendstr(req, json);
}

static esp_err_t asset_get(httpd_req_t *req)
{
    for (size_t i = 0; i < sizeof(s_assets) / sizeof(s_assets[0]); i++) {
        const asset_t *a = &s_assets[i];
        if (strcmp(req->uri, a->uri) == 0) {
            return send_embedded(req, a->type, a->start, a->end);
        }
    }
    return httpd_resp_send_err(req, HTTPD_404_NOT_FOUND, "Not found");
}

/* Captive portal: всё неизвестное — на страницу входа (iOS нужен непустой ответ) */
static esp_err_t captive_redirect(httpd_req_t *req, httpd_err_code_t err)
{
    httpd_resp_set_status(req, "302 Found");
    httpd_resp_set_hdr(req, "Location", s_portal_url);
    return httpd_resp_sendstr(req, "Redirect to the captive portal");
}

static const httpd_uri_t s_routes[] = {
    { .uri = "/", .method = HTTP_GET, .handler = root_get },
    { .uri = "/login", .method = HTTP_GET, .handler = login_get },
    { .uri = "/login", .method = HTTP_POST, .handler = login_post },
    { .uri = "/logout", .method = HTTP_POST, .handler = logout_post },
    { .uri = "/settings", .method = HTTP_GET, .handler = settings_get },
    { .uri = "/api/status", .method = HTTP_GET, .handler = api_status_get },
    { .uri = "/assets/*", .method = HTTP_GET, .handler = asset_get },
};

esp_err_t wcs_web_start(const wcs_web_config_t *config)
{
    ESP_RETURN_ON_FALSE(config, ESP_ERR_INVALID_ARG, TAG, "config is NULL");
    ESP_RETURN_ON_FALSE(!s_server, ESP_ERR_INVALID_STATE, TAG, "already running");

    snprintf(s_portal_url, sizeof(s_portal_url), "http://" IPSTR "/", IP2STR(&config->portal_ip));

    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.stack_size = SERVER_STACK_SIZE;
    cfg.max_uri_handlers = sizeof(s_routes) / sizeof(s_routes[0]) + 4;
    cfg.lru_purge_enable = true;
    cfg.uri_match_fn = httpd_uri_match_wildcard;

    ESP_RETURN_ON_ERROR(httpd_start(&s_server, &cfg), TAG, "httpd_start failed");
    for (size_t i = 0; i < sizeof(s_routes) / sizeof(s_routes[0]); i++) {
        httpd_register_uri_handler(s_server, &s_routes[i]);
    }
    httpd_register_err_handler(s_server, HTTPD_404_NOT_FOUND, captive_redirect);

    ESP_LOGI(TAG, "started at %s", s_portal_url);
    return ESP_OK;
}

esp_err_t wcs_web_stop(void)
{
    if (!s_server) {
        return ESP_OK;
    }
    esp_err_t err = httpd_stop(s_server);
    s_server = NULL;
    return err;
}
