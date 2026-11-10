#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct QEQTestReceiver QEQTestReceiver;
QEQTestReceiver *qeq_test_receiver_create(void);
QEQTestReceiver *qeq_test_receiver_create_display(uint16_t width, uint16_t height);
void qeq_test_receiver_destroy(QEQTestReceiver *receiver);
void qeq_test_receiver_feed(QEQTestReceiver *receiver, const uint8_t *bytes, size_t size);
size_t qeq_test_receiver_read(QEQTestReceiver *receiver, uint8_t *bytes, size_t capacity);
uint32_t qeq_test_receiver_pixels_crc(QEQTestReceiver *receiver);
uint32_t qeq_test_receiver_acknowledged(QEQTestReceiver *receiver);
void qeq_test_receiver_expire(QEQTestReceiver *receiver);
#ifdef __cplusplus
}
#endif
