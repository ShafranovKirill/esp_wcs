#include "wcs_bastion.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "lwip/inet.h"
#include "lwip/netdb.h"
#include "lwip/sockets.h"
#include "mdns.h"

#define MDNS_QUERY_TIMEOUT_MS 2000

static const char *TAG = "wcs_bastion";

static bool s_mdns_started;

bool wcs_bastion_parse_addr(const char *addr, wcs_bastion_addr_t *out)
{
    size_t len = strlen(addr);
    if (len == 0 || len > WCS_BASTION_ADDR_MAX_LEN) {
        return false;
    }
    /* Хост или IPv4: буквы, цифры, точка, дефис; одно двоеточие перед портом */
    const char *colon = strchr(addr, ':');
    for (const char *p = addr; *p; p++) {
        if (!(isalnum((unsigned char)*p) || *p == '.' || *p == '-' || p == colon)) {
            return false;
        }
    }

    long port = CONFIG_WCS_BASTION_DEFAULT_PORT;
    size_t host_len = len;
    if (colon) {
        char *end;
        port = strtol(colon + 1, &end, 10);
        if (colon == addr || *end != '\0' || end == colon + 1 || port < 1 || port > 65535) {
            return false;
        }
        host_len = colon - addr;
    }

    memcpy(out->host, addr, host_len);
    out->host[host_len] = '\0';
    out->port = (uint16_t)port;
    return true;
}

static bool is_mdns_name(const char *host)
{
    size_t len = strlen(host);
    return len > 6 && strcasecmp(host + len - 6, ".local") == 0;
}

static bool resolve(const char *host, esp_ip4_addr_t *ip)
{
    struct in_addr literal;
    if (inet_aton(host, &literal)) {
        ip->addr = literal.s_addr;
        return true;
    }

    if (is_mdns_name(host)) {
        if (!s_mdns_started) {
            esp_err_t err = mdns_init();
            if (err != ESP_OK) {
                ESP_LOGW(TAG, "mdns init failed: %s", esp_err_to_name(err));
                return false;
            }
            s_mdns_started = true;
        }
        /* mDNS спрашивает имя без суффикса .local */
        char name[WCS_BASTION_ADDR_MAX_LEN + 1];
        strlcpy(name, host, sizeof(name));
        name[strlen(name) - 6] = '\0';
        return mdns_query_a(name, MDNS_QUERY_TIMEOUT_MS, ip) == ESP_OK;
    }

    const struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) {
        return false;
    }
    ip->addr = ((struct sockaddr_in *)res->ai_addr)->sin_addr.s_addr;
    freeaddrinfo(res);
    return true;
}

static wcs_bastion_probe_result_t tcp_probe(const esp_ip4_addr_t *ip, uint16_t port, uint32_t timeout_ms)
{
    int s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s < 0) {
        return WCS_BASTION_PROBE_UNREACHABLE;
    }
    fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);

    struct sockaddr_in sa = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = ip->addr,
    };

    int err = 0;
    if (connect(s, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        err = errno;
        if (err == EINPROGRESS) {
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(s, &wfds);
            struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
            int n = select(s + 1, NULL, &wfds, NULL, &tv);
            if (n == 0) {
                close(s);
                return WCS_BASTION_PROBE_TIMEOUT;
            }
            socklen_t len = sizeof(err);
            if (n < 0 || getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len) != 0) {
                err = EIO;
            }
        }
    }
    close(s);

    switch (err) {
    case 0:
        return WCS_BASTION_PROBE_OK;
    case ECONNREFUSED:
    case ECONNRESET: /* lwIP сообщает об отказе (RST) так */
        return WCS_BASTION_PROBE_REFUSED;
    case ETIMEDOUT:
        return WCS_BASTION_PROBE_TIMEOUT;
    default:
        ESP_LOGD(TAG, "connect errno %d", err);
        return WCS_BASTION_PROBE_UNREACHABLE;
    }
}

esp_err_t wcs_bastion_probe(const char *addr, uint32_t timeout_ms, wcs_bastion_probe_t *out)
{
    wcs_bastion_addr_t parsed;
    if (!wcs_bastion_parse_addr(addr, &parsed)) {
        return ESP_ERR_INVALID_ARG;
    }

    memset(out, 0, sizeof(*out));
    out->port = parsed.port;
    if (!resolve(parsed.host, &out->ip)) {
        out->result = WCS_BASTION_PROBE_NOT_RESOLVED;
        ESP_LOGI(TAG, "probe %s: not resolved", parsed.host);
        return ESP_OK;
    }

    int64_t start = esp_timer_get_time();
    out->result = tcp_probe(&out->ip, parsed.port, timeout_ms);
    out->time_ms = (uint32_t)((esp_timer_get_time() - start) / 1000);
    ESP_LOGI(TAG, "probe %s (" IPSTR ":%u): result %d, %" PRIu32 " ms",
             parsed.host, IP2STR(&out->ip), parsed.port, out->result, out->time_ms);
    return ESP_OK;
}
