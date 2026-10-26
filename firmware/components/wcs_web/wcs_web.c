#include <ctype.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "esp_app_desc.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "wcs_auth.h"
#include "web_priv.h"

#define SESSION_COOKIE    "wcs_session"
#define LOGIN_BODY_MAX    512
#define USERNAME_MAX      64
#define PASSWORD_MAX      128
#define SERVER_STACK_SIZE 8192 /* PBKDF2 и поиск Wi-Fi выполняются в задаче сервера */
#define MAX_URI_HANDLERS  16

static const char *TAG = "wcs_web";

wcs_web_config_t web_config;

static httpd_handle_t s_server;

/* ---- встроенные файлы ---- */

EMBEDDED(login_html);
EMBEDDED(login_js);
EMBEDDED(setup_js);
EMBEDDED(style_css);

typedef struct {
    const char *uri;
    const char *type;
    const uint8_t *start;
    const uint8_t *end;
} asset_t;

static const asset_t s_assets[] = {
    { "/assets/login.js", "text/javascript", login_js_start, login_js_end },
    { "/assets/setup.js", "text/javascript", setup_js_start, setup_js_end },
    { "/assets/style.css", "text/css", style_css_start, style_css_end },
};

/* ---- общие помощники ---- */

void web_set_security_headers(httpd_req_t *req)
{
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "X-Content-Type-Options", "nosniff");
    httpd_resp_set_hdr(req, "X-Frame-Options", "DENY");
    httpd_resp_set_hdr(req, "Referrer-Policy", "no-referrer");
    httpd_resp_set_hdr(req, "Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'");
}

esp_err_t web_send_embedded(httpd_req_t *req, const char *type, const uint8_t *start, const uint8_t *end)
{
    web_set_security_headers(req);
    httpd_resp_set_type(req, type);
    return httpd_resp_send(req, (const char *)start, end - start);
}

esp_err_t web_redirect(httpd_req_t *req, const char *location)
{
    web_set_security_headers(req);
    httpd_resp_set_status(req, "303 See Other");
    httpd_resp_set_hdr(req, "Location", location);
    return httpd_resp_send(req, NULL, 0);
}

esp_err_t web_send_json(httpd_req_t *req, const char *status, const char *json)
{
    web_set_security_headers(req);
    httpd_resp_set_type(req, "application/json");
    if (status) {
        httpd_resp_set_status(req, status);
    }
    return httpd_resp_sendstr(req, json);
}

esp_err_t web_send_unauthorized(httpd_req_t *req)
{
    return web_send_json(req, "401 Unauthorized", "{\"error\":\"unauthorized\"}");
}

static bool get_session_token(httpd_req_t *req, char token[WCS_AUTH_TOKEN_LEN + 1])
{
    size_t len = WCS_AUTH_TOKEN_LEN + 1;
    return httpd_req_get_cookie_val(req, SESSION_COOKIE, token, &len) == ESP_OK;
}

bool web_is_authorized(httpd_req_t *req)
{
    char token[WCS_AUTH_TOKEN_LEN + 1];
    return get_session_token(req, token) && wcs_auth_session_check(token);
}

esp_err_t web_read_body(httpd_req_t *req, char *buf, size_t size)
{
    if (req->content_len >= size) {
        return ESP_ERR_INVALID_SIZE;
    }
    size_t received = 0;
    while (received < req->content_len) {
        int r = httpd_req_recv(req, buf + received, req->content_len - received);
        if (r == HTTPD_SOCK_ERR_TIMEOUT) {
            continue;
        }
        if (r <= 0) {
            return ESP_FAIL;
        }
        received += r;
    }
    buf[received] = '\0';
    return ESP_OK;
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

bool web_form_value(const char *body, const char *key, char *out, size_t out_size)
{
    if (httpd_query_key_value(body, key, out, out_size) != ESP_OK) {
        return false;
    }
    url_decode(out);
    return true;
}

bool web_json_escape(const char *in, char *out, size_t out_size)
{
    size_t n = 0;
    for (const unsigned char *p = (const unsigned char *)in; *p; p++) {
        char tmp[7];
        const char *piece = tmp;
        if (*p == '"' || *p == '\\') {
            tmp[0] = '\\';
            tmp[1] = (char)*p;
            tmp[2] = '\0';
        } else if (*p < 0x20) {
            snprintf(tmp, sizeof(tmp), "\\u%04x", *p);
        } else {
            tmp[0] = (char)*p;
            tmp[1] = '\0';
        }
        size_t len = strlen(piece);
        if (n + len >= out_size) {
            return false;
        }
        memcpy(out + n, piece, len);
        n += len;
    }
    out[n] = '\0';
    return true;
}

/* Главная страница режима после входа */
static const char *home_path(void)
{
    return web_config.mode == WCS_WEB_MODE_SETUP ? "/setup" : "/console";
}

/* ---- общие обработчики ---- */

static esp_err_t root_get(httpd_req_t *req)
{
    return web_redirect(req, web_is_authorized(req) ? home_path() : "/login");
}

static esp_err_t login_get(httpd_req_t *req)
{
    if (web_is_authorized(req)) {
        return web_redirect(req, home_path());
    }
    return web_send_embedded(req, WEB_HTML, login_html_start, login_html_end);
}

static esp_err_t login_post(httpd_req_t *req)
{
    char body[LOGIN_BODY_MAX];
    if (req->content_len == 0 || web_read_body(req, body, sizeof(body)) != ESP_OK) {
        return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Bad request");
    }

    char username[USERNAME_MAX];
    char password[PASSWORD_MAX];
    if (!web_form_value(body, "username", username, sizeof(username)) ||
        !web_form_value(body, "password", password, sizeof(password))) {
        memset(body, 0, sizeof(body));
        return web_redirect(req, "/login?error=bad");
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
        return web_redirect(req, home_path());
    }

    char location[48];
    snprintf(location, sizeof(location), "/login?error=%s&retry=%" PRIu32,
             result == WCS_AUTH_LOCKED ? "locked" : "bad", retry_after_s);
    return web_redirect(req, location);
}

static esp_err_t logout_post(httpd_req_t *req)
{
    char token[WCS_AUTH_TOKEN_LEN + 1];
    if (get_session_token(req, token)) {
        wcs_auth_logout(token);
    }
    httpd_resp_set_hdr(req, "Set-Cookie", SESSION_COOKIE "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0");
    return web_redirect(req, "/login");
}

static esp_err_t api_status_get(httpd_req_t *req)
{
    if (!web_is_authorized(req)) {
        return web_send_unauthorized(req);
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
    return web_send_json(req, NULL, json);
}

static esp_err_t asset_get(httpd_req_t *req)
{
    for (size_t i = 0; i < sizeof(s_assets) / sizeof(s_assets[0]); i++) {
        const asset_t *a = &s_assets[i];
        if (strcmp(req->uri, a->uri) == 0) {
            return web_send_embedded(req, a->type, a->start, a->end);
        }
    }
    return httpd_resp_send_err(req, HTTPD_404_NOT_FOUND, "Not found");
}

static const httpd_uri_t s_routes[] = {
    { .uri = "/", .method = HTTP_GET, .handler = root_get },
    { .uri = "/login", .method = HTTP_GET, .handler = login_get },
    { .uri = "/login", .method = HTTP_POST, .handler = login_post },
    { .uri = "/logout", .method = HTTP_POST, .handler = logout_post },
    { .uri = "/api/status", .method = HTTP_GET, .handler = api_status_get },
    { .uri = "/assets/*", .method = HTTP_GET, .handler = asset_get },
};

esp_err_t wcs_web_start(const wcs_web_config_t *config)
{
    ESP_RETURN_ON_FALSE(config, ESP_ERR_INVALID_ARG, TAG, "config is NULL");
    ESP_RETURN_ON_FALSE(config->mode != WCS_WEB_MODE_SETUP || config->apply, ESP_ERR_INVALID_ARG, TAG,
                        "setup mode requires apply callback");
    ESP_RETURN_ON_FALSE(!s_server, ESP_ERR_INVALID_STATE, TAG, "already running");
    web_config = *config;

    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.stack_size = SERVER_STACK_SIZE;
    cfg.max_uri_handlers = MAX_URI_HANDLERS;
    cfg.lru_purge_enable = true;
    cfg.uri_match_fn = httpd_uri_match_wildcard;

    ESP_RETURN_ON_ERROR(httpd_start(&s_server, &cfg), TAG, "httpd_start failed");
    for (size_t i = 0; i < sizeof(s_routes) / sizeof(s_routes[0]); i++) {
        httpd_register_uri_handler(s_server, &s_routes[i]);
    }
    esp_err_t err = config->mode == WCS_WEB_MODE_SETUP ? web_setup_register(s_server)
                                                       : web_direct_register(s_server);
    if (err != ESP_OK) {
        wcs_web_stop();
        return err;
    }

    ESP_LOGI(TAG, "started in %s mode", config->mode == WCS_WEB_MODE_SETUP ? "setup" : "direct");
    return ESP_OK;
}

esp_err_t wcs_web_stop(void)
{
    if (!s_server) {
        return ESP_OK;
    }
    esp_err_t err = httpd_stop(s_server);
    s_server = NULL;
    ESP_LOGI(TAG, "stopped");
    return err;
}
