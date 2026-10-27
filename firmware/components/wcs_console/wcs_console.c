#include "wcs_console.h"

#include <inttypes.h>
#include <string.h>

#include "driver/uart.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "wcs_storage.h"

#define HISTORY_SIZE     (CONFIG_WCS_CONSOLE_HISTORY_KB * 1024)
#define READ_CHUNK       512
#define READ_TIMEOUT_MS  20
#define TX_DONE_MS       2000
#define TASK_STACK       4096
#define TASK_PRIORITY    6
#define BAUD_MIN         300
#define BAUD_MAX         1000000

typedef struct {
    wcs_console_output_cb_t cb;
    void *ctx;
} listener_t;

static const char *TAG = "wcs_console";

static wcs_console_config_t s_config;
static wcs_console_line_t s_line;
static SemaphoreHandle_t s_lock;
static SemaphoreHandle_t s_tx_lock;
static uint8_t *s_history;
static size_t s_history_head;
static size_t s_history_len;
static listener_t s_listeners[CONFIG_WCS_CONSOLE_MAX_LISTENERS];

bool wcs_console_line_valid(const wcs_console_line_t *line)
{
    return line && line->baud >= BAUD_MIN && line->baud <= BAUD_MAX && line->data_bits >= 5 &&
           line->data_bits <= 8 && line->parity <= WCS_CONSOLE_PARITY_ODD &&
           (line->stop_bits == 1 || line->stop_bits == 2);
}

static uart_parity_t to_uart_parity(wcs_console_parity_t parity)
{
    switch (parity) {
    case WCS_CONSOLE_PARITY_EVEN:
        return UART_PARITY_EVEN;
    case WCS_CONSOLE_PARITY_ODD:
        return UART_PARITY_ODD;
    default:
        return UART_PARITY_DISABLE;
    }
}

static esp_err_t apply_line(const wcs_console_line_t *line)
{
    uart_port_t uart = s_config.uart_num;
    ESP_RETURN_ON_ERROR(uart_set_baudrate(uart, line->baud), TAG, "baud");
    ESP_RETURN_ON_ERROR(uart_set_word_length(uart, (uart_word_length_t)(UART_DATA_5_BITS + line->data_bits - 5)),
                        TAG, "data bits");
    ESP_RETURN_ON_ERROR(uart_set_parity(uart, to_uart_parity(line->parity)), TAG, "parity");
    ESP_RETURN_ON_ERROR(uart_set_stop_bits(uart, line->stop_bits == 2 ? UART_STOP_BITS_2 : UART_STOP_BITS_1), TAG,
                        "stop bits");
    return ESP_OK;
}

static void load_line(void)
{
    s_line = (wcs_console_line_t){
        .baud = s_config.default_baud,
        .data_bits = 8,
        .parity = WCS_CONSOLE_PARITY_NONE,
        .stop_bits = 1,
    };

    wcs_console_settings_t saved;
    if (wcs_storage_load_console(&saved) != ESP_OK) {
        return;
    }
    const wcs_console_line_t line = {
        .baud = saved.baud,
        .data_bits = saved.data_bits,
        .parity = (wcs_console_parity_t)saved.parity,
        .stop_bits = saved.stop_bits,
    };
    if (wcs_console_line_valid(&line)) {
        s_line = line;
    } else {
        ESP_LOGW(TAG, "saved line settings are invalid, using defaults");
    }
}

static void history_append(const uint8_t *data, size_t len)
{
    if (len >= HISTORY_SIZE) {
        data += len - HISTORY_SIZE;
        len = HISTORY_SIZE;
    }
    size_t first = HISTORY_SIZE - s_history_head;
    if (first > len) {
        first = len;
    }
    memcpy(s_history + s_history_head, data, first);
    memcpy(s_history, data + first, len - first);
    s_history_head = (s_history_head + len) % HISTORY_SIZE;
    s_history_len = s_history_len + len > HISTORY_SIZE ? HISTORY_SIZE : s_history_len + len;
}

static void reader_task(void *arg)
{
    static uint8_t buf[READ_CHUNK];
    listener_t listeners[CONFIG_WCS_CONSOLE_MAX_LISTENERS];

    for (;;) {
        int n = uart_read_bytes(s_config.uart_num, buf, sizeof(buf), pdMS_TO_TICKS(READ_TIMEOUT_MS));
        if (n <= 0) {
            continue;
        }
        xSemaphoreTake(s_lock, portMAX_DELAY);
        history_append(buf, n);
        memcpy(listeners, s_listeners, sizeof(listeners));
        xSemaphoreGive(s_lock);

        for (size_t i = 0; i < CONFIG_WCS_CONSOLE_MAX_LISTENERS; i++) {
            if (listeners[i].cb) {
                listeners[i].cb(buf, n, listeners[i].ctx);
            }
        }
    }
}

esp_err_t wcs_console_init(const wcs_console_config_t *config)
{
    ESP_RETURN_ON_FALSE(config, ESP_ERR_INVALID_ARG, TAG, "config is NULL");
    ESP_RETURN_ON_FALSE(!s_lock, ESP_ERR_INVALID_STATE, TAG, "already initialized");

    s_config = *config;
    s_lock = xSemaphoreCreateMutex();
    s_tx_lock = xSemaphoreCreateMutex();
    s_history = heap_caps_malloc(HISTORY_SIZE, MALLOC_CAP_SPIRAM);
    if (!s_history) {
        s_history = malloc(HISTORY_SIZE);
    }
    ESP_RETURN_ON_FALSE(s_lock && s_tx_lock && s_history, ESP_ERR_NO_MEM, TAG, "no memory");

    load_line();

    const uart_config_t uart = {
        .baud_rate = (int)s_line.baud,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_RETURN_ON_ERROR(uart_driver_install(config->uart_num, CONFIG_WCS_CONSOLE_RX_BUFFER,
                                            CONFIG_WCS_CONSOLE_TX_BUFFER, 0, NULL, 0),
                        TAG, "uart_driver_install failed");
    ESP_RETURN_ON_ERROR(uart_param_config(config->uart_num, &uart), TAG, "uart_param_config failed");
    ESP_RETURN_ON_ERROR(apply_line(&s_line), TAG, "line config failed");
    ESP_RETURN_ON_ERROR(uart_set_pin(config->uart_num, config->tx_gpio, config->rx_gpio, UART_PIN_NO_CHANGE,
                                     UART_PIN_NO_CHANGE),
                        TAG, "uart_set_pin failed");
    gpio_pullup_en(config->rx_gpio);

    BaseType_t ok = xTaskCreate(reader_task, "wcs_console", TASK_STACK, NULL, TASK_PRIORITY, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "task create failed");

    ESP_LOGI(TAG, "UART%d TX %d RX %d, %" PRIu32 " %u%c%u", config->uart_num, config->tx_gpio, config->rx_gpio,
             s_line.baud, s_line.data_bits, "NEO"[s_line.parity], s_line.stop_bits);
    return ESP_OK;
}

void wcs_console_get_line(wcs_console_line_t *line)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *line = s_line;
    xSemaphoreGive(s_lock);
}

esp_err_t wcs_console_set_line(const wcs_console_line_t *line)
{
    ESP_RETURN_ON_FALSE(s_lock, ESP_ERR_INVALID_STATE, TAG, "not initialized");
    ESP_RETURN_ON_FALSE(wcs_console_line_valid(line), ESP_ERR_INVALID_ARG, TAG, "invalid line settings");

    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    uart_wait_tx_done(s_config.uart_num, pdMS_TO_TICKS(TX_DONE_MS));
    esp_err_t err = apply_line(line);
    xSemaphoreGive(s_tx_lock);
    ESP_RETURN_ON_ERROR(err, TAG, "apply failed");

    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_line = *line;
    xSemaphoreGive(s_lock);

    const wcs_console_settings_t saved = {
        .baud = line->baud,
        .data_bits = line->data_bits,
        .parity = (uint8_t)line->parity,
        .stop_bits = line->stop_bits,
    };
    err = wcs_storage_save_console(&saved);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "line settings not saved: %s", esp_err_to_name(err));
    }
    ESP_LOGI(TAG, "line %" PRIu32 " %u%c%u", line->baud, line->data_bits, "NEO"[line->parity], line->stop_bits);
    return ESP_OK;
}

esp_err_t wcs_console_write(const uint8_t *data, size_t len)
{
    ESP_RETURN_ON_FALSE(s_lock, ESP_ERR_INVALID_STATE, TAG, "not initialized");
    if (len == 0) {
        return ESP_OK;
    }
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    int n = uart_write_bytes(s_config.uart_num, data, len);
    xSemaphoreGive(s_tx_lock);
    return n == (int)len ? ESP_OK : ESP_FAIL;
}

esp_err_t wcs_console_send_break(void)
{
    ESP_RETURN_ON_FALSE(s_lock, ESP_ERR_INVALID_STATE, TAG, "not initialized");

    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    uart_wait_tx_done(s_config.uart_num, pdMS_TO_TICKS(TX_DONE_MS));
    esp_err_t err = uart_set_line_inverse(s_config.uart_num, UART_SIGNAL_TXD_INV);
    if (err == ESP_OK) {
        vTaskDelay(pdMS_TO_TICKS(s_config.break_ms));
        err = uart_set_line_inverse(s_config.uart_num, UART_SIGNAL_INV_DISABLE);
    }
    xSemaphoreGive(s_tx_lock);
    ESP_LOGI(TAG, "break %" PRIu32 " ms", s_config.break_ms);
    return err;
}

size_t wcs_console_history(uint8_t *out, size_t size)
{
    if (!s_lock) {
        return 0;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    size_t len = s_history_len < size ? s_history_len : size;
    size_t start = (s_history_head + HISTORY_SIZE - len) % HISTORY_SIZE;
    size_t first = HISTORY_SIZE - start;
    if (first > len) {
        first = len;
    }
    memcpy(out, s_history + start, first);
    memcpy(out + first, s_history, len - first);
    xSemaphoreGive(s_lock);
    return len;
}

esp_err_t wcs_console_add_listener(wcs_console_output_cb_t cb, void *ctx)
{
    ESP_RETURN_ON_FALSE(s_lock && cb, ESP_ERR_INVALID_STATE, TAG, "not initialized");
    esp_err_t err = ESP_ERR_NO_MEM;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    for (size_t i = 0; i < CONFIG_WCS_CONSOLE_MAX_LISTENERS; i++) {
        if (!s_listeners[i].cb) {
            s_listeners[i] = (listener_t){ .cb = cb, .ctx = ctx };
            err = ESP_OK;
            break;
        }
    }
    xSemaphoreGive(s_lock);
    return err;
}

void wcs_console_remove_listener(wcs_console_output_cb_t cb, void *ctx)
{
    if (!s_lock) {
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    for (size_t i = 0; i < CONFIG_WCS_CONSOLE_MAX_LISTENERS; i++) {
        if (s_listeners[i].cb == cb && s_listeners[i].ctx == ctx) {
            s_listeners[i] = (listener_t){ 0 };
        }
    }
    xSemaphoreGive(s_lock);
}
