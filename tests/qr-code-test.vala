/* gnome-linto
 *
 * Copyright (C) 2026 Benjamin Bellamy
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

// A golden matrix for "hi" (version 1, level M), verified byte for byte against
// the independent libqrencode encoder. Catches any regression in the data
// encoding, error correction, placement, or mask selection.
const string[] GOLDEN_HI = {
    "111111100111101111111",
    "100000100110101000001",
    "101110101101101011101",
    "101110101100101011101",
    "101110101001101011101",
    "100000101100101000001",
    "111111101010101111111",
    "000000001011100000000",
    "101111100000101111100",
    "011101010010100100001",
    "001100110101010011110",
    "111010000100000110100",
    "111010100001010010101",
    "000000001001111001001",
    "111111100010101100010",
    "100000101111111001001",
    "101110101000100100100",
    "101110101110100100100",
    "101110101001010011100",
    "100000100110000110100",
    "111111101011010011110"
};

void test_golden_hi () {
    var qr = Linto.QrCode.encode ("hi");
    assert (qr != null);
    assert (qr.size == 21);
    for (int y = 0; y < 21; y++) {
        for (int x = 0; x < 21; x++) {
            assert (qr.get_module (x, y) == (GOLDEN_HI[y].get (x) == '1'));
        }
    }
}

void test_versions () {
    // The chosen version grows with the data, matching the QR capacity tables.
    assert (Linto.QrCode.encode ("hi").size == 21);              // version 1
    assert (Linto.QrCode.encode ("https://example.org/").size == 25);  // v2
    var url = "https://studio.linto.ai/transcription/"
        + "8d30ef9d-394e-4725-8e6e-f2eb1123500c";
    assert (Linto.QrCode.encode (url).size == 37);              // version 5
}

void test_too_long () {
    // Beyond the supported capacity (version 12, level M) it returns null.
    assert (Linto.QrCode.encode (string.nfill (400, 'a')) == null);
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/qr-code/golden-hi", test_golden_hi);
    Test.add_func ("/qr-code/versions", test_versions);
    Test.add_func ("/qr-code/too-long", test_too_long);
    return Test.run ();
}
