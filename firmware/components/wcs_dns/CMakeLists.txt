idf_component_register(SRCS "wcs_dns.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_netif
                       PRIV_REQUIRES lwip)
