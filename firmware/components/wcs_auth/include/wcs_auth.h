#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#define WCS_AUTH_TOKEN_LEN 64

typedef enum {
    WCS_AUTH_OK,
    WCS_AUTH_BAD_CREDENTIALS,
    WCS_AUTH_LOCKED,
} wcs_auth_result_t;

esp_err_t wcs_auth_init(void);

wcs_auth_result_t wcs_auth_login(const char *username, const char *password,
                                 char token[WCS_AUTH_TOKEN_LEN + 1], uint32_t *retry_after_s);

bool wcs_auth_session_check(const char *token);

void wcs_auth_logout(const char *token);

void wcs_auth_logout_all(void);
