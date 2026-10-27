#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_http_server.h"
#include "wcs_web.h"

extern wcs_web_config_t web_config;

void web_set_security_headers(httpd_req_t *req);
esp_err_t web_send_file(httpd_req_t *req, const char *path);
esp_err_t web_redirect(httpd_req_t *req, const char *location);
bool web_is_authorized(httpd_req_t *req);

typedef enum {
    WEB_ACCESS_API = 0,
    WEB_ACCESS_PAGE,
    WEB_ACCESS_PUBLIC,
} web_access_t;

typedef struct {
    const char *uri;
    httpd_method_t method;
    esp_err_t (*handler)(httpd_req_t *req);
    web_access_t access;
} web_route_t;

esp_err_t web_register_routes(httpd_handle_t server, const web_route_t *routes, size_t count);
#define WEB_REGISTER_ROUTES(server, routes) \
    web_register_routes((server), (routes), sizeof(routes) / sizeof((routes)[0]))

esp_err_t web_send_json(httpd_req_t *req, const char *status, const char *json);
esp_err_t web_send_unauthorized(httpd_req_t *req);

esp_err_t web_read_body(httpd_req_t *req, char *buf, size_t size);

bool web_form_value(const char *body, const char *key, char *out, size_t out_size);

bool web_json_escape(const char *in, char *out, size_t out_size);

esp_err_t web_setup_register(httpd_handle_t server);
esp_err_t web_direct_register(httpd_handle_t server);
