from pathlib import Path
import tempfile, subprocess
root=Path(__file__).resolve().parents[1]/'components/wcs_button'
with tempfile.TemporaryDirectory() as d:
 p=Path(d)
 for name in ['driver/gpio.h','esp_err.h','esp_event.h','esp_check.h','esp_log.h','esp_timer.h','freertos/FreeRTOS.h','freertos/task.h']:
  f=p/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text('#include "mock.h"\n')
 (p/'mock.h').write_text('''#pragma once
#include <stdint.h>
#include <stddef.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
typedef int gpio_num_t;
typedef int esp_err_t;
typedef int BaseType_t;
typedef struct { uint64_t pin_bit_mask; int mode,pull_up_en,pull_down_en,intr_type; } gpio_config_t;
#define ESP_EVENT_DECLARE_BASE(x) extern int x
#define ESP_EVENT_DEFINE_BASE(x) int x
#define ESP_OK 0
#define ESP_ERR_INVALID_ARG 1
#define ESP_ERR_NO_MEM 2
#define GPIO_MODE_INPUT 0
#define GPIO_PULLUP_ENABLE 1
#define GPIO_PULLUP_DISABLE 0
#define GPIO_PULLDOWN_ENABLE 1
#define GPIO_PULLDOWN_DISABLE 0
#define GPIO_INTR_DISABLE 0
#define ESP_RETURN_ON_FALSE(c,e,...) do {if(!(c)) return e;} while(0)
#define ESP_RETURN_ON_ERROR(c,...) do {int e=(c);if(e) return e;} while(0)
#define ESP_LOGI(...) ((void)0)
#define ESP_LOGW(...) ((void)0)
#define pdPASS 1
#define pdMS_TO_TICKS(x) (x)
static int ms, clicks, hold, stop_ms, events[32], count;
static jmp_buf done;
static void (*task)(void *);
static int64_t esp_timer_get_time(void) {return (int64_t)ms*1000;}
static int gpio_get_level(int gpio) { for(int i=0;i<clicks;i++) if(ms>=100+i*180 && ms<100+i*180+hold) return 0; return 1; }
static int gpio_config(const gpio_config_t *c) {return 0;}
static int esp_event_post(int b,int e,void *v,size_t n,int t) {events[count++]=e;return 0;}
static void vTaskDelay(int n) {ms+=n;if(ms>stop_ms) longjmp(done,1);}
static int xTaskCreate(void (*f)(void *),const char *name,int stack,void *arg,int priority,void *out) {task=f;return 1;}
''')
 (p/'test.c').write_text('''#include "mock.h"
#include "wcs_button.c"
static void run(int n,int duration,int expected) {
 ms=0;clicks=n;hold=duration;stop_ms=100+n*180+duration+1000;count=0;s_click_count=0;s_last_click_us=0;
 wcs_button_config_t c={.active_level=0,.click_max_ms=1000,.long_press_ms=5000,.very_long_press_ms=15000,.multi_click_gap_ms=500};
 if(wcs_button_init(&c)) abort();
 if(!setjmp(done)) task(NULL);
 if((expected < 0 && count != 0) || (expected >= 0 && (count != 1 || events[0] != expected))) {printf("failed clicks=%d count=%d first=%d\\n",n,count,events[0]);exit(1);}
}
int main(void) {
 run(1,70,WCS_BUTTON_EVENT_CLICK);
 run(3,70,WCS_BUTTON_EVENT_TRIPLE_CLICK);
 run(6,70,WCS_BUTTON_EVENT_SIX_CLICK);
 run(4,70,-1);
 return 0;
}
''')
 subprocess.run(['cc','-I'+str(p),'-I'+str(root/'include'),'-I'+str(root),str(p/'test.c'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
 print('Button simulation: single/triple/six clicks and ignored four clicks passed')
