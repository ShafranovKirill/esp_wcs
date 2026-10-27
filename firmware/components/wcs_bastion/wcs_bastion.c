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
#include "mbedtls/net_sockets.h"
#include "mbedtls/pem.h"
#include "mbedtls/ssl.h"
#include "mdns.h"
#include "psa/crypto.h"

#define MDNS_QUERY_TIMEOUT_MS 2000

static const char *TAG = "wcs_bastion";

static bool s_mdns_started;

bool wcs_bastion_parse_addr(const char *addr, wcs_bastion_addr_t *out)
{
    size_t len = strlen(addr);
    if (len == 0 || len > WCS_BASTION_ADDR_MAX_LEN) {
        return false;
    }
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

static wcs_bastion_probe_result_t tcp_connect(const esp_ip4_addr_t *ip, uint16_t port, uint32_t timeout_ms, int *fd)
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

    switch (err) {
    case 0:
        fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) & ~O_NONBLOCK);
        struct timeval rcv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &rcv, sizeof(rcv));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &rcv, sizeof(rcv));
        *fd = s;
        return WCS_BASTION_PROBE_OK;
    case ECONNREFUSED:
    case ECONNRESET:
        close(s);
        return WCS_BASTION_PROBE_REFUSED;
    case ETIMEDOUT:
        close(s);
        return WCS_BASTION_PROBE_TIMEOUT;
    default:
        ESP_LOGD(TAG, "connect errno %d", err);
        close(s);
        return WCS_BASTION_PROBE_UNREACHABLE;
    }
}

static int bio_send(void *ctx, const unsigned char *buf, size_t len)
{
    int r = send(*(int *)ctx, buf, len, 0);
    return r < 0 ? MBEDTLS_ERR_NET_SEND_FAILED : r;
}

static int bio_recv(void *ctx, unsigned char *buf, size_t len)
{
    int r = recv(*(int *)ctx, buf, len, 0);
    if (r == 0) {
        return MBEDTLS_ERR_NET_CONN_RESET;
    }
    return r < 0 ? MBEDTLS_ERR_NET_RECV_FAILED : r;
}

static const mbedtls_x509_crt *chain_root(const mbedtls_x509_crt *chain)
{
    const mbedtls_x509_crt *root = chain;
    while (root && root->next && root->next->raw.len) {
        root = root->next;
    }
    if (!root || root == chain || mbedtls_x509_crt_get_ca_istrue(root) != 1 || root->issuer_raw.len != root->subject_raw.len ||
        memcmp(root->issuer_raw.p, root->subject_raw.p, root->subject_raw.len) != 0) {
        return NULL;
    }
    return root;
}

static wcs_bastion_probe_result_t tls_inspect(int fd, const char *host, wcs_bastion_probe_t *out)
{
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);

    wcs_bastion_probe_result_t result = WCS_BASTION_PROBE_NOT_BASTION;
    int ret = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                          MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret == 0) {
        mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
        mbedtls_ssl_conf_min_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_3);
        ret = mbedtls_ssl_setup(&ssl, &conf);
    }
    if (ret == 0) {
        mbedtls_ssl_set_hostname(&ssl, host);
        mbedtls_ssl_set_bio(&ssl, &fd, bio_send, bio_recv, NULL);
        do {
            ret = mbedtls_ssl_handshake(&ssl);
        } while (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE);
    }

    if (ret != 0) {
        ESP_LOGI(TAG, "TLS handshake failed: -0x%x", -ret);
    } else {
        const mbedtls_x509_crt *root = chain_root(mbedtls_ssl_get_peer_cert(&ssl));
        size_t pem_len = 0;
        if (root &&
            mbedtls_pem_write_buffer("-----BEGIN CERTIFICATE-----\n", "-----END CERTIFICATE-----\n", root->raw.p,
                                     root->raw.len, (unsigned char *)out->ca_pem, sizeof(out->ca_pem), &pem_len) == 0 &&
            wcs_bastion_code(root->pk_raw.p, root->pk_raw.len, out->code) == ESP_OK) {
            result = WCS_BASTION_PROBE_OK;
        } else {
            ESP_LOGI(TAG, "no self-signed root CA in the server chain");
        }
        mbedtls_ssl_close_notify(&ssl);
    }

    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    return result;
}

esp_err_t wcs_bastion_code(const uint8_t *spki_der, size_t len, char out[WCS_BASTION_CODE_LEN + 1])
{
    uint8_t hash[32];
    size_t hash_len;
    if (psa_hash_compute(PSA_ALG_SHA_256, spki_der, len, hash, sizeof(hash), &hash_len) != PSA_SUCCESS) {
        return ESP_FAIL;
    }
    snprintf(out, WCS_BASTION_CODE_LEN + 1, "%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X", hash[0], hash[1],
             hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9]);
    return ESP_OK;
}

esp_err_t wcs_bastion_resolve(const char *host, esp_ip4_addr_t *ip)
{
    return resolve(host, ip) ? ESP_OK : ESP_ERR_NOT_FOUND;
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
    int fd = -1;
    out->result = tcp_connect(&out->ip, parsed.port, timeout_ms, &fd);
    out->time_ms = (uint32_t)((esp_timer_get_time() - start) / 1000);
    if (out->result == WCS_BASTION_PROBE_OK) {
        out->result = tls_inspect(fd, parsed.host, out);
        close(fd);
    }
    ESP_LOGI(TAG, "probe %s (" IPSTR ":%u): result %d, %" PRIu32 " ms%s%s", parsed.host, IP2STR(&out->ip),
             parsed.port, out->result, out->time_ms, out->result == WCS_BASTION_PROBE_OK ? ", code " : "",
             out->result == WCS_BASTION_PROBE_OK ? out->code : "");
    return ESP_OK;
}
