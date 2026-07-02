// SPDX-License-Identifier: Apache-2.0
//
// Prints a QR code directly into the console using Unicode half-block glyphs,
// so the Matter setup code appears in the boot log as a scannable image rather
// than a "paste this URL to view the QR" link.
//
// The encoder is Nayuki's qrcodegen (MIT, third-party — qrcodegen.c/.h).
// The rendering loop is adapted from that library's own qrprint.c demo.

#include "qr_console.h"
#include "qrcodegen.h"

#include <stdio.h>

// The Matter setup payload is a short alphanumeric string, so a small version
// cap is plenty and keeps both scratch buffers tiny (~212 B each). That matters
// because app_main() runs on a modestly-sized stack.
#define QR_MAX_VERSION 6

void aqualink_qr_print(const char *text)
{
    if (text == NULL || text[0] == '\0') {
        return;
    }

    uint8_t qr[qrcodegen_BUFFER_LEN_FOR_VERSION(QR_MAX_VERSION)];
    uint8_t tmp[qrcodegen_BUFFER_LEN_FOR_VERSION(QR_MAX_VERSION)];

    if (!qrcodegen_encodeText(text, tmp, qr, qrcodegen_Ecc_MEDIUM,
                              qrcodegen_VERSION_MIN, QR_MAX_VERSION,
                              qrcodegen_Mask_AUTO, true)) {
        printf("[qr] payload too long to render: %s\n", text);
        return;
    }

    const int size   = qrcodegen_getSize(qr);
    const int border = 2;  // quiet zone (spec minimum is 4, 2 scans fine on-screen)

    printf("\n\033[1m  Scan to commission AquaLink (Matter):\033[0m\n\n");

    // Two module-rows are packed into each text line via upper/lower half
    // blocks; one char per module then keeps the aspect roughly square
    // (a terminal cell is ~2× taller than wide).
    //
    // NOTE: dark modules are drawn as filled blocks (matches the upstream
    // qrprint.c). On a dark-background monitor that renders inverted; if a
    // scanner struggles, swap `top`/`bot` for `!top`/`!bot` below to invert.
    for (int b = 0; b < border; b++) {
        for (int x = -border; x < size + border; x++) printf(" ");
        printf("\n");
    }
    for (int y = 0; y < size; y += 2) {
        for (int b = 0; b < border; b++) printf(" ");
        for (int x = 0; x < size; x++) {
            bool top = qrcodegen_getModule(qr, x, y);
            bool bot = (y + 1 < size) ? qrcodegen_getModule(qr, x, y + 1) : false;
            const char *c = (top && bot) ? "\xE2\x96\x88"   // █ full
                          : top          ? "\xE2\x96\x80"   // ▀ upper half
                          : bot          ? "\xE2\x96\x84"   // ▄ lower half
                                         : " ";
            printf("%s", c);
        }
        printf("\n");
    }
    for (int b = 0; b < border; b++) {
        for (int x = -border; x < size + border; x++) printf(" ");
        printf("\n");
    }

    printf("\n  Payload: %s\n\n", text);
}
