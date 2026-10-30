#include <ctype.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "esp_app_desc.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_https_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "wcs_auth.h"
#include "wcs_tls.h"
#include "web_files.h"
#include "web_priv.h"

#define SESSION_COOKIE    "wcs_session"
#define LOGIN_BODY_MAX    512
#define USERNAME_MAX      64
#define PASSWORD_MAX      128
#define SERVER_STACK_SIZE 10240
#define MAX_URI_HANDLERS  24
#define MAX_OPEN_SOCKETS  7
#define HOST_MAX          64
#define ORIGIN_MAX        (sizeof("https://") + HOST_MAX)

#define REDIRECT_CTRL_PORT    ESP_HTTPD_DEF_CTRL_PORT
#define REDIRECT_MAX_SOCKETS  2
#define REDIRECT_STACK_SIZE   3072

static const char *TAG = "wcs_web";

wcs_web_config_t web_config;

static httpd_handle_t s_server;
static httpd_handle_t s_redirect_server;
static char s_host[HOST_MAX];
static char s_csp[160 + HOST_MAX];

void web_set_security_headers(httpd_req_t *req)
{
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "X-Content-Type-Options", "nosniff");
    httpd_resp_set_hdr(req, "X-Frame-Options", "DENY");
    httpd_resp_set_hdr(req, "Referrer-Policy", "no-referrer");
    httpd_resp_set_hdr(req, "Content-Security-Policy", s_csp);
}

esp_err_t web_send_file(httpd_req_t *req, const char *path)
{
    for (size_t i = 0; i < web_files_count; i++) {
        const web_file_t *f = &web_files[i];
        if (strcmp(f->path, path) == 0) {
            web_set_security_headers(req);
            httpd_resp_set_type(req, f->type);
            if (f->gzip) {
                httpd_resp_set_hdr(req, "Content-Encoding", "gzip");
            }
            return httpd_resp_send(req, (const char *)f->data, f->len);
        }
    }
    return httpd_resp_send_err(req, HTTPD_404_NOT_FOUND, "Not found");
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

static const char *home_path(void)
{
    return web_config.mode == WCS_WEB_MODE_SETUP ? "/setup" : "/console";
}

static esp_err_t root_get(httpd_req_t *req)
{
    return web_redirect(req, web_is_authorized(req) ? home_path() : "/login");
}

static esp_err_t login_get(httpd_req_t *req)
{
    if (web_is_authorized(req)) {
        return web_redirect(req, home_path());
    }
    return web_send_file(req, "pages/login.html");
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
        char cookie[sizeof(SESSION_COOKIE) + WCS_AUTH_TOKEN_LEN + 48];
        snprintf(cookie, sizeof(cookie), SESSION_COOKIE "=%s; Path=/; Secure; HttpOnly; SameSite=Strict", token);
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
    httpd_resp_set_hdr(req, "Set-Cookie", SESSION_COOKIE "=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0");
    return web_redirect(req, "/login");
}

static esp_err_t api_status_get(httpd_req_t *req)
{
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
    char path[CONFIG_HTTPD_MAX_URI_LEN + 1];
    strlcpy(path, req->uri + 1, sizeof(path));
    path[strcspn(path, "?#")] = '\0';
    return web_send_file(req, path);
}

static const web_route_t s_routes[] = {
    { .uri = "/", .method = HTTP_GET, .handler = root_get, .access = WEB_ACCESS_PUBLIC },
    { .uri = "/login", .method = HTTP_GET, .handler = login_get, .access = WEB_ACCESS_PUBLIC },
    { .uri = "/login", .method = HTTP_POST, .handler = login_post, .access = WEB_ACCESS_PUBLIC },
    { .uri = "/logout", .method = HTTP_POST, .handler = logout_post, .access = WEB_ACCESS_PUBLIC },
    { .uri = "/api/status", .method = HTTP_GET, .handler = api_status_get, .access = WEB_ACCESS_API },
    { .uri = "/assets/*", .method = HTTP_GET, .handler = asset_get, .access = WEB_ACCESS_PUBLIC },
};

const char *web_ws_session_token(httpd_req_t *req)
{
    return req->sess_ctx;
}

static esp_err_t ws_authorize(httpd_req_t *req)
{
    char origin[ORIGIN_MAX];
    char expected[ORIGIN_MAX];
    snprintf(expected, sizeof(expected), "https://%s", s_host);
    if (httpd_req_get_hdr_value_str(req, "Origin", origin, sizeof(origin)) != ESP_OK ||
        strcmp(origin, expected) != 0) {
        ESP_LOGW(TAG, "websocket %s: bad origin", req->uri);
        return ESP_FAIL;
    }

    char token[WCS_AUTH_TOKEN_LEN + 1];
    if (!get_session_token(req, token) || !wcs_auth_session_check(token)) {
        ESP_LOGW(TAG, "websocket %s: not authorized", req->uri);
        return ESP_FAIL;
    }
    char *copy = strdup(token);
    ESP_RETURN_ON_FALSE(copy, ESP_ERR_NO_MEM, TAG, "no memory");
    req->sess_ctx = copy;
    req->free_ctx = free;
    return ESP_OK;
}

static esp_err_t dispatch(httpd_req_t *req)
{
    const web_route_t *route = req->user_ctx;
    if (route->websocket) {
        return route->handler(req);
    }
    if (route->access != WEB_ACCESS_PUBLIC && !web_is_authorized(req)) {
        return route->access == WEB_ACCESS_PAGE ? web_redirect(req, "/login") : web_send_unauthorized(req);
    }
    return route->handler(req);
}

esp_err_t web_register_routes(httpd_handle_t server, const web_route_t *routes, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        const httpd_uri_t uri = {
            .uri = routes[i].uri,
            .method = routes[i].method,
            .handler = dispatch,
            .user_ctx = (void *)&routes[i],
            .is_websocket = routes[i].websocket,
            .ws_pre_handshake_cb = routes[i].websocket ? ws_authorize : NULL,
        };
        esp_err_t err = httpd_register_uri_handler(server, &uri);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "route %s: %s", routes[i].uri, esp_err_to_name(err));
            return err;
        }
    }
    return ESP_OK;
}

static esp_err_t redirect_any(httpd_req_t *req)
{
    char location[sizeof("https://") + HOST_MAX + CONFIG_HTTPD_MAX_URI_LEN];
    snprintf(location, sizeof(location), "https://%s%s", s_host, req->uri);
    ESP_LOGD(TAG, "http %s -> https", req->uri);
    httpd_resp_set_status(req, "301 Moved Permanently");
    httpd_resp_set_hdr(req, "Location", location);
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "Connection", "close");
    return httpd_resp_send(req, NULL, 0);
}

static esp_err_t start_redirect_server(void)
{
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.server_port = 80;
    cfg.ctrl_port = REDIRECT_CTRL_PORT;
    cfg.max_open_sockets = REDIRECT_MAX_SOCKETS;
    cfg.stack_size = REDIRECT_STACK_SIZE;
    cfg.max_uri_handlers = 4;
    cfg.lru_purge_enable = true;
    cfg.uri_match_fn = httpd_uri_match_wildcard;
    ESP_RETURN_ON_ERROR(httpd_start(&s_redirect_server, &cfg), TAG, "redirect server start failed");

    static const httpd_method_t methods[] = { HTTP_GET, HTTP_HEAD, HTTP_POST };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        const httpd_uri_t any = { .uri = "/*", .method = methods[i], .handler = redirect_any };
        httpd_register_uri_handler(s_redirect_server, &any);
    }
    return ESP_OK;
}

static void on_socket_close(httpd_handle_t hd, int fd)
{
    if (web_config.mode == WCS_WEB_MODE_DIRECT) {
        web_direct_socket_closed(fd);
    }
    close(fd);
}

esp_err_t wcs_web_start(const wcs_web_config_t *config)
{
    ESP_RETURN_ON_FALSE(config, ESP_ERR_INVALID_ARG, TAG, "config is NULL");
    ESP_RETURN_ON_FALSE(config->mode != WCS_WEB_MODE_SETUP || config->apply, ESP_ERR_INVALID_ARG, TAG,
                        "setup mode requires apply callback");
    ESP_RETURN_ON_FALSE(config->host && strlen(config->host) < HOST_MAX, ESP_ERR_INVALID_ARG, TAG, "bad host");
    ESP_RETURN_ON_FALSE(!s_server, ESP_ERR_INVALID_STATE, TAG, "already running");

    wcs_tls_server_cred_t cred;
    ESP_RETURN_ON_ERROR(wcs_tls_get_server_cred(&cred), TAG, "no TLS certificate");

    web_config = *config;
    strlcpy(s_host, config->host, sizeof(s_host));
    snprintf(s_csp, sizeof(s_csp),
             "default-src 'self'; connect-src 'self' wss://%s; style-src 'self' 'unsafe-inline'; "
             "frame-ancestors 'none'",
             s_host);

    httpd_ssl_config_t cfg = HTTPD_SSL_CONFIG_DEFAULT();
    cfg.servercert = (const uint8_t *)cred.cert_pem;
    cfg.servercert_len = cred.cert_len;
    cfg.prvtkey_pem = (const uint8_t *)cred.key_pem;
    cfg.prvtkey_len = cred.key_len;
    cfg.tls_version = ESP_TLS_VER_TLS_1_3;
    cfg.httpd.stack_size = SERVER_STACK_SIZE;
    cfg.httpd.max_uri_handlers = MAX_URI_HANDLERS;
    cfg.httpd.max_open_sockets = MAX_OPEN_SOCKETS;
    cfg.httpd.lru_purge_enable = true;
    cfg.httpd.uri_match_fn = httpd_uri_match_wildcard;
    cfg.httpd.close_fn = on_socket_close;

    ESP_RETURN_ON_ERROR(httpd_ssl_start(&s_server, &cfg), TAG, "httpd_ssl_start failed");
    esp_err_t err = WEB_REGISTER_ROUTES(s_server, s_routes);
    if (err == ESP_OK) {
        err = config->mode == WCS_WEB_MODE_SETUP ? web_setup_register(s_server) : web_direct_register(s_server);
    }
    if (err == ESP_OK) {
        err = start_redirect_server();
    }
    if (err != ESP_OK) {
        wcs_web_stop();
        return err;
    }

    ESP_LOGI(TAG, "started in %s mode, https://%s/", config->mode == WCS_WEB_MODE_SETUP ? "setup" : "direct",
             s_host);
    return ESP_OK;
}

esp_err_t wcs_web_stop(void)
{
    if (s_redirect_server) {
        httpd_stop(s_redirect_server);
        s_redirect_server = NULL;
    }
    if (!s_server) {
        return ESP_OK;
    }
    if (web_config.mode == WCS_WEB_MODE_DIRECT) {
        web_direct_stop();
    }
    esp_err_t err = httpd_ssl_stop(s_server);
    s_server = NULL;
    ESP_LOGI(TAG, "stopped");
    return err;
}
