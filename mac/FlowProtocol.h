#ifndef FLOW_PROTOCOL_H
#define FLOW_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
/* 1: response, 0: unrelated, -1: old firmware, -2: invalid fields. */
static inline int flow_validate_command(const uint8_t *p, size_t n, const uint8_t nonce[4],unsigned command) {
    if(command!=1&&command!=2)return 0;
    if (n == 33 && p[0] == 0) { p++; n--; }
    if (n != 32 || memcmp(p + 8, nonce, 4) != 0) return 0;
    if (p[0] == 0xff && p[1] == 0x4c && p[2] == 0x46 && p[3] == 0x42 && p[4] == command) return -1;
    if (p[0] != 0x15 || p[1] != 0x4c || p[2] != 0x46 || p[3] != 0x42 || p[4] != (0x80|command)) return 0;
    if ((p[5] & ~7) || ((p[5] & 1) && p[6] > 100)) return -2;
    return 1;
}
static inline int flow_validate(const uint8_t *p,size_t n,const uint8_t nonce[4]){return flow_validate_command(p,n,nonce,1);}
static inline void flow_request(uint8_t p[32], const uint8_t nonce[4]) {
    memset(p, 0, 32);
    p[0] = 0x15; p[1] = 0x4c; p[2] = 0x46; p[3] = 0x42; p[4] = 1;
    memcpy(p + 8, nonce, 4);
}
#endif
