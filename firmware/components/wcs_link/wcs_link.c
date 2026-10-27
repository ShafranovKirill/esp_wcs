#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#include "cJSON.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_websocket_client.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "link_priv.h"
#include "mbedtls/x509_crt.h"
#include "wcs_bastion.h"
#include "wcs_storage.h"

#define PROTOCOL_VERSION    1
#define TASK_STACK          6144
#define TASK_PRIORITY       5
#define QUEUE_LEN           8
#define WS_BUFFER_SIZE      4096
#define NETWORK_TIMEOUT_MS  10000
#define WELCOME_TIMEOUT_MS  20000
#define CSR_PEM_MAX         1024

#define BACKOFF_MIN_MS      1000
#define BACKOFF_MAX_MS      60000
#define RETRY_LATER_MS      60000

#define CLOSE_FORBIDDEN     4003
#define CLOSE_RATE_LIMITED  4008

ESP_EVENT_DEFINE_BASE(WCS_LINK_EVENT);

static const char *TAG = "wcs_link";

typedef enum {
    MSG_CONNECTED,
    MSG_TEXT,
    MSG_CLOSED,
} msg_type_t;

typedef struct {
    msg_type_t type;
    int close_code;
    char *text;
} link_msg_t;

typedef enum {
    OUTCOME_RETRY,
    OUTCOME_NOW,
    OUTCOME_LATER,
} outcome_t;

typedef struct {
    char addr[WCS_BASTION_ADDR_MAX_LEN + 1];
    char name[64];
    char firmware[32];
} config_t;

static config_t s_config;
static TaskHandle_t s_task;
static QueueHandle_t s_queue;
static SemaphoreHandle_t s_wake;
static SemaphoreHandle_t s_done;
static volatile bool s_stop;
static volatile wcs_link_state_t s_state = WCS_LINK_STATE_STOPPED;

static void set_state(wcs_link_state_t state)
{
    if (s_state == state) {
        return;
    }
    s_state = state;
    esp_event_post(WCS_LINK_EVENT, WCS_LINK_EVENT_STATE, &state, sizeof(state), 0);
}

static void post(msg_type_t type, int close_code, char *text)
{
    link_msg_t msg = { .type = type, .close_code = close_code, .text = text };
    if (xQueueSend(s_queue, &msg, 0) != pdTRUE) {
        free(text);
    }
}

static void on_ws_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    const esp_websocket_event_data_t *ev = data;

    switch (id) {
    case WEBSOCKET_EVENT_CONNECTED:
        post(MSG_CONNECTED, 0, NULL);
        break;
    case WEBSOCKET_EVENT_DATA:
        if (ev->op_code == 0x1) {
            if (ev->payload_offset == 0 && ev->data_len == ev->payload_len && ev->data_len > 0) {
                char *text = malloc(ev->data_len + 1);
                if (text) {
                    memcpy(text, ev->data_ptr, ev->data_len);
                    text[ev->data_len] = '\0';
                    post(MSG_TEXT, 0, text);
                }
            }
        } else if (ev->op_code == 0x8) {
            post(MSG_CLOSED, ev->close_status_code, NULL);
        }
        break;
    case WEBSOCKET_EVENT_CLOSED:
    case WEBSOCKET_EVENT_DISCONNECTED:
        post(MSG_CLOSED, ev ? ev->close_status_code : 0, NULL);
        break;
    case WEBSOCKET_EVENT_ERROR:
        ESP_LOGW(TAG, "websocket error, tls 0x%x, errno %d", ev->error_handle.esp_tls_stack_err,
                 ev->error_handle.esp_transport_sock_errno);
        post(MSG_CLOSED, 0, NULL);
        break;
    default:
        break;
    }
}

static int64_t now_ms(void)
{
    return esp_timer_get_time() / 1000;
}

static void send_json(esp_websocket_client_handle_t client, cJSON *json)
{
    char *text = cJSON_PrintUnformatted(json);
    if (text) {
        esp_websocket_client_send_text(client, text, strlen(text), pdMS_TO_TICKS(NETWORK_TIMEOUT_MS));
        free(text);
    }
    cJSON_Delete(json);
}

static void send_hello(esp_websocket_client_handle_t client, const char *device_id)
{
    cJSON *json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "t", "hello");
    cJSON_AddNumberToObject(json, "v", PROTOCOL_VERSION);
    cJSON_AddStringToObject(json, "device_id", device_id);
    cJSON_AddStringToObject(json, "fw", s_config.firmware);
    cJSON *caps = cJSON_AddArrayToObject(json, "caps");
    cJSON_AddItemToArray(caps, cJSON_CreateString("console"));
    send_json(client, json);
}

static esp_err_t send_enroll(esp_websocket_client_handle_t client, const char *device_id)
{
    char *csr = calloc(1, CSR_PEM_MAX);
    ESP_RETURN_ON_FALSE(csr, ESP_ERR_NO_MEM, TAG, "no memory");
    esp_err_t err = link_make_csr(device_id, csr, CSR_PEM_MAX);
    if (err == ESP_OK) {
        cJSON *json = cJSON_CreateObject();
        cJSON_AddStringToObject(json, "t", "enroll");
        cJSON_AddStringToObject(json, "name", s_config.name);
        cJSON_AddStringToObject(json, "csr", csr);
        send_json(client, json);
    }
    free(csr);
    return err;
}

static void send_heartbeat(esp_websocket_client_handle_t client, uint32_t seq, int rtt)
{
    wifi_ap_record_t ap;
    bool have_ap = esp_wifi_sta_get_ap_info(&ap) == ESP_OK;

    cJSON *json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "t", "hb");
    cJSON_AddNumberToObject(json, "seq", seq);
    cJSON_AddNumberToObject(json, "ts", (double)now_ms());
    if (rtt >= 0) {
        cJSON_AddNumberToObject(json, "rtt", rtt);
    }
    if (have_ap) {
        cJSON_AddNumberToObject(json, "rssi", ap.rssi);
    }
    cJSON_AddNumberToObject(json, "uptime", (double)(esp_timer_get_time() / 1000000));
    cJSON_AddNumberToObject(json, "heap", heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    send_json(client, json);
}

static void set_time(double bastion_ms, int rtt)
{
    int64_t ms = (int64_t)bastion_ms + (rtt > 0 ? rtt / 2 : 0);
    struct timeval tv = { .tv_sec = ms / 1000, .tv_usec = (ms % 1000) * 1000 };
    settimeofday(&tv, NULL);
}

typedef struct {
    esp_websocket_client_handle_t client;
    const char *device_id;
    const char *ca_code;
    bool device_session;
    bool welcomed;
    int hb_interval_ms;
    int64_t next_hb;
    uint32_t hb_seq;
    int rtt;
    outcome_t outcome;
    bool done;
} session_t;

static void handle_text(session_t *s, const char *text)
{
    cJSON *json = cJSON_Parse(text);
    const cJSON *t = cJSON_GetObjectItem(json, "t");
    if (!cJSON_IsString(t)) {
        cJSON_Delete(json);
        return;
    }

    if (strcmp(t->valuestring, "welcome") == 0) {
        const cJSON *time = cJSON_GetObjectItem(json, "time");
        const cJSON *hb = cJSON_GetObjectItem(json, "hb");
        if (cJSON_IsNumber(time)) {
            set_time(time->valuedouble, 0);
        }
        s->hb_interval_ms = cJSON_IsNumber(hb) && hb->valueint > 0 ? hb->valueint * 1000 : 15000;
        s->welcomed = true;

        if (s->device_session) {
            ESP_LOGI(TAG, "online");
            set_state(WCS_LINK_STATE_ONLINE);
            s->next_hb = now_ms();
        } else if (send_enroll(s->client, s->device_id) != ESP_OK) {
            s->done = true;
        }
    } else if (strcmp(t->valuestring, "enroll_status") == 0) {
        const cJSON *status = cJSON_GetObjectItem(json, "status");
        const cJSON *cert = cJSON_GetObjectItem(json, "cert");
        if (cJSON_IsString(status) && strcmp(status->valuestring, "pending") == 0) {
            ESP_LOGI(TAG, "request sent, waiting for approval on the bastion");
            set_state(WCS_LINK_STATE_PENDING);
        } else if (cJSON_IsString(status) && strcmp(status->valuestring, "approved") == 0 && cJSON_IsString(cert)) {
            if (link_save_certificate(cert->valuestring, s->ca_code) == ESP_OK) {
                ESP_LOGI(TAG, "approved, certificate saved");
                s->outcome = OUTCOME_NOW;
            }
            s->done = true;
        } else {
            ESP_LOGW(TAG, "request rejected");
            s->outcome = OUTCOME_LATER;
            s->done = true;
        }
    } else if (strcmp(t->valuestring, "hb_ack") == 0) {
        const cJSON *ts = cJSON_GetObjectItem(json, "ts");
        const cJSON *time = cJSON_GetObjectItem(json, "time");
        if (cJSON_IsNumber(ts)) {
            s->rtt = (int)(now_ms() - (int64_t)ts->valuedouble);
        }
        if (cJSON_IsNumber(time)) {
            set_time(time->valuedouble, s->rtt);
        }
    }
    cJSON_Delete(json);
}

static void handle_close(session_t *s, int code)
{
    s->done = true;
    if (code == CLOSE_FORBIDDEN && s->device_session) {
        ESP_LOGW(TAG, "certificate refused by the bastion, will send a new request");
        wcs_link_forget_certificate();
        s->outcome = OUTCOME_LATER;
    } else if (code == CLOSE_RATE_LIMITED) {
        s->outcome = OUTCOME_LATER;
    } else if (code) {
        ESP_LOGI(TAG, "closed by the bastion, code %d", code);
    }
}

static esp_err_t ca_code_of(const char *ca_pem, char code[WCS_BASTION_CODE_LEN + 1])
{
    mbedtls_x509_crt crt;
    mbedtls_x509_crt_init(&crt);
    esp_err_t err = ESP_FAIL;
    if (mbedtls_x509_crt_parse(&crt, (const unsigned char *)ca_pem, strlen(ca_pem) + 1) == 0) {
        err = wcs_bastion_code(crt.pk_raw.p, crt.pk_raw.len, code);
    }
    mbedtls_x509_crt_free(&crt);
    return err;
}

static outcome_t run_session(const char *ca_pem, const char *ca_code, const char *device_id, bool *was_online)
{
    wcs_bastion_addr_t addr;
    esp_ip4_addr_t ip;
    if (!wcs_bastion_parse_addr(s_config.addr, &addr) || wcs_bastion_resolve(addr.host, &ip) != ESP_OK) {
        ESP_LOGW(TAG, "bastion %s not resolved", s_config.addr);
        return OUTCOME_RETRY;
    }

    char *cert_pem = NULL;
    bool device_session = link_load_certificate(ca_code, &cert_pem) == ESP_OK;

    char uri[64];
    snprintf(uri, sizeof(uri), "wss://" IPSTR ":%u/link", IP2STR(&ip), addr.port);

    esp_websocket_client_config_t cfg = {
        .uri = uri,
        .cert_pem = ca_pem,
        .skip_cert_common_name_check = true,
        .client_cert = device_session ? cert_pem : NULL,
        .client_key = device_session ? link_key_pem() : NULL,
        .disable_auto_reconnect = true,
        .buffer_size = WS_BUFFER_SIZE,
        .network_timeout_ms = NETWORK_TIMEOUT_MS,
        .ping_interval_sec = 30,
    };

    esp_websocket_client_handle_t client = esp_websocket_client_init(&cfg);
    if (!client) {
        free(cert_pem);
        return OUTCOME_RETRY;
    }
    esp_websocket_register_events(client, WEBSOCKET_EVENT_ANY, on_ws_event, NULL);
    xQueueReset(s_queue);

    ESP_LOGI(TAG, "connecting to %s (%s)", uri, device_session ? "device certificate" : "enrollment");
    session_t s = {
        .client = client,
        .device_id = device_id,
        .ca_code = ca_code,
        .device_session = device_session,
        .rtt = -1,
        .outcome = OUTCOME_RETRY,
    };
    int64_t welcome_deadline = now_ms() + WELCOME_TIMEOUT_MS;

    if (esp_websocket_client_start(client) == ESP_OK) {
        while (!s.done && !s_stop) {
            int64_t now = now_ms();
            if (!s.welcomed && now > welcome_deadline) {
                ESP_LOGW(TAG, "no welcome from the bastion");
                break;
            }
            if (s.welcomed && s.device_session && now >= s.next_hb) {
                send_heartbeat(client, s.hb_seq++, s.rtt);
                s.next_hb = now + s.hb_interval_ms;
            }

            link_msg_t msg;
            if (xQueueReceive(s_queue, &msg, pdMS_TO_TICKS(500)) != pdTRUE) {
                continue;
            }
            switch (msg.type) {
            case MSG_CONNECTED:
                send_hello(client, device_id);
                break;
            case MSG_TEXT:
                handle_text(&s, msg.text);
                free(msg.text);
                break;
            case MSG_CLOSED:
                handle_close(&s, msg.close_code);
                break;
            }
        }
    }

    if (esp_websocket_client_is_connected(client)) {
        esp_websocket_client_close(client, pdMS_TO_TICKS(2000));
    }
    esp_websocket_client_destroy(client);

    link_msg_t msg;
    while (xQueueReceive(s_queue, &msg, 0) == pdTRUE) {
        free(msg.text);
    }
    free(cert_pem);
    *was_online = s.device_session && s.welcomed;
    return s.outcome;
}

static uint32_t jitter(uint32_t ms)
{
    return ms * 8 / 10 + esp_random() % (ms * 4 / 10 + 1);
}

static void link_task(void *arg)
{
    char device_id[WCS_LINK_DEVICE_ID_LEN + 1];
    char ca_code[WCS_BASTION_CODE_LEN + 1] = "";
    char *ca_pem = calloc(1, WCS_BASTION_CA_PEM_MAX);

    wcs_link_device_id(device_id);
    if (!ca_pem || wcs_storage_load_bastion_ca(ca_pem, WCS_BASTION_CA_PEM_MAX) != ESP_OK ||
        ca_code_of(ca_pem, ca_code) != ESP_OK) {
        ESP_LOGE(TAG, "no pinned bastion certificate — set up Bastion mode again");
        set_state(WCS_LINK_STATE_OFFLINE);
        s_stop = true;
    }

    uint32_t backoff = BACKOFF_MIN_MS;
    bool ever_online = false;
    while (!s_stop) {
        bool was_online = false;
        outcome_t outcome = run_session(ca_pem, ca_code, device_id, &was_online);
        if (s_stop) {
            break;
        }
        if (was_online) {
            ever_online = true;
            backoff = BACKOFF_MIN_MS;
        }

        uint32_t delay;
        switch (outcome) {
        case OUTCOME_NOW:
            delay = 0;
            break;
        case OUTCOME_LATER:
            delay = RETRY_LATER_MS;
            break;
        default:
            delay = jitter(backoff);
            backoff = backoff * 2 > BACKOFF_MAX_MS ? BACKOFF_MAX_MS : backoff * 2;
            break;
        }
        set_state(ever_online ? WCS_LINK_STATE_OFFLINE : WCS_LINK_STATE_CONNECTING);
        if (delay) {
            ESP_LOGI(TAG, "reconnect in %" PRIu32 " ms", delay);
            xSemaphoreTake(s_wake, pdMS_TO_TICKS(delay));
        }
    }

    free(ca_pem);
    set_state(WCS_LINK_STATE_STOPPED);
    xSemaphoreGive(s_done);
    vTaskDelete(NULL);
}

esp_err_t wcs_link_start(const wcs_link_config_t *config)
{
    ESP_RETURN_ON_FALSE(config && config->bastion_addr, ESP_ERR_INVALID_ARG, TAG, "bad config");
    ESP_RETURN_ON_FALSE(!s_task, ESP_ERR_INVALID_STATE, TAG, "already running");
    ESP_RETURN_ON_FALSE(link_key_pem(), ESP_ERR_INVALID_STATE, TAG, "identity not initialized");

    if (!s_queue) {
        s_queue = xQueueCreate(QUEUE_LEN, sizeof(link_msg_t));
        s_wake = xSemaphoreCreateBinary();
        s_done = xSemaphoreCreateBinary();
        ESP_RETURN_ON_FALSE(s_queue && s_wake && s_done, ESP_ERR_NO_MEM, TAG, "no memory");
    }
    strlcpy(s_config.addr, config->bastion_addr, sizeof(s_config.addr));
    strlcpy(s_config.name, config->name ? config->name : "esp-wcs", sizeof(s_config.name));
    strlcpy(s_config.firmware, config->firmware ? config->firmware : "", sizeof(s_config.firmware));

    s_stop = false;
    xSemaphoreTake(s_wake, 0);
    xSemaphoreTake(s_done, 0);
    set_state(WCS_LINK_STATE_CONNECTING);
    ESP_RETURN_ON_FALSE(xTaskCreate(link_task, "wcs_link", TASK_STACK, NULL, TASK_PRIORITY, &s_task) == pdPASS,
                        ESP_ERR_NO_MEM, TAG, "task create failed");
    return ESP_OK;
}

esp_err_t wcs_link_stop(void)
{
    if (!s_task) {
        return ESP_OK;
    }
    s_stop = true;
    xSemaphoreGive(s_wake);
    xSemaphoreTake(s_done, portMAX_DELAY);
    s_task = NULL;
    return ESP_OK;
}

wcs_link_state_t wcs_link_get_state(void)
{
    return s_state;
}
