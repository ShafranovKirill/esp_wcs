idf_component_register(SRCS "wcs_auth.c"
                       INCLUDE_DIRS "include"
                       PRIV_REQUIRES wcs_defaults mbedtls esp_timer esp_hw_support)
