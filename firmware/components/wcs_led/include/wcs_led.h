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
    WCS_LED_SOLID,
    WCS_LED_DIM,
    WCS_LED_BREATHE,
    WCS_LED_BLINK_FAST,
} wcs_led_pattern_t;

typedef struct {
    wcs_led_color_t color;
    wcs_led_pattern_t pattern;
} wcs_led_indication_t;

typedef struct {
    gpio_num_t gpio;
    uint8_t brightness;
} wcs_led_config_t;

esp_err_t wcs_led_init(const wcs_led_config_t *config);

void wcs_led_set_base(wcs_led_indication_t indication);

void wcs_led_set_overlay(wcs_led_indication_t indication, uint32_t duration_ms);
void wcs_led_clear_overlay(void);

void wcs_led_activity(void);
