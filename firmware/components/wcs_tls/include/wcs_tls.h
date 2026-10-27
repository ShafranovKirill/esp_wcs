#pragma once

#include <stddef.h>

#include "esp_err.h"
#include "esp_netif_ip_addr.h"

typedef struct {
    const char *common_name;
    esp_ip4_addr_t ip;
} wcs_tls_identity_t;

esp_err_t wcs_tls_init(const wcs_tls_identity_t *identity);

typedef struct {
    const char *cert_pem;
    size_t cert_len;
    const char *key_pem;
    size_t key_len;
} wcs_tls_server_cred_t;

esp_err_t wcs_tls_get_server_cred(wcs_tls_server_cred_t *cred);
