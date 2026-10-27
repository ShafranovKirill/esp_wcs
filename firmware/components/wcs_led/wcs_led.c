#include "wcs_led.h"

#include <math.h>
#include <stdbool.h>

#include "esp_check.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "led_strip.h"

#define FRAME_PERIOD_MS      20
#define BREATHE_PERIOD_MS    2000
#define BREATHE_MIN_LEVEL    0.06f
#define BLINK_PERIOD_MS      200
#define DIM_LEVEL            0.33f
#define ACTIVITY_OFF_MS      30
#define ACTIVITY_MIN_GAP_MS  100
#define TASK_STACK_SIZE      3072
#define TASK_PRIORITY        3
#define RMT_RESOLUTION_HZ    (10 * 1000 * 1000)

typedef struct {
    wcs_led_indication_t base;
    wcs_led_indication_t overlay;
    bool overlay_active;
    int64_t overlay_until_us;
    bool activity_pending;
} led_state_t;

static const char *TAG = "wcs_led";

static led_strip_handle_t s_strip;
static uint8_t s_brightness;
static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static led_state_t s_state;

static float pattern_level(wcs_led_pattern_t pattern, int64_t now_ms)
{
    switch (pattern) {
    case WCS_LED_SOLID:
        return 1.0f;
    case WCS_LED_DIM:
        return DIM_LEVEL;
    case WCS_LED_BREATHE: {
        float phase = (float)(now_ms % BREATHE_PERIOD_MS) / BREATHE_PERIOD_MS;
        float wave = (1.0f - cosf(2.0f * (float)M_PI * phase)) / 2.0f;
        return BREATHE_MIN_LEVEL + (1.0f - BREATHE_MIN_LEVEL) * wave * wave;
    }
    case WCS_LED_BLINK_FAST:
        return (now_ms % BLINK_PERIOD_MS) < BLINK_PERIOD_MS / 2 ? 1.0f : 0.0f;
    case WCS_LED_OFF:
    default:
        return 0.0f;
    }
}

static uint8_t scale(uint8_t component, float level)
{
    return (uint8_t)lroundf(component * level * s_brightness / 255.0f);
}

static void led_task(void *arg)
{
    uint8_t last[3] = { 1, 1, 1 };
    int64_t activity_off_until_ms = 0;
    int64_t activity_next_allowed_ms = 0;

    for (;;) {
        int64_t now_us = esp_timer_get_time();
        int64_t now_ms = now_us / 1000;

        portENTER_CRITICAL(&s_lock);
        if (s_state.overlay_active && s_state.overlay_until_us && now_us >= s_state.overlay_until_us) {
            s_state.overlay_active = false;
        }
        bool use_overlay = s_state.overlay_active;
        wcs_led_indication_t ind = use_overlay ? s_state.overlay : s_state.base;
        bool activity = s_state.activity_pending;
        s_state.activity_pending = false;
        portEXIT_CRITICAL(&s_lock);

        if (activity && now_ms >= activity_next_allowed_ms) {
            activity_off_until_ms = now_ms + ACTIVITY_OFF_MS;
            activity_next_allowed_ms = now_ms + ACTIVITY_MIN_GAP_MS;
        }

        float level = pattern_level(ind.pattern, now_ms);
        if (!use_overlay && now_ms < activity_off_until_ms) {
            level = 0.0f;
        }

        uint8_t rgb[3] = { scale(ind.color.r, level), scale(ind.color.g, level), scale(ind.color.b, level) };
        if (rgb[0] != last[0] || rgb[1] != last[1] || rgb[2] != last[2]) {
            led_strip_set_pixel(s_strip, 0, rgb[0], rgb[1], rgb[2]);
            led_strip_refresh(s_strip);
            last[0] = rgb[0];
            last[1] = rgb[1];
            last[2] = rgb[2];
        }

        vTaskDelay(pdMS_TO_TICKS(FRAME_PERIOD_MS));
    }
}

esp_err_t wcs_led_init(const wcs_led_config_t *config)
{
    ESP_RETURN_ON_FALSE(config && config->brightness > 0, ESP_ERR_INVALID_ARG, TAG, "invalid config");
    ESP_RETURN_ON_FALSE(!s_strip, ESP_ERR_INVALID_STATE, TAG, "already initialized");
    s_brightness = config->brightness;

    led_strip_config_t strip_config = {
        .strip_gpio_num = config->gpio,
        .max_leds = 1,
        .led_model = LED_MODEL_WS2812,
        .color_component_format = LED_STRIP_COLOR_COMPONENT_FMT_GRB,
    };
    led_strip_rmt_config_t rmt_config = {
        .clk_src = RMT_CLK_SRC_DEFAULT,
        .resolution_hz = RMT_RESOLUTION_HZ,
    };
    ESP_RETURN_ON_ERROR(led_strip_new_rmt_device(&strip_config, &rmt_config, &s_strip), TAG, "led_strip init failed");
    led_strip_clear(s_strip);

    BaseType_t ok = xTaskCreate(led_task, "wcs_led", TASK_STACK_SIZE, NULL, TASK_PRIORITY, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "task create failed");
    return ESP_OK;
}

void wcs_led_set_base(wcs_led_indication_t indication)
{
    portENTER_CRITICAL(&s_lock);
    s_state.base = indication;
    portEXIT_CRITICAL(&s_lock);
}

void wcs_led_set_overlay(wcs_led_indication_t indication, uint32_t duration_ms)
{
    int64_t until_us = duration_ms ? esp_timer_get_time() + (int64_t)duration_ms * 1000 : 0;
    portENTER_CRITICAL(&s_lock);
    s_state.overlay = indication;
    s_state.overlay_active = true;
    s_state.overlay_until_us = until_us;
    portEXIT_CRITICAL(&s_lock);
}

void wcs_led_clear_overlay(void)
{
    portENTER_CRITICAL(&s_lock);
    s_state.overlay_active = false;
    portEXIT_CRITICAL(&s_lock);
}

void wcs_led_activity(void)
{
    portENTER_CRITICAL(&s_lock);
    s_state.activity_pending = true;
    portEXIT_CRITICAL(&s_lock);
}
