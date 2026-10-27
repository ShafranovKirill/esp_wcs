#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "wcs_auth.h"
#include "wcs_console.h"
#include "web_priv.h"

#define FRAME_MAX      4096
#define HISTORY_CHUNK  4096
#define HISTORY_MAX    (CONFIG_WCS_CONSOLE_HISTORY_KB * 1024)
#define PENDING_MAX    (32 * 1024)

typedef struct {
    uint8_t *data;
    size_t len;
} out_chunk_t;

static const char *TAG = "wcs_web_console";

static SemaphoreHandle_t s_lock;
static httpd_handle_t s_server;
static int s_owner = -1;
static size_t s_pending;
static bool s_listening;
static uint8_t s_frame[FRAME_MAX + 1];

static const char *const s_parity_names[] = {
    [WCS_CONSOLE_PARITY_NONE] = "none",
    [WCS_CONSOLE_PARITY_EVEN] = "even",
    [WCS_CONSOLE_PARITY_ODD] = "odd",
};

static esp_err_t console_get(httpd_req_t *req)
{
    return web_send_file(req, "pages/console.html");
}

static bool owner_alive(void)
{
    return s_owner >= 0 && s_server && httpd_ws_get_fd_info(s_server, s_owner) == HTTPD_WS_CLIENT_WEBSOCKET;
}

static bool is_owner(int fd)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool owner = s_owner == fd;
    xSemaphoreGive(s_lock);
    return owner;
}

static void on_sent(esp_err_t err, int socket, void *arg)
{
    out_chunk_t *chunk = arg;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_pending = s_pending > chunk->len ? s_pending - chunk->len : 0;
    xSemaphoreGive(s_lock);
    free(chunk->data);
    free(chunk);
}

static void on_output(const uint8_t *data, size_t len, void *ctx)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    int fd = s_owner;
    httpd_handle_t server = s_server;
    bool fits = s_pending + len <= PENDING_MAX;
    if (fd >= 0 && server && fits) {
        s_pending += len;
    }
    xSemaphoreGive(s_lock);

    if (fd < 0 || !server) {
        return;
    }
    if (!fits) {
        ESP_LOGW(TAG, "client is slow, %u bytes of output dropped", (unsigned)len);
        return;
    }

    out_chunk_t *chunk = malloc(sizeof(*chunk));
    uint8_t *copy = malloc(len);
    if (chunk && copy) {
        memcpy(copy, data, len);
        *chunk = (out_chunk_t){ .data = copy, .len = len };
        httpd_ws_frame_t frame = { .type = HTTPD_WS_TYPE_BINARY, .payload = copy, .len = len };
        if (httpd_ws_send_data_async(server, fd, &frame, on_sent, chunk) == ESP_OK) {
            return;
        }
    }
    free(copy);
    free(chunk);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_pending = s_pending > len ? s_pending - len : 0;
    xSemaphoreGive(s_lock);
}

static esp_err_t send_text(httpd_req_t *req, const char *text)
{
    httpd_ws_frame_t frame = { .type = HTTPD_WS_TYPE_TEXT, .payload = (uint8_t *)text, .len = strlen(text) };
    return httpd_ws_send_frame(req, &frame);
}

static esp_err_t send_state(httpd_req_t *req)
{
    wcs_console_line_t line;
    wcs_console_get_line(&line);
    char json[160];
    snprintf(json, sizeof(json),
             "{\"t\":\"state\",\"owner\":true,\"line\":{\"baud\":%" PRIu32
             ",\"data_bits\":%u,\"parity\":\"%s\",\"stop_bits\":%u}}",
             line.baud, line.data_bits, s_parity_names[line.parity], line.stop_bits);
    return send_text(req, json);
}

static esp_err_t send_history(httpd_req_t *req)
{
    uint8_t *buf = heap_caps_malloc(HISTORY_MAX, MALLOC_CAP_SPIRAM);
    if (!buf) {
        return ESP_OK;
    }
    size_t len = wcs_console_history(buf, HISTORY_MAX);
    esp_err_t err = ESP_OK;
    for (size_t off = 0; off < len && err == ESP_OK; off += HISTORY_CHUNK) {
        size_t n = len - off < HISTORY_CHUNK ? len - off : HISTORY_CHUNK;
        httpd_ws_frame_t frame = { .type = HTTPD_WS_TYPE_BINARY, .payload = buf + off, .len = n };
        err = httpd_ws_send_frame(req, &frame);
    }
    free(buf);
    return err;
}

static void notify_taken(int fd)
{
    static const char text[] = "{\"t\":\"taken\"}";
    httpd_ws_frame_t frame = { .type = HTTPD_WS_TYPE_TEXT, .payload = (uint8_t *)text, .len = sizeof(text) - 1 };
    httpd_ws_send_frame_async(s_server, fd, &frame);
}

static esp_err_t become_owner(httpd_req_t *req, int fd, bool force)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    int previous = s_owner;
    bool busy = previous != fd && owner_alive();
    if (!busy || force) {
        s_owner = fd;
    }
    xSemaphoreGive(s_lock);

    if (busy && !force) {
        return send_text(req, "{\"t\":\"busy\"}");
    }
    if (busy) {
        ESP_LOGI(TAG, "console taken over by socket %d", fd);
        notify_taken(previous);
    }
    ESP_RETURN_ON_ERROR(send_state(req), TAG, "state send failed");
    return send_history(req);
}

static bool parse_line(const cJSON *json, wcs_console_line_t *line)
{
    const cJSON *baud = cJSON_GetObjectItem(json, "baud");
    const cJSON *data_bits = cJSON_GetObjectItem(json, "data_bits");
    const cJSON *parity = cJSON_GetObjectItem(json, "parity");
    const cJSON *stop_bits = cJSON_GetObjectItem(json, "stop_bits");
    if (!cJSON_IsNumber(baud) || !cJSON_IsNumber(data_bits) || !cJSON_IsString(parity) ||
        !cJSON_IsNumber(stop_bits) || baud->valuedouble < 0 || baud->valuedouble > UINT32_MAX) {
        return false;
    }
    *line = (wcs_console_line_t){
        .baud = (uint32_t)baud->valuedouble,
        .data_bits = (uint8_t)data_bits->valueint,
        .stop_bits = (uint8_t)stop_bits->valueint,
    };
    for (size_t i = 0; i < sizeof(s_parity_names) / sizeof(s_parity_names[0]); i++) {
        if (strcmp(parity->valuestring, s_parity_names[i]) == 0) {
            line->parity = (wcs_console_parity_t)i;
            return wcs_console_line_valid(line);
        }
    }
    return false;
}

static esp_err_t handle_text(httpd_req_t *req, int fd, const char *text)
{
    cJSON *json = cJSON_Parse(text);
    const cJSON *t = cJSON_GetObjectItem(json, "t");
    esp_err_t err = ESP_OK;

    if (!cJSON_IsString(t)) {
        err = send_text(req, "{\"t\":\"error\",\"error\":\"bad_message\"}");
    } else if (strcmp(t->valuestring, "hello") == 0) {
        err = become_owner(req, fd, false);
    } else if (strcmp(t->valuestring, "take") == 0) {
        err = become_owner(req, fd, true);
    } else if (strcmp(t->valuestring, "ping") == 0) {
        err = send_text(req, "{\"t\":\"pong\"}");
    } else if (!is_owner(fd)) {
        err = send_text(req, "{\"t\":\"busy\"}");
    } else if (strcmp(t->valuestring, "line") == 0) {
        wcs_console_line_t line;
        if (!parse_line(json, &line)) {
            err = send_text(req, "{\"t\":\"error\",\"error\":\"invalid_line\"}");
        } else if (wcs_console_set_line(&line) != ESP_OK) {
            err = send_text(req, "{\"t\":\"error\",\"error\":\"line_failed\"}");
        } else {
            err = send_state(req);
        }
    } else if (strcmp(t->valuestring, "break") == 0) {
        err = wcs_console_send_break() == ESP_OK ? send_text(req, "{\"t\":\"break_done\"}")
                                                 : send_text(req, "{\"t\":\"error\",\"error\":\"break_failed\"}");
    }
    cJSON_Delete(json);
    return err;
}

static esp_err_t console_ws(httpd_req_t *req)
{
    int fd = httpd_req_to_sockfd(req);
    httpd_ws_frame_t frame = { 0 };
    ESP_RETURN_ON_ERROR(httpd_ws_recv_frame(req, &frame, 0), TAG, "frame header");
    if (frame.len > FRAME_MAX) {
        ESP_LOGW(TAG, "frame too big: %u", (unsigned)frame.len);
        return ESP_FAIL;
    }
    frame.payload = s_frame;
    if (frame.len) {
        ESP_RETURN_ON_ERROR(httpd_ws_recv_frame(req, &frame, frame.len), TAG, "frame body");
    }

    const char *token = web_ws_session_token(req);
    if (!token || !wcs_auth_session_check(token)) {
        send_text(req, "{\"t\":\"logout\"}");
        return ESP_FAIL;
    }

    switch (frame.type) {
    case HTTPD_WS_TYPE_BINARY:
        if (is_owner(fd)) {
            wcs_console_write(frame.payload, frame.len);
        }
        return ESP_OK;
    case HTTPD_WS_TYPE_TEXT:
        s_frame[frame.len] = '\0';
        return handle_text(req, fd, (const char *)s_frame);
    default:
        return ESP_OK;
    }
}

static const web_route_t s_routes[] = {
    { .uri = "/console", .method = HTTP_GET, .handler = console_get, .access = WEB_ACCESS_PAGE },
    { .uri = "/ws/console", .method = HTTP_GET, .handler = console_ws, .websocket = true },
};

esp_err_t web_direct_register(httpd_handle_t server)
{
    if (!s_lock) {
        s_lock = xSemaphoreCreateMutex();
        ESP_RETURN_ON_FALSE(s_lock, ESP_ERR_NO_MEM, TAG, "no memory");
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_server = server;
    s_owner = -1;
    s_pending = 0;
    xSemaphoreGive(s_lock);

    if (!s_listening) {
        ESP_RETURN_ON_ERROR(wcs_console_add_listener(on_output, NULL), TAG, "console listener");
        s_listening = true;
    }
    return WEB_REGISTER_ROUTES(server, s_routes);
}

void web_direct_stop(void)
{
    if (!s_lock) {
        return;
    }
    if (s_listening) {
        wcs_console_remove_listener(on_output, NULL);
        s_listening = false;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_server = NULL;
    s_owner = -1;
    xSemaphoreGive(s_lock);
}

void web_direct_socket_closed(int fd)
{
    if (!s_lock) {
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_owner == fd) {
        s_owner = -1;
        ESP_LOGI(TAG, "console released");
    }
    xSemaphoreGive(s_lock);
}
