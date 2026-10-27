#pragma once

#include <stdint.h>

#define WCS_PASSWORD_SALT_LEN 16
#define WCS_PASSWORD_HASH_LEN 32

typedef struct {
    uint32_t iterations;
    uint8_t salt[WCS_PASSWORD_SALT_LEN];
    uint8_t hash[WCS_PASSWORD_HASH_LEN];
} wcs_password_hash_t;

typedef struct {
    const char *setup_ap_ssid_prefix;
    const char *setup_ap_password;
    const char *direct_ap_ssid_prefix;
    const char *direct_ap_password;
    const char *admin_username;
    wcs_password_hash_t admin_password;
} wcs_defaults_t;

extern const wcs_defaults_t wcs_defaults;
