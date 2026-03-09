#include <stdio.h>
int main() {
    int x;
    printf("%d\n", x);  // uninitialized variable - cppcheck should catch this
    return 0;
}
