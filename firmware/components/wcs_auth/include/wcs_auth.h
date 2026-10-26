/*
 * Авторизация администратора: проверка пароля (PBKDF2), сессии, защита от перебора.
 *
 * Сессия — случайный токен, который веб-сервер кладёт в cookie.
 * Все функции потокобезопасны.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#define WCS_AUTH_TOKEN_LEN 64 /* hex-строка из 32 случайных байт, без завершающего нуля */

typedef enum {
    WCS_AUTH_OK,
    WCS_AUTH_BAD_CREDENTIALS,
    WCS_AUTH_LOCKED, /* слишком много неверных попыток, нужно подождать */
} wcs_auth_result_t;

esp_err_t wcs_auth_init(void);

/*
 * Проверяет логин и пароль. При успехе создаёт сессию и пишет её токен в token.
 * При WCS_AUTH_LOCKED и WCS_AUTH_BAD_CREDENTIALS в retry_after_s — через сколько
 * секунд можно пробовать снова (0 — сразу). Проверка занимает заметное время (PBKDF2).
 */
wcs_auth_result_t wcs_auth_login(const char *username, const char *password,
                                 char token[WCS_AUTH_TOKEN_LEN + 1], uint32_t *retry_after_s);

/* Проверяет токен и продлевает сессию */
bool wcs_auth_session_check(const char *token);

void wcs_auth_logout(const char *token);

/* Завершить все сессии (при смене режима устройства) */
void wcs_auth_logout_all(void);
