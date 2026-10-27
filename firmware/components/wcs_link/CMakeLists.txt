idf_component_register(SRCS "wcs_link.c" "identity.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_event
                       PRIV_REQUIRES mbedtls tcp_transport esp-tls nvs_flash esp_timer esp_hw_support esp_system esp_wifi esp_netif esp_psram
                                     wcs_bastion wcs_console wcs_storage)
