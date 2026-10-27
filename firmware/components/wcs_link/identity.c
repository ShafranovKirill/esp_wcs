#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "link_priv.h"
#include "mbedtls/pk.h"
#include "mbedtls/x509_csr.h"
#include "nvs.h"
#include "psa/crypto.h"
#include "wcs_bastion.h"

#define NVS_NAMESPACE  "wcs_link"
#define KEY_KEY        "key"
#define KEY_CERT       "cert"
#define KEY_CERT_CA    "cert_ca"

#define KEY_PEM_MAX    512
#define GEN_TASK_STACK 12288

static const char *TAG = "wcs_link_id";

static char *s_key_pem;
static char s_device_code[WCS_LINK_CODE_LEN + 1];

static esp_err_t nvs_read_str(const char *key, char **out)
{
    nvs_handle_t nvs;
    esp_err_t err = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (err != ESP_OK) {
        return err;
    }
    size_t len = 0;
    err = nvs_get_str(nvs, key, NULL, &len);
    if (err == ESP_OK) {
        *out = malloc(len);
        err = *out ? nvs_get_str(nvs, key, *out, &len) : ESP_ERR_NO_MEM;
        if (err != ESP_OK) {
            free(*out);
            *out = NULL;
        }
    }
    nvs_close(nvs);
    return err;
}

static esp_err_t nvs_write(const char *const keys[], const char *const values[], size_t n)
{
    nvs_handle_t nvs;
    ESP_RETURN_ON_ERROR(nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs), TAG, "nvs_open failed");
    esp_err_t err = ESP_OK;
    for (size_t i = 0; i < n && err == ESP_OK; i++) {
        err = values[i] ? nvs_set_str(nvs, keys[i], values[i]) : nvs_erase_key(nvs, keys[i]);
        if (err == ESP_ERR_NVS_NOT_FOUND) {
            err = ESP_OK;
        }
    }
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}

static esp_err_t parse_key(mbedtls_pk_context *pk)
{
    mbedtls_pk_init(pk);
    int ret = mbedtls_pk_parse_key(pk, (const unsigned char *)s_key_pem, strlen(s_key_pem) + 1, NULL, 0);
    return ret == 0 ? ESP_OK : ESP_FAIL;
}

static esp_err_t compute_code(void)
{
    mbedtls_pk_context pk;
    ESP_RETURN_ON_ERROR(parse_key(&pk), TAG, "key parse failed");

    unsigned char der[160];
    int len = mbedtls_pk_write_pubkey_der(&pk, der, sizeof(der));
    mbedtls_pk_free(&pk);
    ESP_RETURN_ON_FALSE(len > 0, ESP_FAIL, TAG, "public key write failed");
    return wcs_bastion_code(der + sizeof(der) - len, len, s_device_code);
}

static esp_err_t generate_key(void)
{
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(&attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));

    mbedtls_svc_key_id_t key_id;
    psa_status_t st = psa_generate_key(&attr, &key_id);
    psa_reset_key_attributes(&attr);
    ESP_RETURN_ON_FALSE(st == PSA_SUCCESS, ESP_FAIL, TAG, "psa_generate_key: %d", (int)st);

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    char *pem = calloc(1, KEY_PEM_MAX);
    esp_err_t err = ESP_FAIL;
    if (pem && mbedtls_pk_copy_from_psa(key_id, &pk) == 0 &&
        mbedtls_pk_write_key_pem(&pk, (unsigned char *)pem, KEY_PEM_MAX) == 0) {
        err = ESP_OK;
    }
    mbedtls_pk_free(&pk);
    psa_destroy_key(key_id);

    if (err != ESP_OK) {
        free(pem);
        return err;
    }
    const char *keys[] = { KEY_KEY, KEY_CERT, KEY_CERT_CA };
    const char *values[] = { pem, NULL, NULL };
    err = nvs_write(keys, values, 3);
    if (err != ESP_OK) {
        memset(pem, 0, KEY_PEM_MAX);
        free(pem);
        return err;
    }
    s_key_pem = pem;
    return ESP_OK;
}

typedef struct {
    esp_err_t (*fn)(void *arg);
    void *arg;
    SemaphoreHandle_t done;
    esp_err_t err;
} job_t;

static void job_task(void *arg)
{
    job_t *job = arg;
    job->err = job->fn(job->arg);
    xSemaphoreGive(job->done);
    vTaskDelete(NULL);
}

esp_err_t link_run_with_stack(esp_err_t (*fn)(void *arg), void *arg)
{
    job_t job = { .fn = fn, .arg = arg, .done = xSemaphoreCreateBinary() };
    ESP_RETURN_ON_FALSE(job.done, ESP_ERR_NO_MEM, TAG, "no memory");
    if (xTaskCreate(job_task, "wcs_link_job", GEN_TASK_STACK, &job, uxTaskPriorityGet(NULL), NULL) != pdPASS) {
        vSemaphoreDelete(job.done);
        return ESP_ERR_NO_MEM;
    }
    xSemaphoreTake(job.done, portMAX_DELAY);
    vSemaphoreDelete(job.done);
    return job.err;
}

static esp_err_t init_job(void *arg)
{
    if (nvs_read_str(KEY_KEY, &s_key_pem) != ESP_OK) {
        int64_t start = esp_timer_get_time();
        ESP_RETURN_ON_ERROR(generate_key(), TAG, "key generation failed");
        ESP_LOGI(TAG, "device key generated in %lld ms", (esp_timer_get_time() - start) / 1000);
    }
    return compute_code();
}

esp_err_t wcs_link_identity_init(void)
{
    ESP_RETURN_ON_FALSE(!s_key_pem, ESP_ERR_INVALID_STATE, TAG, "already initialized");
    ESP_RETURN_ON_ERROR(link_run_with_stack(init_job, NULL), TAG, "identity init failed");

    char id[WCS_LINK_DEVICE_ID_LEN + 1];
    wcs_link_device_id(id);
    ESP_LOGI(TAG, "device %s, code %s", id, s_device_code);
    return ESP_OK;
}

esp_err_t wcs_link_device_id(char out[WCS_LINK_DEVICE_ID_LEN + 1])
{
    uint8_t mac[6];
    ESP_RETURN_ON_ERROR(esp_read_mac(mac, ESP_MAC_BASE), TAG, "mac read failed");
    snprintf(out, WCS_LINK_DEVICE_ID_LEN + 1, "%02x%02x%02x%02x%02x%02x", mac[0], mac[1], mac[2], mac[3], mac[4],
             mac[5]);
    return ESP_OK;
}

esp_err_t wcs_link_device_code(char out[WCS_LINK_CODE_LEN + 1])
{
    ESP_RETURN_ON_FALSE(s_key_pem, ESP_ERR_INVALID_STATE, TAG, "not initialized");
    strlcpy(out, s_device_code, WCS_LINK_CODE_LEN + 1);
    return ESP_OK;
}

esp_err_t wcs_link_forget_certificate(void)
{
    const char *keys[] = { KEY_CERT, KEY_CERT_CA };
    const char *values[] = { NULL, NULL };
    return nvs_write(keys, values, 2);
}

const char *link_key_pem(void)
{
    return s_key_pem;
}

typedef struct {
    const char *device_id;
    char *out;
    size_t out_size;
} csr_job_t;

static esp_err_t csr_job(void *arg)
{
    csr_job_t *job = arg;
    mbedtls_pk_context pk;
    ESP_RETURN_ON_ERROR(parse_key(&pk), TAG, "key parse failed");

    char subject[24];
    snprintf(subject, sizeof(subject), "CN=%s", job->device_id);

    mbedtls_x509write_csr csr;
    mbedtls_x509write_csr_init(&csr);
    mbedtls_x509write_csr_set_md_alg(&csr, MBEDTLS_MD_SHA256);
    mbedtls_x509write_csr_set_key(&csr, &pk);
    int ret = mbedtls_x509write_csr_set_subject_name(&csr, subject);
    if (ret == 0) {
        ret = mbedtls_x509write_csr_pem(&csr, (unsigned char *)job->out, job->out_size);
    }
    mbedtls_x509write_csr_free(&csr);
    mbedtls_pk_free(&pk);
    ESP_RETURN_ON_FALSE(ret == 0, ESP_FAIL, TAG, "CSR write failed: -0x%x", -ret);
    return ESP_OK;
}

esp_err_t link_make_csr(const char *device_id, char *out, size_t out_size)
{
    csr_job_t job = { .device_id = device_id, .out = out, .out_size = out_size };
    return link_run_with_stack(csr_job, &job);
}

esp_err_t link_load_certificate(const char *ca_code, char **cert_pem)
{
    char *issuer = NULL;
    *cert_pem = NULL;
    if (nvs_read_str(KEY_CERT_CA, &issuer) != ESP_OK) {
        return ESP_ERR_NOT_FOUND;
    }
    bool same_ca = strcmp(issuer, ca_code) == 0;
    free(issuer);
    if (!same_ca) {
        ESP_LOGW(TAG, "certificate was issued by another bastion, forgetting it");
        wcs_link_forget_certificate();
        return ESP_ERR_NOT_FOUND;
    }
    return nvs_read_str(KEY_CERT, cert_pem) == ESP_OK ? ESP_OK : ESP_ERR_NOT_FOUND;
}

esp_err_t link_save_certificate(const char *cert_pem, const char *ca_code)
{
    const char *keys[] = { KEY_CERT, KEY_CERT_CA };
    const char *values[] = { cert_pem, ca_code };
    return nvs_write(keys, values, 2);
}
