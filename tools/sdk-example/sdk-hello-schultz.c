/* sdk-hello-schultz -- proves an app built with the eSDK actually runs on
 * the target: correct output requires an aarch64 binary executed on the
 * real device, not just "it compiled". See ../README.md. */
#include <stdio.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <time.h>

int main(void) {
    struct utsname u;
    char host[256] = "unknown";
    time_t now = time(NULL);

    uname(&u);
    gethostname(host, sizeof(host));

    printf("sdk-hello-schultz\n");
    printf("  built for : %s\n", u.machine);
    printf("  running on: %s (%s %s)\n", host, u.sysname, u.release);
    printf("  pid       : %d\n", (int)getpid());
    printf("  time      : %s", ctime(&now));
    return 0;
}
