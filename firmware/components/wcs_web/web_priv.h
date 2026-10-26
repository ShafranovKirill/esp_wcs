/* Внутренний интерфейс между частями веб-сервера */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_http_server.h"
#include "wcs_web.h"

#define EMBEDDED(name)                                                   \
    extern const uint8_t name##_start[] asm("_binary_" #name "_start"); \
    extern const uint8_t name##_end[] asm("_binary_" #name "_end")

#define WEB_HTML "text/html; charset=utf-8"

extern wcs_web_config_t web_config;

void web_set_security_headers(httpd_req_t *req);
esp_err_t web_send_embedded(httpd_req_t *req, const char *type, const uint8_t *start, const uint8_t *end);
esp_err_t web_redirect(httpd_req_t *req, const char *location);
bool web_is_authorized(httpd_req_t *req);

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
