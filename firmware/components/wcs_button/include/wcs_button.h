/*
 * Кнопка режимов: опрос с подавлением дребезга, классификация нажатия по длительности.
 *
 * События публикуются в стандартный цикл событий (esp_event_loop_create_default).
 * CLICK/LONG/VERY_LONG — при отпускании, HOLD_* — во время удержания, когда
 * достигнут порог (для подсказки светодиодом). Данные события — uint32_t,
 * длительность удержания в мс.
 */
#pragma once

#include <stdint.h>

#include "driver/gpio.h"
#include "esp_err.h"
#include "esp_event.h"

ESP_EVENT_DECLARE_BASE(WCS_BUTTON_EVENT);

typedef enum {
    WCS_BUTTON_EVENT_CLICK,     /* короче click_max_ms */
    WCS_BUTTON_EVENT_LONG,      /* от long_press_ms до very_long_press_ms */
    WCS_BUTTON_EVENT_VERY_LONG, /* от very_long_press_ms */
    WCS_BUTTON_EVENT_HOLD_LONG,      /* кнопка ещё нажата, достигнут long_press_ms */
    WCS_BUTTON_EVENT_HOLD_VERY_LONG, /* кнопка ещё нажата, достигнут very_long_press_ms */
} wcs_button_event_t;

typedef struct {
    gpio_num_t gpio;
    int active_level;            /* уровень на пине при нажатии */
    uint32_t click_max_ms;       /* удержания между click_max_ms и long_press_ms игнорируются */
    uint32_t long_press_ms;
    uint32_t very_long_press_ms;
} wcs_button_config_t;

/* Настраивает пин и запускает задачу опроса. Вызывать один раз. */
esp_err_t wcs_button_init(const wcs_button_config_t *config);
