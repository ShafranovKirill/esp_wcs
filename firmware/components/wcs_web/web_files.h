#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    const char *path;
    const char *type;
    const uint8_t *data;
    size_t len;
    bool gzip;
} web_file_t;

extern const web_file_t web_files[];
extern const size_t web_files_count;
