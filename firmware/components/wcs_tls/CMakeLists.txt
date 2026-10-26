idf_component_register(SRCS "wcs_tls.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_netif
                       PRIV_REQUIRES mbedtls nvs_flash esp_timer)
