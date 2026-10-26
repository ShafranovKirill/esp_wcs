idf_component_register(SRCS "wcs_button.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_event esp_driver_gpio
                       PRIV_REQUIRES esp_timer)
