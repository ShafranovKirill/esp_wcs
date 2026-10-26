idf_component_register(SRCS "wcs_led.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_driver_gpio
                       PRIV_REQUIRES espressif__led_strip esp_timer)
