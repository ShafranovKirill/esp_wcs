idf_component_register(SRCS "wcs_web.c" "web_setup.c" "web_direct.c"
                       INCLUDE_DIRS "include"
                       REQUIRES wcs_storage
                       PRIV_REQUIRES esp_http_server wcs_auth wcs_wifi wcs_bastion esp_app_format esp_hw_support esp_timer
                       EMBED_FILES "www/login.html"
                                   "www/login.js"
                                   "www/setup.html"
                                   "www/setup.js"
                                   "www/console.html"
                                   "www/style.css")
