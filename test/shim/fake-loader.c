/*
 * Test fixture for shim-test.sh: stands in for the glibc loader.  It prints its
 * argv and the LD_PRELOAD its children would inherit, which is exactly what the
 * shim rewrites and strips.
 */

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    const char *preload = getenv("LD_PRELOAD");
    int i;

    for (i = 0; i < argc; i++) printf("argv[%d]=%s\n", i, argv[i]);
    printf("LD_PRELOAD=%s\n", preload && *preload ? preload : "<unset>");
    return 0;
}
