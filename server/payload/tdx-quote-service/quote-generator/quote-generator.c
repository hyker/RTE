#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <tdx_attest.h>

static int hex_to_bytes(const char *hex, uint8_t *out, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        if (sscanf(hex + i * 2, "%2hhx", &out[i]) != 1)
            return -1;
    }
    return 0;
}

int main(int argc, char *argv[])
{
    tdx_report_data_t report_data = {{0}};
    uint8_t *quote = NULL;
    uint32_t quote_size = 0;

    if (argc > 1) {
        if (strlen(argv[1]) != 128 || hex_to_bytes(argv[1], report_data.d, 64) != 0) {
            fprintf(stderr, "Usage: %s [64-byte-hex]\n", argv[0]);
            return 1;
        }
    }

    tdx_attest_error_t result = tdx_att_get_quote(&report_data, NULL, 0, NULL, &quote, &quote_size, 0);
    if (result != TDX_ATTEST_SUCCESS) {
        fprintf(stderr, "Failed to get the quote.\n");
        return 1;
    }

    printf("TDX quote data: [");
    for (uint32_t i = 0; i < quote_size; i++) {
        printf("%u", quote[i]);
        if (i < quote_size - 1)
            printf(", ");
    }
    printf("]\n");

    tdx_att_free_quote(quote);
    return 0;
}
