/*
 * RGB-светодиод состояния (WS2812): цвет, характер свечения, слои.
 *
 * Компонент не знает о состояниях устройства — только как светить.
 * Схема индикации: docs/led.md
 *
 * Итоговое свечение собирается из слоёв, верхний перекрывает нижние:
 *   1. подсказка (overlay) — например, при удержании кнопки;
 *   2. активность — короткие погасания поверх базы, когда идут данные;
 *   3. база — по текущему состоянию устройства.
 * Все функции потокобезопасны.
 */
#pragma once

#include <stdint.h>

#include "driver/gpio.h"
#include "esp_err.h"

typedef struct {
    uint8_t r, g, b;
} wcs_led_color_t;

#define WCS_LED_WHITE  ((wcs_led_color_t){ 255, 255, 255 })
#define WCS_LED_BLUE   ((wcs_led_color_t){ 0, 0, 255 })
#define WCS_LED_GREEN  ((wcs_led_color_t){ 0, 255, 0 })
#define WCS_LED_PURPLE ((wcs_led_color_t){ 160, 0, 255 })
#define WCS_LED_YELLOW ((wcs_led_color_t){ 255, 160, 0 })
#define WCS_LED_RED    ((wcs_led_color_t){ 255, 0, 0 })

typedef enum {
    WCS_LED_OFF,
    WCS_LED_SOLID,      /* ровно */
    WCS_LED_DIM,        /* ровно, ~1/3 яркости */
    WCS_LED_BREATHE,    /* плавно, период 2 с */
    WCS_LED_BLINK_FAST, /* 5 Гц */
} wcs_led_pattern_t;

typedef struct {
    wcs_led_color_t color;
    wcs_led_pattern_t pattern;
} wcs_led_indication_t;

typedef struct {
    gpio_num_t gpio;
    uint8_t brightness; /* максимальная яркость, 1..255 */
} wcs_led_config_t;

esp_err_t wcs_led_init(const wcs_led_config_t *config);

/* Базовое свечение по состоянию устройства */
void wcs_led_set_base(wcs_led_indication_t indication);

/* Подсказка поверх базы. duration_ms = 0 — до вызова wcs_led_clear_overlay() */
void wcs_led_set_overlay(wcs_led_indication_t indication, uint32_t duration_ms);
void wcs_led_clear_overlay(void);

/* Отметить активность (данные консоли): короткое погасание, не чаще 10 раз в секунду */
void wcs_led_activity(void);
