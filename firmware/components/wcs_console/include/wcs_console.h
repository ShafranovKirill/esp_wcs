#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "driver/gpio.h"
#include "esp_err.h"
#include "hal/uart_types.h"

typedef enum {
    WCS_CONSOLE_PARITY_NONE = 0,
    WCS_CONSOLE_PARITY_EVEN = 1,
    WCS_CONSOLE_PARITY_ODD = 2,
} wcs_console_parity_t;

typedef struct {
    uint32_t baud;
    uint8_t data_bits;
    wcs_console_parity_t parity;
    uint8_t stop_bits;
} wcs_console_line_t;

typedef struct {
    uart_port_t uart_num;
    gpio_num_t tx_gpio;
    gpio_num_t rx_gpio;
    uint32_t default_baud;
    uint32_t break_ms;
} wcs_console_config_t;

typedef void (*wcs_console_output_cb_t)(const uint8_t *data, size_t len, void *ctx);

esp_err_t wcs_console_init(const wcs_console_config_t *config);

void wcs_console_get_line(wcs_console_line_t *line);
bool wcs_console_line_valid(const wcs_console_line_t *line);
esp_err_t wcs_console_set_line(const wcs_console_line_t *line);

esp_err_t wcs_console_write(const uint8_t *data, size_t len);
esp_err_t wcs_console_send_break(void);

size_t wcs_console_history(uint8_t *out, size_t size);

esp_err_t wcs_console_add_listener(wcs_console_output_cb_t cb, void *ctx);
void wcs_console_remove_listener(wcs_console_output_cb_t cb, void *ctx);
