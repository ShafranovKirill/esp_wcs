#include "wcs_storage.h"

#include <string.h>

#include "esp_check.h"
#include "nvs.h"

#define NVS_NAMESPACE    "wcs"
#define KEY_MODE         "mode"
#define KEY_STA_SSID     "sta_ssid"
#define KEY_STA_PASSWORD "sta_pass"
#define KEY_BASTION      "bastion"

static const char *TAG = "wcs_storage";

static esp_err_t read_str(nvs_handle_t nvs, const char *key, char *out, size_t out_size)
{
    size_t len = out_size;
    esp_err_t err = nvs_get_str(nvs, key, out, &len);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        out[0] = '\0';
        return ESP_OK;
    }
    return err;
}

esp_err_t wcs_storage_load(wcs_settings_t *settings)
{
    ESP_RETURN_ON_FALSE(settings, ESP_ERR_INVALID_ARG, TAG, "settings is NULL");
    memset(settings, 0, sizeof(*settings));

    nvs_handle_t nvs;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        return ESP_OK; /* ничего ещё не сохранялось */
    }
    ESP_RETURN_ON_ERROR(err, TAG, "nvs_open failed");

    uint8_t mode = WCS_MODE_FACTORY;
    err = nvs_get_u8(nvs, KEY_MODE, &mode);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        err = ESP_OK;
    }
    if (err == ESP_OK) {
        err = read_str(nvs, KEY_STA_SSID, settings->sta_ssid, sizeof(settings->sta_ssid));
    }
    if (err == ESP_OK) {
        err = read_str(nvs, KEY_STA_PASSWORD, settings->sta_password, sizeof(settings->sta_password));
    }
    if (err == ESP_OK) {
        err = read_str(nvs, KEY_BASTION, settings->bastion_addr, sizeof(settings->bastion_addr));
    }
    nvs_close(nvs);
    ESP_RETURN_ON_ERROR(err, TAG, "read failed");

    settings->mode = mode <= WCS_MODE_BASTION ? (wcs_mode_t)mode : WCS_MODE_FACTORY;
    return ESP_OK;
}

esp_err_t wcs_storage_save(const wcs_settings_t *settings)
{
    ESP_RETURN_ON_FALSE(settings, ESP_ERR_INVALID_ARG, TAG, "settings is NULL");

    nvs_handle_t nvs;
    ESP_RETURN_ON_ERROR(nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs), TAG, "nvs_open failed");

    esp_err_t err = nvs_set_u8(nvs, KEY_MODE, (uint8_t)settings->mode);
    if (err == ESP_OK) {
        err = nvs_set_str(nvs, KEY_STA_SSID, settings->sta_ssid);
    }
    if (err == ESP_OK) {
        err = nvs_set_str(nvs, KEY_STA_PASSWORD, settings->sta_password);
    }
    if (err == ESP_OK) {
        err = nvs_set_str(nvs, KEY_BASTION, settings->bastion_addr);
    }
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    ESP_RETURN_ON_ERROR(err, TAG, "write failed");
    return ESP_OK;
}

esp_err_t wcs_storage_erase(void)
{
    nvs_handle_t nvs;
    ESP_RETURN_ON_ERROR(nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs), TAG, "nvs_open failed");
    esp_err_t err = nvs_erase_all(nvs);
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}
