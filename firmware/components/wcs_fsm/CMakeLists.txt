idf_component_register(SRCS "wcs_fsm.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_driver_gpio
                       PRIV_REQUIRES esp_event esp_netif esp_wifi esp_timer esp_hw_support esp_system
                                     wcs_defaults wcs_storage wcs_button wcs_wifi wcs_auth wcs_web wcs_led wcs_tls)
