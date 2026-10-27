#include "board.h"
#include "esp_app_desc.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_psram.h"
#include "nvs_flash.h"
#include "wcs_auth.h"
#include "wcs_fsm.h"
#include "wcs_led.h"

#define BOOT_FLASH_MS 500

static const char *TAG = "wcs";

static void init_nvs(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS partition is incompatible, erasing");
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

void app_main(void)
{
    const esp_app_desc_t *app = esp_app_get_description();

    const wcs_led_config_t led = { .gpio = BOARD_RGB_LED_GPIO, .brightness = BOARD_RGB_LED_BRIGHTNESS };
    ESP_ERROR_CHECK(wcs_led_init(&led));
    wcs_led_set_overlay((wcs_led_indication_t){ WCS_LED_WHITE, WCS_LED_SOLID }, BOOT_FLASH_MS);

    ESP_LOGI(TAG, "%s %s (ESP-IDF %s)", app->project_name, app->version, app->idf_ver);
    ESP_LOGI(TAG, "PSRAM: %u bytes, free heap: internal %u, PSRAM %u",
             (unsigned)esp_psram_get_size(),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));

    init_nvs();
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(wcs_auth_init());

    const wcs_fsm_config_t fsm = {
        .button_gpio = BOARD_BUTTON_GPIO,
        .button_active_level = BOARD_BUTTON_ACTIVE_LEVEL,
    };
    ESP_ERROR_CHECK(wcs_fsm_start(&fsm));
}
