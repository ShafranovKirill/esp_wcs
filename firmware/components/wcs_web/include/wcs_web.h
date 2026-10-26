/*
 * Веб-интерфейс устройства: вход администратора и страница настроек.
 *
 * Пока HTTP; HTTPS — отдельный этап (ТЗ, этап 1, пункт 3).
 */
#pragma once

#include "esp_err.h"

esp_err_t wcs_web_start(void);
esp_err_t wcs_web_stop(void);
