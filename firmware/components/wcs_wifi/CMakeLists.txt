idf_component_register(SRCS "wcs_wifi.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_netif
                       PRIV_REQUIRES esp_wifi esp_event esp_hw_support esp_timer)
