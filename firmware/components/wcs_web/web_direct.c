/* Режим Direct connection: после входа — консоль */
#include "web_priv.h"

static esp_err_t console_get(httpd_req_t *req)
{
    return web_send_file(req, "pages/console.html");
}

static const web_route_t s_routes[] = {
    { .uri = "/console", .method = HTTP_GET, .handler = console_get, .access = WEB_ACCESS_PAGE },
};

esp_err_t web_direct_register(httpd_handle_t server)
{
    return WEB_REGISTER_ROUTES(server, s_routes);
}
