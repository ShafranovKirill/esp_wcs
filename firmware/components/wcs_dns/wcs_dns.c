#include "wcs_dns.h"

#include <stdbool.h>
#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

#define DNS_PORT        53
#define DNS_MAX_LEN     512
#define DNS_HEADER_LEN  12
#define DNS_ANSWER_LEN  16
#define DNS_TYPE_A      1
#define DNS_CLASS_IN    1
#define DNS_ANSWER_TTL  60
#define TASK_STACK_SIZE 4096
#define TASK_PRIORITY   5

static const char *TAG = "wcs_dns";

static esp_ip4_addr_t s_answer_ip;
static TaskHandle_t s_task;
static volatile bool s_stop;

static void put_u16(uint8_t *p, uint16_t v)
{
    p[0] = v >> 8;
    p[1] = v & 0xff;
}

static uint16_t get_u16(const uint8_t *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}

/*
 * Превращает запрос в ответ на месте. Возвращает длину ответа или 0, если
 * запрос не обрабатывается. Поддерживается один вопрос; на A/IN отвечаем
 * адресом устройства, на остальное — пустым ответом без ошибки.
 */
static size_t build_reply(uint8_t *buf, size_t len)
{
    if (len < DNS_HEADER_LEN || (buf[2] & 0x80) || get_u16(buf + 4) != 1) {
        return 0;
    }

    size_t pos = DNS_HEADER_LEN;
    while (pos < len && buf[pos] != 0) {
        if (buf[pos] & 0xc0) {
            return 0; /* сжатие имён в вопросе не ожидается */
        }
        pos += buf[pos] + 1;
    }
    pos += 1 + 4; /* нулевая метка, QTYPE, QCLASS */
    if (pos > len) {
        return 0;
    }

    uint16_t qtype = get_u16(buf + pos - 4);
    uint16_t qclass = get_u16(buf + pos - 2);
    bool answer = qtype == DNS_TYPE_A && qclass == DNS_CLASS_IN;

    buf[2] = 0x80 | (buf[2] & 0x79) | 0x04; /* QR=1, opcode и RD из запроса, AA=1 */
    buf[3] = 0x00;                          /* RA=0, RCODE=0 */
    put_u16(buf + 6, answer ? 1 : 0);       /* ANCOUNT */
    put_u16(buf + 8, 0);                    /* NSCOUNT */
    put_u16(buf + 10, 0);                   /* ARCOUNT: дополнительные записи (EDNS) отбрасываем */

    if (!answer) {
        return pos;
    }
    if (pos + DNS_ANSWER_LEN > DNS_MAX_LEN) {
        return 0;
    }

    uint8_t *a = buf + pos;
    put_u16(a, 0xc000 | DNS_HEADER_LEN); /* имя — ссылка на вопрос */
    put_u16(a + 2, DNS_TYPE_A);
    put_u16(a + 4, DNS_CLASS_IN);
    put_u16(a + 6, 0);
    put_u16(a + 8, DNS_ANSWER_TTL);
    put_u16(a + 10, 4);
    memcpy(a + 12, &s_answer_ip.addr, 4); /* addr уже в сетевом порядке байт */
    return pos + DNS_ANSWER_LEN;
}

static void dns_task(void *arg)
{
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) {
        ESP_LOGE(TAG, "socket failed: errno %d", errno);
        goto out;
    }

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(DNS_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ESP_LOGE(TAG, "bind failed: errno %d", errno);
        goto out;
    }

    /* Таймаут, чтобы периодически проверять флаг остановки */
    struct timeval timeout = { .tv_sec = 1 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    ESP_LOGI(TAG, "started, answering " IPSTR, IP2STR(&s_answer_ip));

    uint8_t buf[DNS_MAX_LEN];
    while (!s_stop) {
        struct sockaddr_in from;
        socklen_t from_len = sizeof(from);
        int len = recvfrom(sock, buf, sizeof(buf), 0, (struct sockaddr *)&from, &from_len);
        if (len <= 0) {
            continue;
        }
        size_t reply_len = build_reply(buf, len);
        if (reply_len > 0) {
            sendto(sock, buf, reply_len, 0, (struct sockaddr *)&from, from_len);
        }
    }

out:
    if (sock >= 0) {
        close(sock);
    }
    ESP_LOGI(TAG, "stopped");
    s_task = NULL;
    vTaskDelete(NULL);
}

esp_err_t wcs_dns_start(esp_ip4_addr_t answer_ip)
{
    ESP_RETURN_ON_FALSE(!s_task, ESP_ERR_INVALID_STATE, TAG, "already running");
    s_answer_ip = answer_ip;
    s_stop = false;
    BaseType_t ok = xTaskCreate(dns_task, "wcs_dns", TASK_STACK_SIZE, NULL, TASK_PRIORITY, &s_task);
    ESP_RETURN_ON_FALSE(ok == pdPASS, ESP_ERR_NO_MEM, TAG, "task create failed");
    return ESP_OK;
}

void wcs_dns_stop(void)
{
    s_stop = true; /* задача завершится сама в течение секунды */
}
