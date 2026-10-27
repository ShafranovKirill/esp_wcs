#include "wcs_tls.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "mbedtls/asn1.h"
#include "mbedtls/oid.h"
#include "mbedtls/pk.h"
#include "mbedtls/x509_crt.h"
#include "nvs.h"
#include "psa/crypto.h"

#define NVS_NAMESPACE  "wcs_tls"
#define NVS_KEY_KEY    "key"
#define NVS_KEY_CERT   "cert"
#define NVS_KEY_ID     "id"

#define KEY_PEM_MAX    512
#define CERT_PEM_MAX   2048
#define ID_MAX         96
#define SERIAL_LEN     16
#define GEN_TASK_STACK 12288

#define VALID_FROM     "20250101000000"
#define VALID_TO       "20991231235959"

static const char *TAG = "wcs_tls";

static char *s_key_pem;
static char *s_cert_pem;

static char *load_str(nvs_handle_t nvs, const char *key, size_t max)
{
    size_t len = 0;
    if (nvs_get_blob(nvs, key, NULL, &len) != ESP_OK || len == 0 || len > max) {
        return NULL;
    }
    char *buf = malloc(len);
    if (!buf) {
        return NULL;
    }
    if (nvs_get_blob(nvs, key, buf, &len) != ESP_OK || buf[len - 1] != '\0') {
        free(buf);
        return NULL;
    }
    return buf;
}

static bool load(const char *id)
{
    nvs_handle_t nvs;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs) != ESP_OK) {
        return false;
    }
    char *saved_id = load_str(nvs, NVS_KEY_ID, ID_MAX);
    char *key = load_str(nvs, NVS_KEY_KEY, KEY_PEM_MAX);
    char *cert = load_str(nvs, NVS_KEY_CERT, CERT_PEM_MAX);
    nvs_close(nvs);

    bool ok = saved_id && key && cert && strcmp(saved_id, id) == 0;
    if (ok) {
        mbedtls_pk_context pk;
        mbedtls_x509_crt crt;
        mbedtls_pk_init(&pk);
        mbedtls_x509_crt_init(&crt);
        ok = mbedtls_pk_parse_key(&pk, (const unsigned char *)key, strlen(key) + 1, NULL, 0) == 0 &&
             mbedtls_x509_crt_parse(&crt, (const unsigned char *)cert, strlen(cert) + 1) == 0;
        mbedtls_x509_crt_free(&crt);
        mbedtls_pk_free(&pk);
    }
    free(saved_id);

    if (!ok) {
        if (key) {
            memset(key, 0, strlen(key));
        }
        free(key);
        free(cert);
        return false;
    }
    s_key_pem = key;
    s_cert_pem = cert;
    return true;
}

static esp_err_t save(const char *id)
{
    nvs_handle_t nvs;
    ESP_RETURN_ON_ERROR(nvs_open(NVS_NAMESPACE, NVS_READWRITE, &nvs), TAG, "nvs_open failed");
    esp_err_t err = nvs_set_blob(nvs, NVS_KEY_KEY, s_key_pem, strlen(s_key_pem) + 1);
    if (err == ESP_OK) {
        err = nvs_set_blob(nvs, NVS_KEY_CERT, s_cert_pem, strlen(s_cert_pem) + 1);
    }
    if (err == ESP_OK) {
        err = nvs_set_blob(nvs, NVS_KEY_ID, id, strlen(id) + 1);
    }
    if (err == ESP_OK) {
        err = nvs_commit(nvs);
    }
    nvs_close(nvs);
    return err;
}

static esp_err_t generate_key(mbedtls_pk_context *pk)
{
    psa_key_attributes_t attr = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attr, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_SECP_R1));
    psa_set_key_bits(&attr, 256);
    psa_set_key_usage_flags(&attr, PSA_KEY_USAGE_SIGN_HASH | PSA_KEY_USAGE_EXPORT);
    psa_set_key_algorithm(&attr, PSA_ALG_ECDSA(PSA_ALG_SHA_256));

    mbedtls_svc_key_id_t key_id;
    psa_status_t st = psa_generate_key(&attr, &key_id);
    psa_reset_key_attributes(&attr);
    if (st != PSA_SUCCESS) {
        ESP_LOGE(TAG, "psa_generate_key: %d", (int)st);
        return ESP_FAIL;
    }
    int ret = mbedtls_pk_copy_from_psa(key_id, pk);
    psa_destroy_key(key_id);
    if (ret != 0) {
        ESP_LOGE(TAG, "mbedtls_pk_copy_from_psa: -0x%x", -ret);
        return ESP_FAIL;
    }
    return ESP_OK;
}

static esp_err_t write_cert(mbedtls_pk_context *pk, const wcs_tls_identity_t *identity, char *out, size_t out_size)
{
    char subject[96];
    snprintf(subject, sizeof(subject), "CN=%s,O=ESP WCS", identity->common_name);

    unsigned char serial[SERIAL_LEN];
    if (psa_generate_random(serial, sizeof(serial)) != PSA_SUCCESS) {
        return ESP_FAIL;
    }
    serial[0] &= 0x7f;
    serial[0] |= 0x01;

    char dns[80];
    snprintf(dns, sizeof(dns), "%s.local", identity->common_name);
    uint8_t ip[4];
    memcpy(ip, &identity->ip.addr, sizeof(ip));
    mbedtls_x509_san_list san_dns = {
        .node = { .type = MBEDTLS_X509_SAN_DNS_NAME,
                  .san.unstructured_name = { .p = (unsigned char *)dns, .len = strlen(dns) } },
    };
    mbedtls_x509_san_list san_ip = {
        .node = { .type = MBEDTLS_X509_SAN_IP_ADDRESS,
                  .san.unstructured_name = { .p = ip, .len = sizeof(ip) } },
        .next = &san_dns,
    };

    mbedtls_asn1_sequence server_auth = {
        .buf = { .tag = MBEDTLS_ASN1_OID, .p = (unsigned char *)MBEDTLS_OID_SERVER_AUTH,
                 .len = MBEDTLS_OID_SIZE(MBEDTLS_OID_SERVER_AUTH) },
    };

    mbedtls_x509write_cert crt;
    mbedtls_x509write_crt_init(&crt);
    mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&crt, pk);
    mbedtls_x509write_crt_set_issuer_key(&crt, pk);

    int ret = mbedtls_x509write_crt_set_subject_name(&crt, subject);
    if (ret == 0) {
        ret = mbedtls_x509write_crt_set_issuer_name(&crt, subject);
    }
    if (ret == 0) {
        ret = mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof(serial));
    }
    if (ret == 0) {
        ret = mbedtls_x509write_crt_set_validity(&crt, VALID_FROM, VALID_TO);
    }
    if (ret == 0) {
        ret = mbedtls_x509write_crt_set_basic_constraints(&crt, 0, -1);
    }
    if (ret == 0) {
        ret = mbedtls_x509write_crt_set_key_usage(&crt, MBEDTLS_X509_KU_DIGITAL_SIGNATURE);
    }
    if (ret == 0) {
        ret = mbedtls_x509write_crt_set_ext_key_usage(&crt, &server_auth);
    }
    if (ret == 0) {
        ret = mbedtls_x509write_crt_set_subject_alternative_name(&crt, &san_ip);
    }
    if (ret == 0) {
        ret = mbedtls_x509write_crt_set_subject_key_identifier(&crt);
    }
    if (ret == 0) {
        ret = mbedtls_x509write_crt_pem(&crt, (unsigned char *)out, out_size);
    }
    mbedtls_x509write_crt_free(&crt);

    if (ret != 0) {
        ESP_LOGE(TAG, "certificate write failed: -0x%x", -ret);
        return ESP_FAIL;
    }
    return ESP_OK;
}

static esp_err_t generate(const wcs_tls_identity_t *identity)
{
    int64_t start = esp_timer_get_time();
    s_key_pem = calloc(1, KEY_PEM_MAX);
    s_cert_pem = calloc(1, CERT_PEM_MAX);
    ESP_RETURN_ON_FALSE(s_key_pem && s_cert_pem, ESP_ERR_NO_MEM, TAG, "no memory");

    mbedtls_pk_context pk;
    mbedtls_pk_init(&pk);
    esp_err_t err = generate_key(&pk);
    if (err == ESP_OK && mbedtls_pk_write_key_pem(&pk, (unsigned char *)s_key_pem, KEY_PEM_MAX) != 0) {
        ESP_LOGE(TAG, "key write failed");
        err = ESP_FAIL;
    }
    if (err == ESP_OK) {
        err = write_cert(&pk, identity, s_cert_pem, CERT_PEM_MAX);
    }
    mbedtls_pk_free(&pk);

    if (err != ESP_OK) {
        memset(s_key_pem, 0, KEY_PEM_MAX);
        free(s_key_pem);
        free(s_cert_pem);
        s_key_pem = s_cert_pem = NULL;
        return err;
    }
    ESP_LOGI(TAG, "generated ECDSA P-256 key and certificate in %lld ms",
             (esp_timer_get_time() - start) / 1000);
    return ESP_OK;
}

typedef struct {
    const wcs_tls_identity_t *identity;
    SemaphoreHandle_t done;
    esp_err_t err;
} gen_job_t;

static void gen_task(void *arg)
{
    gen_job_t *job = arg;
    job->err = generate(job->identity);
    xSemaphoreGive(job->done);
    vTaskDelete(NULL);
}

static esp_err_t generate_in_task(const wcs_tls_identity_t *identity)
{
    gen_job_t job = { .identity = identity, .done = xSemaphoreCreateBinary() };
    ESP_RETURN_ON_FALSE(job.done, ESP_ERR_NO_MEM, TAG, "no memory");
    if (xTaskCreate(gen_task, "wcs_tls_gen", GEN_TASK_STACK, &job, uxTaskPriorityGet(NULL), NULL) != pdPASS) {
        vSemaphoreDelete(job.done);
        return ESP_ERR_NO_MEM;
    }
    xSemaphoreTake(job.done, portMAX_DELAY);
    vSemaphoreDelete(job.done);
    return job.err;
}

esp_err_t wcs_tls_init(const wcs_tls_identity_t *identity)
{
    ESP_RETURN_ON_FALSE(identity && identity->common_name, ESP_ERR_INVALID_ARG, TAG, "identity is NULL");
    ESP_RETURN_ON_FALSE(!s_key_pem, ESP_ERR_INVALID_STATE, TAG, "already initialized");

    char id[ID_MAX];
    snprintf(id, sizeof(id), "%s|" IPSTR, identity->common_name, IP2STR(&identity->ip));

    if (load(id)) {
        ESP_LOGI(TAG, "certificate loaded for %s", id);
        return ESP_OK;
    }

    ESP_LOGI(TAG, "no valid certificate for %s, generating", id);
    ESP_RETURN_ON_ERROR(generate_in_task(identity), TAG, "generation failed");
    esp_err_t err = save(id);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "certificate save failed: %s", esp_err_to_name(err));
    }
    return ESP_OK;
}

esp_err_t wcs_tls_get_server_cred(wcs_tls_server_cred_t *cred)
{
    ESP_RETURN_ON_FALSE(cred, ESP_ERR_INVALID_ARG, TAG, "cred is NULL");
    ESP_RETURN_ON_FALSE(s_key_pem && s_cert_pem, ESP_ERR_INVALID_STATE, TAG, "not initialized");
    cred->cert_pem = s_cert_pem;
    cred->cert_len = strlen(s_cert_pem) + 1;
    cred->key_pem = s_key_pem;
    cred->key_len = strlen(s_key_pem) + 1;
    return ESP_OK;
}
