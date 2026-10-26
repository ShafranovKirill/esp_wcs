#include "wcs_button.h"

#include <inttypes.h>
#include <stdbool.h>

#include "esp_check.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define POLL_PERIOD_MS   10
#define DEBOUNCE_SAMPLES 3 /* состояние считается устойчивым после 30 мс */
#define TASK_STACK_SIZE  3072
#define TASK_PRIORITY    5

ESP_EVENT_DEFINE_BASE(WCS_BUTTON_EVENT);

static const char *TAG = "wcs_button";

static wcs_button_config_t s_config;

static bool read_pressed(void)
{
    return gpio_get_level(s_config.gpio) == s_config.active_level;
}

static void post_release(uint32_t held_ms)
{
    wcs_button_event_t event;

    if (held_ms >= s_config.very_long_press_ms) {
        event = WCS_BUTTON_EVENT_VERY_LONG;
    } else if (held_ms >= s_config.long_press_ms) {
        event = WCS_BUTTON_EVENT_LONG;
    } else if (held_ms < s_config.click_max_ms) {
        event = WCS_BUTTON_EVENT_CLICK;
    } else {
        ESP_LOGI(TAG, "held %" PRIu32 " ms: ignored", held_ms);
        return;
    }

    ESP_LOGI(TAG, "held %" PRIu32 " ms: event %d", held_ms, event);
    esp_err_t err = esp_event_post(WCS_BUTTON_EVENT, event, &held_ms, sizeof(held_ms), 0);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "event post failed: %s", esp_err_to_name(err));
    }
}

static void button_task(void *arg)
{
    bool stable = read_pressed();
    bool last_raw = stable;
    int same_count = DEBOUNCE_SAMPLES;
    int64_t pressed_at_us = 0;

    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(POLL_PERIOD_MS));

        bool raw = read_pressed();
        if (raw != last_raw) {
            last_raw = raw;
            same_count = 0;
            continue;
        }
        if (same_count >= DEBOUNCE_SAMPLES || ++same_count < DEBOUNCE_SAMPLES || raw == stable) {
            continue;
        }

        stable = raw;
        if (stable) {
            pressed_at_us = esp_timer_get_time();
        } else {
            post_release((uint32_t)((esp_timer_get_time() - pressed_at_us) / 1000));
        }
    }
}

esp_err_t wcs_button_init(const wcs_button_config_t *config)
{
    ESP_RETURN_ON_FALSE(config, ESP_ERR_INVALID_ARG, TAG, "config is NULL");
    ESP_RETURN_ON_FALSE(config->click_max_ms <= config->long_press_ms &&
                            config->long_press_ms < config->very_long_press_ms,
                        ESP_ERR_INVALID_ARG, TAG, "invalid press thresholds");
    s_config = *config;

    gpio_config_t io = {
        .pin_bit_mask = 1ULL << config->gpio,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = config->active_level == 0 ? GPIO_PULLUP_ENABLE : GPIO_PULLUP_DISABLE,
        .pull_down_en = config->active_level == 0 ? GPIO_PULLDOWN_DISABLE : GPIO_PULLDOWN_ENABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&io), TAG, "gpio_config failed");

    BaseType_t ok = xTaskCreate(button_task, "wcs_button", TASK_STACK_SIZE, NULL, TASK_PRIORITY, NULL);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "task create failed");
    return ESP_OK;
}
