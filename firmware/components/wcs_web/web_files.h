/* Файлы из www/, встроенные в прошивку генератором gen_www.py */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    const char *path; /* относительно www/: "pages/login.html", "assets/style.css" */
    const char *type; /* Content-Type */
    const uint8_t *data;
    size_t len;
    bool gzip;        /* data сжаты, отдавать с Content-Encoding: gzip */
} web_file_t;

extern const web_file_t web_files[];
extern const size_t web_files_count;
