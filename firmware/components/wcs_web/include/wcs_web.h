/*
 * Веб-интерфейс устройства.
 *
 * Режимы сервера:
 *   SETUP  — вход и мастер настройки: выбор Direct / Bastion, поиск Wi-Fi, адрес бастиона;
 *   DIRECT — вход и консоль. Страниц и API настройки в этом режиме нет совсем.
 *
 * Пока HTTP; HTTPS — отдельный этап (ТЗ, этап 1, пункт 3).
 */
#pragma once

#include "esp_err.h"
#include "wcs_storage.h"

typedef enum {
    WCS_WEB_MODE_SETUP,
    WCS_WEB_MODE_DIRECT,
} wcs_web_mode_t;

/* Что показать пользователю при выборе Direct connection */
typedef struct {
    const char *ssid;
    const char *password;
    const char *url;
} wcs_web_direct_info_t;

typedef struct {
    wcs_web_mode_t mode;

    /* Только для WCS_WEB_MODE_SETUP. Строки должны жить, пока работает сервер. */
    wcs_web_direct_info_t direct;
    /*
     * Пользователь применил настройки (уже проверены). Вызывается из задачи
     * веб-сервера; должен сохранить настройки и запланировать смену режима —
     * ответ браузеру уходит после возврата, поэтому сервер нельзя останавливать сразу.
     */
    esp_err_t (*apply)(const wcs_settings_t *settings);
} wcs_web_config_t;

esp_err_t wcs_web_start(const wcs_web_config_t *config);
esp_err_t wcs_web_stop(void);
