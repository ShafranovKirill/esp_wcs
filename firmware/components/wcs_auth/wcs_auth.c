#include "wcs_auth.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "psa/crypto.h"
#include "wcs_defaults.h"

#if !defined(PSA_WANT_ALG_PBKDF2_HMAC)
#error "PBKDF2-HMAC is required by wcs_auth"
#endif

#define US_PER_S             1000000LL
#define SESSION_IDLE_TIMEOUT (CONFIG_WCS_AUTH_SESSION_IDLE_TIMEOUT_MIN * 60 * US_PER_S)

typedef struct {
    bool used;
    char token[WCS_AUTH_TOKEN_LEN + 1];
    int64_t last_seen_us;
} session_t;

static const char *TAG = "wcs_auth";

static SemaphoreHandle_t s_lock;
static session_t s_sessions[CONFIG_WCS_AUTH_MAX_SESSIONS];
static uint32_t s_failures;
static int64_t s_locked_until_us;

static bool ct_equal(const void *a, const void *b, size_t len)
{
    const uint8_t *x = a;
    const uint8_t *y = b;
    uint8_t diff = 0;
    for (size_t i = 0; i < len; i++) {
        diff |= x[i] ^ y[i];
    }
    return diff == 0;
}

static bool ct_streq(const char *a, const char *b)
{
    size_t len_a = strlen(a);
    size_t len_b = strlen(b);
    return ct_equal(len_a == len_b ? a : b, b, len_b) && len_a == len_b;
}

static bool password_matches(const char *password, const wcs_password_hash_t *ref)
{
    psa_key_derivation_operation_t op = PSA_KEY_DERIVATION_OPERATION_INIT;
    uint8_t derived[WCS_PASSWORD_HASH_LEN];

    psa_status_t st = psa_key_derivation_setup(&op, PSA_ALG_PBKDF2_HMAC(PSA_ALG_SHA_256));
    if (st == PSA_SUCCESS) {
        st = psa_key_derivation_input_integer(&op, PSA_KEY_DERIVATION_INPUT_COST, ref->iterations);
    }
    if (st == PSA_SUCCESS) {
        st = psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_SALT, ref->salt, sizeof(ref->salt));
    }
    if (st == PSA_SUCCESS) {
        st = psa_key_derivation_input_bytes(&op, PSA_KEY_DERIVATION_INPUT_PASSWORD,
                                            (const uint8_t *)password, strlen(password));
    }
    if (st == PSA_SUCCESS) {
        st = psa_key_derivation_output_bytes(&op, derived, sizeof(derived));
    }
    psa_key_derivation_abort(&op);

    if (st != PSA_SUCCESS) {
        ESP_LOGE(TAG, "PBKDF2 failed: %d", (int)st);
        return false;
    }
    bool match = ct_equal(derived, ref->hash, sizeof(derived));
    memset(derived, 0, sizeof(derived));
    return match;
}

static uint32_t seconds_until(int64_t deadline_us, int64_t now_us)
{
    return deadline_us > now_us ? (uint32_t)((deadline_us - now_us + US_PER_S - 1) / US_PER_S) : 0;
}

static session_t *find_session(const char *token, int64_t now_us)
{
    if (!token || strlen(token) != WCS_AUTH_TOKEN_LEN) {
        return NULL;
    }
    for (size_t i = 0; i < CONFIG_WCS_AUTH_MAX_SESSIONS; i++) {
        session_t *s = &s_sessions[i];
        if (!s->used) {
            continue;
        }
        if (now_us - s->last_seen_us > SESSION_IDLE_TIMEOUT) {
            s->used = false;
            continue;
        }
        if (ct_equal(s->token, token, WCS_AUTH_TOKEN_LEN)) {
            return s;
        }
    }
    return NULL;
}

static void create_session(char token[WCS_AUTH_TOKEN_LEN + 1], int64_t now_us)
{
    session_t *slot = &s_sessions[0];
    for (size_t i = 0; i < CONFIG_WCS_AUTH_MAX_SESSIONS; i++) {
        session_t *s = &s_sessions[i];
        if (!s->used || now_us - s->last_seen_us > SESSION_IDLE_TIMEOUT) {
            slot = s;
            break;
        }
        if (s->last_seen_us < slot->last_seen_us) {
            slot = s;
        }
    }

    uint8_t random[WCS_AUTH_TOKEN_LEN / 2];
    esp_fill_random(random, sizeof(random));
    for (size_t i = 0; i < sizeof(random); i++) {
        snprintf(&slot->token[i * 2], 3, "%02x", random[i]);
    }
    slot->used = true;
    slot->last_seen_us = now_us;
    memcpy(token, slot->token, WCS_AUTH_TOKEN_LEN + 1);
}

esp_err_t wcs_auth_init(void)
{
    if (!s_lock) {
        s_lock = xSemaphoreCreateMutex();
        ESP_RETURN_ON_FALSE(s_lock, ESP_ERR_NO_MEM, TAG, "mutex create failed");
    }
    ESP_LOGI(TAG, "admin user \"%s\", PBKDF2 %" PRIu32 " iterations",
             wcs_defaults.admin_username, wcs_defaults.admin_password.iterations);
    return ESP_OK;
}

wcs_auth_result_t wcs_auth_login(const char *username, const char *password,
                                 char token[WCS_AUTH_TOKEN_LEN + 1], uint32_t *retry_after_s)
{
    *retry_after_s = 0;

    xSemaphoreTake(s_lock, portMAX_DELAY);
    int64_t now_us = esp_timer_get_time();
    if (now_us < s_locked_until_us) {
        *retry_after_s = seconds_until(s_locked_until_us, now_us);
        xSemaphoreGive(s_lock);
        ESP_LOGW(TAG, "login rejected: locked for %" PRIu32 " s", *retry_after_s);
        return WCS_AUTH_LOCKED;
    }
    xSemaphoreGive(s_lock);

    int64_t started_us = esp_timer_get_time();
    bool user_ok = ct_streq(username, wcs_defaults.admin_username);
    bool pass_ok = password_matches(password, &wcs_defaults.admin_password);
    ESP_LOGD(TAG, "password check took %lld ms", (esp_timer_get_time() - started_us) / 1000);

    xSemaphoreTake(s_lock, portMAX_DELAY);
    now_us = esp_timer_get_time();
    wcs_auth_result_t result;
    if (user_ok && pass_ok) {
        s_failures = 0;
        create_session(token, now_us);
        result = WCS_AUTH_OK;
        ESP_LOGI(TAG, "login ok");
    } else {
        s_failures++;
        if (s_failures >= CONFIG_WCS_AUTH_FREE_ATTEMPTS) {
            uint32_t shift = s_failures - CONFIG_WCS_AUTH_FREE_ATTEMPTS;
            int64_t delay_s = shift < 20 ? (int64_t)CONFIG_WCS_AUTH_LOCKOUT_BASE_S << shift
                                         : CONFIG_WCS_AUTH_LOCKOUT_MAX_S;
            if (delay_s > CONFIG_WCS_AUTH_LOCKOUT_MAX_S) {
                delay_s = CONFIG_WCS_AUTH_LOCKOUT_MAX_S;
            }
            s_locked_until_us = now_us + delay_s * US_PER_S;
            *retry_after_s = (uint32_t)delay_s;
        }
        result = WCS_AUTH_BAD_CREDENTIALS;
        ESP_LOGW(TAG, "login failed (%" PRIu32 " in a row), retry after %" PRIu32 " s",
                 s_failures, *retry_after_s);
    }
    xSemaphoreGive(s_lock);
    return result;
}

bool wcs_auth_session_check(const char *token)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    int64_t now_us = esp_timer_get_time();
    session_t *s = find_session(token, now_us);
    if (s) {
        s->last_seen_us = now_us;
    }
    xSemaphoreGive(s_lock);
    return s != NULL;
}

void wcs_auth_logout(const char *token)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    session_t *s = find_session(token, esp_timer_get_time());
    if (s) {
        memset(s, 0, sizeof(*s));
    }
    xSemaphoreGive(s_lock);
}

void wcs_auth_logout_all(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    memset(s_sessions, 0, sizeof(s_sessions));
    xSemaphoreGive(s_lock);
}
