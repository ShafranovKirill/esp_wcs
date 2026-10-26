/* Внутренний интерфейс между частями веб-сервера */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_http_server.h"
#include "wcs_web.h"

extern wcs_web_config_t web_config;

void web_set_security_headers(httpd_req_t *req);
/* Встроенный файл из www/ (путь относительно www/, например "pages/setup.html"); нет — 404 */
esp_err_t web_send_file(httpd_req_t *req, const char *path);
esp_err_t web_redirect(httpd_req_t *req, const char *location);
bool web_is_authorized(httpd_req_t *req);

/*
 * Маршруты. Проверка входа делается в одном месте — при диспетчеризации,
 * обработчик вызывается только если доступ разрешён.
 * Значение по умолчанию (0) — только после входа: забытое поле не открывает адрес всем.
 */
typedef enum {
    WEB_ACCESS_API = 0, /* без входа — 401 с JSON */
    WEB_ACCESS_PAGE,    /* без входа — перенаправление на /login */
    WEB_ACCESS_PUBLIC,  /* доступно без входа */
} web_access_t;

typedef struct {
    const char *uri; /* можно с * в конце */
    httpd_method_t method;
    esp_err_t (*handler)(httpd_req_t *req);
    web_access_t access;
} web_route_t;

/* routes должен жить, пока работает сервер (static const) */
esp_err_t web_register_routes(httpd_handle_t server, const web_route_t *routes, size_t count);
#define WEB_REGISTER_ROUTES(server, routes) \
    web_register_routes((server), (routes), sizeof(routes) / sizeof((routes)[0]))

/* JSON-ответ; status = NULL — 200 OK */
esp_err_t web_send_json(httpd_req_t *req, const char *status, const char *json);
esp_err_t web_send_unauthorized(httpd_req_t *req);

/* Тело запроса целиком в buf (с завершающим нулём); ESP_ERR_INVALID_SIZE — не помещается */
esp_err_t web_read_body(httpd_req_t *req, char *buf, size_t size);

/* Значение поля application/x-www-form-urlencoded, декодированное */
bool web_form_value(const char *body, const char *key, char *out, size_t out_size);

/* Экранирует строку для JSON (без кавычек вокруг); false — не поместилось */
bool web_json_escape(const char *in, char *out, size_t out_size);

esp_err_t web_setup_register(httpd_handle_t server);
esp_err_t web_direct_register(httpd_handle_t server);
