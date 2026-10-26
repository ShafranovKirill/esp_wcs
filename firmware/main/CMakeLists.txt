idf_component_register(SRCS "main.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES esp_psram esp_app_format esp_event esp_netif esp_hw_support esp_wifi esp_timer nvs_flash
                                     wcs_defaults wcs_storage wcs_button wcs_wifi wcs_auth wcs_web wcs_led wcs_tls)
