/* Режим Direct connection: после входа — консоль */
#include "web_priv.h"

EMBEDDED(console_html);

static esp_err_t console_get(httpd_req_t *req)
{
    if (!web_is_authorized(req)) {
        return web_redirect(req, "/login");
    }
    return web_send_embedded(req, WEB_HTML, console_html_start, console_html_end);
}

static const httpd_uri_t s_routes[] = {
    { .uri = "/console", .method = HTTP_GET, .handler = console_get },
};

esp_err_t web_direct_register(httpd_handle_t server)
{
    for (size_t i = 0; i < sizeof(s_routes) / sizeof(s_routes[0]); i++) {
        esp_err_t err = httpd_register_uri_handler(server, &s_routes[i]);
        if (err != ESP_OK) {
            return err;
        }
    }
    return ESP_OK;
}
