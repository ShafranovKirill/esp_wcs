/*
 * ESP WCS — беспроводной консольный сервер.
 * Точка входа прошивки. Модули подключаются по мере реализации этапов (см. docs/roadmap.md).
 */
#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_psram.h"

static const char *TAG = "wcs";

void app_main(void)
{
    const esp_app_desc_t *app = esp_app_get_description();

    ESP_LOGI(TAG, "%s %s (ESP-IDF %s)", app->project_name, app->version, app->idf_ver);
    ESP_LOGI(TAG, "PSRAM: %u bytes, free heap: internal %u, PSRAM %u",
             (unsigned)esp_psram_get_size(),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
}
