#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "WGCCore.h"

int main(int argc, char **argv) {
    if (argc != 2 || WGCNEABIVersion() != 1) return 1;
    FILE *input = fopen(argv[1], "rb");
    if (!input) return 2;
    char configuration[131073];
    size_t length = fread(configuration, 1, sizeof(configuration), input);
    fclose(input);
    if (!length || length > 131072) return 3;
    char *reply = WGCNEValidate(configuration, (int32_t)length);
    int valid = reply && strstr(reply, "\"ok\":true") && !strstr(reply, "private_key");
    WGCNEFree(reply);
    if (!valid) return 4;
    reply = WGCNEStart(-1, configuration, (int32_t)length);
    valid = reply && strstr(reply, "\"ok\":false");
    WGCNEFree(reply);
    if (!valid) return 5;
    int descriptors[2];
    if (pipe(descriptors)) return 6;
    int owned = dup(descriptors[0]);
    if (owned < 0) return 7;
    reply = WGCNEStart(owned, "{}", 2);
    WGCNEFree(reply);
    errno = 0;
    int closed = fcntl(owned, F_GETFD) == -1 && errno == EBADF;
    close(descriptors[0]); close(descriptors[1]);
    if (!closed) { close(owned); return 8; }
    WGCNEStop(0);
    puts("ABI validation and descriptor ownership passed");
    return 0;
}
