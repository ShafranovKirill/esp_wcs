idf_component_register(SRCS "wcs_console.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_driver_uart esp_driver_gpio
                       PRIV_REQUIRES esp_psram esp_timer wcs_storage)
