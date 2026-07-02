// SPDX-License-Identifier: Apache-2.0
//
// Render a text payload (e.g. a Matter "MT:..." setup code) as a Unicode
// half-block QR code straight into the console log — so commissioning needs
// no "open this URL to see the QR" round-trip.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Encodes `text` and prints a scannable QR to stdout. No-op on NULL/empty
// input, or if the payload is too long for the (small) version cap.
void aqualink_qr_print(const char *text);

#ifdef __cplusplus
}
#endif
