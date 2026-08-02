#include "SystemDNSBridge.h"

#include <resolv.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Minimal layout from Apple's dnsinfo.h. The API is not part of the iOS SDK,
// so resolve its symbols dynamically instead of linking private symbols.
#pragma pack(push, 4)
typedef union {
    char *value;
    uint64_t alignment;
} miclash_dns_char_ptr;

typedef union {
    struct sockaddr **value;
    uint64_t alignment;
} miclash_dns_sockaddr_array;

typedef struct {
    miclash_dns_char_ptr domain;
    int32_t n_nameserver;
    miclash_dns_sockaddr_array nameserver;
    uint16_t port;
    int32_t n_search;
    miclash_dns_char_ptr search;
    int32_t n_sortaddr;
    miclash_dns_char_ptr sortaddr;
    miclash_dns_char_ptr options;
    uint32_t timeout;
    uint32_t search_order;
    uint32_t if_index;
} miclash_dns_resolver;

typedef union {
    miclash_dns_resolver **value;
    uint64_t alignment;
} miclash_dns_resolver_array;

typedef struct {
    int32_t n_resolver;
    miclash_dns_resolver_array resolver;
    int32_t n_scoped_resolver;
    miclash_dns_resolver_array scoped_resolver;
} miclash_dns_config;
#pragma pack(pop)

_Static_assert(offsetof(miclash_dns_resolver, if_index) == 64,
               "unexpected dns_resolver prefix layout");
_Static_assert(offsetof(miclash_dns_config, scoped_resolver) == 16,
               "unexpected dns_config prefix layout");

typedef miclash_dns_config *(*miclash_dns_configuration_copy_fn)(void);
typedef void (*miclash_dns_configuration_free_fn)(miclash_dns_config *);

static int miclash_write_sockaddr(const struct sockaddr *address,
                                  unsigned int fallbackScope,
                                  char *slot, int stride) {
    if (address == NULL || slot == NULL || stride <= 0) return 0;

    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
        return inet_ntop(AF_INET, &v4->sin_addr, slot, (socklen_t)stride) != NULL;
    }
    if (address->sa_family != AF_INET6) return 0;

    const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
    char literal[INET6_ADDRSTRLEN];
    if (inet_ntop(AF_INET6, &v6->sin6_addr, literal, sizeof(literal)) == NULL) return 0;

    unsigned int scope = v6->sin6_scope_id != 0 ? v6->sin6_scope_id : fallbackScope;
    if (IN6_IS_ADDR_LINKLOCAL(&v6->sin6_addr) && scope != 0) {
        char interfaceName[IF_NAMESIZE];
        if (if_indextoname(scope, interfaceName) != NULL) {
            return snprintf(slot, (size_t)stride, "%s%%%s", literal, interfaceName) < stride;
        }
        return snprintf(slot, (size_t)stride, "%s%%%u", literal, scope) < stride;
    }
    return snprintf(slot, (size_t)stride, "%s", literal) < stride;
}

static int miclash_contains_address(const char *out, int stride, int count,
                                    const char *candidate) {
    for (int i = 0; i < count; i++) {
        if (strncmp(out + i * stride, candidate, (size_t)stride) == 0) return 1;
    }
    return 0;
}

static int miclash_copy_resolver_servers(miclash_dns_resolver **resolvers,
                                         int resolverCount,
                                         unsigned int interfaceIndex,
                                         char *out, int stride, int maxCount,
                                         int written) {
    if (resolvers == NULL || resolverCount <= 0 || resolverCount > 64) return written;

    for (int i = 0; i < resolverCount && written < maxCount; i++) {
        miclash_dns_resolver *resolver = NULL;
        memcpy(&resolver, (const char *)resolvers + i * sizeof(resolver), sizeof(resolver));
        if (resolver == NULL || resolver->if_index != interfaceIndex ||
            resolver->n_nameserver <= 0 || resolver->n_nameserver > 32 ||
            resolver->nameserver.value == NULL) {
            continue;
        }

        for (int j = 0; j < resolver->n_nameserver && written < maxCount; j++) {
            struct sockaddr *address = NULL;
            memcpy(&address,
                   (const char *)resolver->nameserver.value + j * sizeof(address),
                   sizeof(address));
            char candidate[128] = {0};
            if (!miclash_write_sockaddr(address, interfaceIndex,
                                        candidate, (int)sizeof(candidate)) ||
                miclash_contains_address(out, stride, written, candidate)) {
                continue;
            }
            if (snprintf(out + written * stride, (size_t)stride, "%s", candidate) < stride) {
                written++;
            }
        }
    }
    return written;
}

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

int miclash_copy_scoped_dns(const char *interfaceName,
                            char *out, int stride, int maxCount) {
    if (interfaceName == NULL || interfaceName[0] == '\0' || out == NULL ||
        stride <= 0 || maxCount <= 0) return 0;

    unsigned int interfaceIndex = if_nametoindex(interfaceName);
    if (interfaceIndex == 0) return 0;

    miclash_dns_configuration_copy_fn copyConfiguration =
        (miclash_dns_configuration_copy_fn)dlsym(RTLD_DEFAULT, "dns_configuration_copy");
    miclash_dns_configuration_free_fn freeConfiguration =
        (miclash_dns_configuration_free_fn)dlsym(RTLD_DEFAULT, "dns_configuration_free");
    if (copyConfiguration == NULL || freeConfiguration == NULL) return 0;

    miclash_dns_config *configuration = copyConfiguration();
    if (configuration == NULL) return 0;

    int written = miclash_copy_resolver_servers(
        configuration->scoped_resolver.value, configuration->n_scoped_resolver,
        interfaceIndex, out, stride, maxCount, 0);
    if (written == 0) {
        written = miclash_copy_resolver_servers(
            configuration->resolver.value, configuration->n_resolver,
            interfaceIndex, out, stride, maxCount, 0);
    }
    freeConfiguration(configuration);
    return written;
}

static int miclash_is_usable_interface_address(const struct sockaddr *address) {
    if (address == NULL) return 0;
    if (address->sa_family == AF_INET) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)address;
        uint32_t value = ntohl(v4->sin_addr.s_addr);
        return value != INADDR_ANY && !IN_MULTICAST(value) &&
               (value >> 24) != IN_LOOPBACKNET;
    }
    if (address->sa_family == AF_INET6) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)address;
        return !IN6_IS_ADDR_UNSPECIFIED(&v6->sin6_addr) &&
               !IN6_IS_ADDR_MULTICAST(&v6->sin6_addr) &&
               !IN6_IS_ADDR_LOOPBACK(&v6->sin6_addr) &&
               !IN6_IS_ADDR_LINKLOCAL(&v6->sin6_addr);
    }
    return 0;
}

int miclash_copy_interface_addresses(const char *interfaceName,
                                     char *out, int stride, int maxCount) {
    if (interfaceName == NULL || interfaceName[0] == '\0' || out == NULL ||
        stride <= 0 || maxCount <= 0) return 0;

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || interfaces == NULL) return 0;

    unsigned int interfaceIndex = if_nametoindex(interfaceName);
    int written = 0;
    for (struct ifaddrs *entry = interfaces;
         entry != NULL && written < maxCount; entry = entry->ifa_next) {
        if (entry->ifa_name == NULL ||
            strcmp(entry->ifa_name, interfaceName) != 0 ||
            !miclash_is_usable_interface_address(entry->ifa_addr)) {
            continue;
        }

        char candidate[128] = {0};
        if (!miclash_write_sockaddr(entry->ifa_addr, interfaceIndex,
                                    candidate, (int)sizeof(candidate)) ||
            miclash_contains_address(out, stride, written, candidate)) {
            continue;
        }
        if (snprintf(out + written * stride, (size_t)stride, "%s", candidate) < stride) {
            written++;
        }
    }
    freeifaddrs(interfaces);
    return written;
}
