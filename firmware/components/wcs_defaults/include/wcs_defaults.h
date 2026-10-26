/*
 * Заводские настройки устройства.
 *
 * Значения задаются в firmware/.env и генерируются при сборке (gen_defaults.py).
 * Используются, пока пользователь не сохранил свои настройки.
 */
#pragma once

#include <stdint.h>

#define WCS_PASSWORD_SALT_LEN 16
#define WCS_PASSWORD_HASH_LEN 32

/* Пароль, сохранённый как PBKDF2-HMAC-SHA256 */
typedef struct {
    uint32_t iterations;
    uint8_t salt[WCS_PASSWORD_SALT_LEN];
    uint8_t hash[WCS_PASSWORD_HASH_LEN];
} wcs_password_hash_t;

typedef struct {
    const char *setup_ap_ssid_prefix; /* к нему добавляются 4 hex-цифры MAC */
    const char *setup_ap_password;
    const char *direct_ap_ssid_prefix; /* к нему добавляются 4 hex-цифры MAC */
    const char *direct_ap_password;
    const char *admin_username;
    wcs_password_hash_t admin_password;
} wcs_defaults_t;

extern const wcs_defaults_t wcs_defaults;
