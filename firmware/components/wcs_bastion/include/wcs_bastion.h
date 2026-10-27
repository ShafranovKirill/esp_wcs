#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_netif_ip_addr.h"
#include "wcs_storage.h"

#define WCS_BASTION_CODE_LEN    14
#define WCS_BASTION_CA_PEM_MAX  1536

typedef struct {
    char host[WCS_BASTION_ADDR_MAX_LEN + 1];
    uint16_t port;
} wcs_bastion_addr_t;

bool wcs_bastion_parse_addr(const char *addr, wcs_bastion_addr_t *out);

typedef enum {
    WCS_BASTION_PROBE_OK,
    WCS_BASTION_PROBE_NOT_RESOLVED,
    WCS_BASTION_PROBE_REFUSED,
    WCS_BASTION_PROBE_TIMEOUT,
    WCS_BASTION_PROBE_UNREACHABLE,
    WCS_BASTION_PROBE_NOT_BASTION,
} wcs_bastion_probe_result_t;

typedef struct {
    wcs_bastion_probe_result_t result;
    esp_ip4_addr_t ip;
    uint16_t port;
    uint32_t time_ms;
    char code[WCS_BASTION_CODE_LEN + 1];
    char ca_pem[WCS_BASTION_CA_PEM_MAX];
} wcs_bastion_probe_t;

esp_err_t wcs_bastion_probe(const char *addr, uint32_t timeout_ms, wcs_bastion_probe_t *out);

esp_err_t wcs_bastion_code(const uint8_t *spki_der, size_t len, char out[WCS_BASTION_CODE_LEN + 1]);

esp_err_t wcs_bastion_resolve(const char *host, esp_ip4_addr_t *ip);
