#include "SystemDNSBridge.h"

#include <resolv.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>

int miclash_copy_system_dns(char *out, int stride, int maxCount) {
    if (out == NULL || stride <= 0 || maxCount <= 0) return 0;

    struct __res_state res;
    memset(&res, 0, sizeof(res));
    if (res_ninit(&res) != 0) return 0;

    // iOS resolv.h 里 res_sockaddr_union 是宏（→ res_9_sockaddr_union），
    // 真实类型是 union，声明必须带 union 标签。
    union res_sockaddr_union servers[8];
    memset(servers, 0, sizeof(servers));
    int count = res_getservers(&res, servers, 8);

    int written = 0;
    for (int i = 0; i < count && i < 8 && written < maxCount; i++) {
        char *slot = out + written * stride;
        const char *p = NULL;
        if (servers[i].sin.sin_family == AF_INET) {
            p = inet_ntop(AF_INET, &servers[i].sin.sin_addr, slot, (socklen_t)stride);
        } else if (servers[i].sin.sin_family == AF_INET6) {
            char address[INET6_ADDRSTRLEN];
            p = inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr,
                          address, sizeof(address));
            if (p != NULL && servers[i].sin6.sin6_scope_id != 0) {
                char interfaceName[IF_NAMESIZE];
                if (if_indextoname(servers[i].sin6.sin6_scope_id, interfaceName) != NULL) {
                    if (snprintf(slot, (size_t)stride, "%s%%%s", address, interfaceName) >= stride) {
                        p = NULL;
                    }
                } else if (snprintf(slot, (size_t)stride, "%s%%%u", address,
                                    servers[i].sin6.sin6_scope_id) >= stride) {
                    p = NULL;
                }
            } else if (p != NULL) {
                if (snprintf(slot, (size_t)stride, "%s", address) >= stride) {
                    p = NULL;
                }
            }
        }
        if (p != NULL) written++;
    }

    res_nclose(&res);
    return written;
}
