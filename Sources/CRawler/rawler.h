// rawler-ffi/src/lib.rs の C ABI(手書きヘッダー)
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t width;
    uint32_t height;
    float *data;      // RGBA f32, linear sRGB (D65)
    size_t len;
    uint16_t orientation;
} RlImage;

typedef struct {
    char make[64];
    char model[64];
    char lens[128];
    char date[32];
    double iso;
    double shutter;
    double aperture;
    double focal_length;
} RlMetadata;

const char *rl_version(void);
int32_t rl_decode(const char *path, bool apply_wb, RlImage *out, char *err, size_t err_len);
void rl_image_free(float *data, size_t len);
int32_t rl_metadata(const char *path, RlMetadata *out, char *err, size_t err_len);
