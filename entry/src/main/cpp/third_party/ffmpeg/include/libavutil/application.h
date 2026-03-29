/* stub application.h — IJK custom FFmpeg extension, types only */
#ifndef AVUTIL_APPLICATION_H
#define AVUTIL_APPLICATION_H
#include <stdint.h>
#include "avutil.h"

/* Minimal AVApplicationContext for compilation only */
typedef struct AVAppIOStatistic {
    int64_t bit_rate;
} AVAppIOStatistic;

typedef struct AVApplicationContext {
    const struct AVApplicationContext_class *av_class;
    void *opaque;
    int64_t statistic_update_gap;
    void (*func_on_app_event)(struct AVApplicationContext *h, int event_type, void *obj, int64_t size);
} AVApplicationContext;

#define AVAPP_EVENT_ASYNC_STATISTIC     0x0001
#define AVAPP_EVENT_IO_TRAFFIC          0x00001
#define AVAPP_CTX_CLASS 0
typedef struct AVApplicationContext_class { int dummy; } AVApplicationContext_class;

static inline int av_application_open(AVApplicationContext **ph, void *opaque) { return 0; }
static inline void av_application_closep(AVApplicationContext **ph) {}
static inline void av_application_on_io_traffic(AVApplicationContext *h, void *obj) {}

#endif /* AVUTIL_APPLICATION_H */
