/* Внутренний интерфейс между частями wcs_link */
#pragma once

#include <stddef.h>

#include "esp_err.h"
#include "esp_timer.h"
#include "wcs_link.h"

/* Выполнить fn в задаче с большим стеком (подпись ECDSA) и дождаться результата */
esp_err_t link_run_with_stack(esp_err_t (*fn)(void *arg), void *arg);

const char *link_key_pem(void);
esp_err_t link_make_csr(const char *device_id, char *out, size_t out_size);

/* Сертификат устройства, если он выдан бастионом с этим кодом CA; *cert_pem — освободить free() */
esp_err_t link_load_certificate(const char *ca_code, char **cert_pem);
esp_err_t link_save_certificate(const char *cert_pem, const char *ca_code);
