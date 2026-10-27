#pragma once

#include <stdint.h>

#include "driver/gpio.h"
#include "esp_err.h"
#include "esp_event.h"

ESP_EVENT_DECLARE_BASE(WCS_BUTTON_EVENT);

typedef enum {
    WCS_BUTTON_EVENT_CLICK,
    WCS_BUTTON_EVENT_LONG,
    WCS_BUTTON_EVENT_VERY_LONG,
    WCS_BUTTON_EVENT_HOLD_LONG,
    WCS_BUTTON_EVENT_HOLD_VERY_LONG,
    WCS_BUTTON_EVENT_TRIPLE_CLICK,
} wcs_button_event_t;

typedef struct {
    gpio_num_t gpio;
    int active_level;
    uint32_t click_max_ms;
    uint32_t long_press_ms;
    uint32_t very_long_press_ms;
    uint32_t multi_click_gap_ms;
} wcs_button_config_t;

esp_err_t wcs_button_init(const wcs_button_config_t *config);
