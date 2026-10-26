idf_component_register(SRCS "wcs_web.c"
                       INCLUDE_DIRS "include"
                       REQUIRES esp_netif
                       PRIV_REQUIRES esp_http_server wcs_auth esp_app_format esp_hw_support esp_timer
                       EMBED_FILES "www/login.html"
                                   "www/login.js"
                                   "www/settings.html"
                                   "www/settings.js"
                                   "www/style.css")
