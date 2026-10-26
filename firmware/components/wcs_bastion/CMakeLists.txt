idf_component_register(SRCS "wcs_bastion.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_netif wcs_storage
                       PRIV_REQUIRES lwip esp_timer mbedtls)
