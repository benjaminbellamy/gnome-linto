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

namespace Linto {
    // A self-contained QR Code generator (ISO/IEC 18004), byte mode, error
    // correction level M, versions 1 to 12. That comfortably covers a public
    // transcription URL (over 200 bytes at the top version). The result is a
    // square boolean grid of modules; the caller renders it. No dependency.
    public class QrCode : Object {
        // Modules per side (a QR is a square). 0 until rendered.
        public int size { get; private set; default = 0; }

        private const int MAX_VERSION = 12;

        // Error correction characteristics for level M, versions 1 to 12, from
        // the QR standard. Each row is
        // {ecc codewords per block, group 1 block count, group 1 data codewords,
        //  group 2 block count, group 2 data codewords}.
        private const int[,] ECC_M = {
            { 10, 1, 16, 0,  0 },
            { 16, 1, 28, 0,  0 },
            { 26, 1, 44, 0,  0 },
            { 18, 2, 32, 0,  0 },
            { 24, 2, 43, 0,  0 },
            { 16, 4, 27, 0,  0 },
            { 18, 4, 31, 0,  0 },
            { 22, 2, 38, 2, 39 },
            { 22, 3, 36, 2, 37 },
            { 26, 4, 43, 1, 44 },
            { 30, 1, 50, 4, 51 },
            { 22, 6, 36, 2, 37 }
        };

        private bool[,] mod;       // dark module = true
        private bool[,] reserved;  // function pattern, not carrying data/mask

        public bool get_module (int x, int y) {
            return this.mod[x, y];
        }

        // Builds a QR code for the given text, or null when it does not fit in
        // the supported versions (the caller reports that to the user).
        public static QrCode? encode (string text) {
            uint8[] data = text.data;
            int len = data.length;

            int version = 0;
            for (int v = 1; v <= MAX_VERSION; v++) {
                int count_bits = (v <= 9) ? 8 : 16;
                if (4 + count_bits + 8 * len <= total_data_codewords (v) * 8) {
                    version = v;
                    break;
                }
            }
            if (version == 0) {
                // Too long for the supported versions; the caller reports it.
                return null;
            }

            var qr = new QrCode ();
            qr.render (version, make_codewords (version, data));
            return qr;
        }

        private static int total_data_codewords (int version) {
            int r = version - 1;
            return ECC_M[r, 1] * ECC_M[r, 2] + ECC_M[r, 3] * ECC_M[r, 4];
        }

        // ---- Data encoding and error correction -----------------------------

        // Writes the low len bits of val (most significant first) into the
        // codeword array at the running bit position (the array is pre-zeroed,
        // so this only needs to set the one bits).
        private static void put_bits (uint8[] cw, ref int bitpos, uint val,
            int len) {
            for (int i = len - 1; i >= 0; i--) {
                if (((val >> i) & 1) != 0) {
                    cw[bitpos >> 3] |= (uint8) (1 << (7 - (bitpos & 7)));
                }
                bitpos++;
            }
        }

        // Encodes the text in byte mode, pads to capacity, splits into blocks,
        // computes Reed-Solomon error correction, and interleaves the result.
        private static uint8[] make_codewords (int version, uint8[] data) {
            int r = version - 1;
            int count_bits = (version <= 9) ? 8 : 16;
            int total_data = total_data_codewords (version);
            int capacity_bits = total_data * 8;

            var data_cw = new uint8[total_data];
            int bitpos = 0;
            put_bits (data_cw, ref bitpos, 0x4, 4);   // byte mode indicator
            put_bits (data_cw, ref bitpos, data.length, count_bits);
            foreach (uint8 b in data) {
                put_bits (data_cw, ref bitpos, b, 8);
            }
            // Terminator, then the rest of the current byte stays zero.
            put_bits (data_cw, ref bitpos, 0,
                int.min (4, capacity_bits - bitpos));
            // Pad bytes alternate between 0xEC and 0x11.
            uint8 pad = 0xEC;
            for (int i = (bitpos + 7) / 8; i < total_data; i++) {
                data_cw[i] = pad;
                pad = (pad == 0xEC) ? 0x11 : 0xEC;
            }

            int ec_len = ECC_M[r, 0];
            int g1_blocks = ECC_M[r, 1];
            int g1_data = ECC_M[r, 2];
            int g2_blocks = ECC_M[r, 3];
            int g2_data = ECC_M[r, 4];
            int num_blocks = g1_blocks + g2_blocks;
            int[] divisor = rs_divisor (ec_len);

            // Vala has no jagged arrays, so blocks are kept as offsets/lengths
            // into the contiguous data codewords, and all error correction
            // codewords in one flat array (block b at b * ec_len).
            var block_off = new int[num_blocks];
            var block_len = new int[num_blocks];
            var ecc_all = new uint8[num_blocks * ec_len];
            int off = 0;
            for (int b = 0; b < num_blocks; b++) {
                int dlen = (b < g1_blocks) ? g1_data : g2_data;
                block_off[b] = off;
                block_len[b] = dlen;
                uint8[] ecc = rs_remainder (data_cw[off : off + dlen], divisor);
                for (int i = 0; i < ec_len; i++) {
                    ecc_all[b * ec_len + i] = ecc[i];
                }
                off += dlen;
            }

            uint8[] result = {};
            int max_data = (g2_blocks > 0) ? g2_data : g1_data;
            for (int i = 0; i < max_data; i++) {
                for (int b = 0; b < num_blocks; b++) {
                    if (i < block_len[b]) {
                        result += data_cw[block_off[b] + i];
                    }
                }
            }
            for (int i = 0; i < ec_len; i++) {
                for (int b = 0; b < num_blocks; b++) {
                    result += ecc_all[b * ec_len + i];
                }
            }
            return result;
        }

        // Multiplies two numbers in GF(2^8) with the QR primitive polynomial.
        private static int rs_multiply (int x, int y) {
            int z = 0;
            for (int i = 7; i >= 0; i--) {
                z = (z << 1) ^ (((z >> 7) & 1) * 0x11D);
                z ^= ((y >> i) & 1) * x;
            }
            return z & 0xFF;
        }

        // The generator polynomial (monic, implicit leading term) for the given
        // number of error correction codewords.
        private static int[] rs_divisor (int degree) {
            var result = new int[degree];
            result[degree - 1] = 1;
            int root = 1;
            for (int i = 0; i < degree; i++) {
                for (int j = 0; j < degree; j++) {
                    result[j] = rs_multiply (result[j], root);
                    if (j + 1 < degree) {
                        result[j] ^= result[j + 1];
                    }
                }
                root = rs_multiply (root, 2);
            }
            return result;
        }

        // The error correction codewords: the remainder of the data divided by
        // the generator polynomial.
        private static uint8[] rs_remainder (uint8[] data, int[] divisor) {
            int ec_len = divisor.length;
            var res = new int[ec_len];
            foreach (uint8 b in data) {
                int factor = (b ^ res[0]) & 0xFF;
                for (int i = 0; i < ec_len - 1; i++) {
                    res[i] = res[i + 1];
                }
                res[ec_len - 1] = 0;
                for (int i = 0; i < ec_len; i++) {
                    res[i] ^= rs_multiply (divisor[i], factor);
                }
            }
            var result = new uint8[ec_len];
            for (int i = 0; i < ec_len; i++) {
                result[i] = (uint8) res[i];
            }
            return result;
        }

        // ---- Matrix construction --------------------------------------------

        private void render (int version, uint8[] codewords) {
            this.size = version * 4 + 17;
            this.mod = new bool[this.size, this.size];
            this.reserved = new bool[this.size, this.size];

            this.draw_function_patterns (version);
            this.draw_codewords (codewords);
            this.apply_best_mask (version);
        }

        private void set_fn (int x, int y, bool dark) {
            this.mod[x, y] = dark;
            this.reserved[x, y] = true;
        }

        private static bool get_bit (int value, int i) {
            return ((value >> i) & 1) != 0;
        }

        private void draw_function_patterns (int version) {
            int n = this.size;
            for (int i = 0; i < n; i++) {
                this.set_fn (6, i, i % 2 == 0);
                this.set_fn (i, 6, i % 2 == 0);
            }
            this.draw_finder (3, 3);
            this.draw_finder (n - 4, 3);
            this.draw_finder (3, n - 4);

            int[] pos = alignment_centers (version);
            int na = pos.length;
            for (int i = 0; i < na; i++) {
                for (int j = 0; j < na; j++) {
                    if ((i == 0 && j == 0)
                        || (i == 0 && j == na - 1)
                        || (i == na - 1 && j == 0)) {
                        continue;   // the finder corners
                    }
                    this.draw_alignment (pos[i], pos[j]);
                }
            }
            // Reserve the format and version areas (real bits placed later).
            this.draw_format (0);
            this.draw_version (version);
        }

        private void draw_finder (int cx, int cy) {
            for (int dy = -4; dy <= 4; dy++) {
                for (int dx = -4; dx <= 4; dx++) {
                    int x = cx + dx;
                    int y = cy + dy;
                    if (x < 0 || x >= this.size || y < 0 || y >= this.size) {
                        continue;
                    }
                    int dist = int.max (dx.abs (), dy.abs ());
                    this.set_fn (x, y, dist != 2 && dist != 4);
                }
            }
        }

        private void draw_alignment (int cx, int cy) {
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    this.set_fn (cx + dx, cy + dy,
                        int.max (dx.abs (), dy.abs ()) != 1);
                }
            }
        }

        private void draw_format (int mask) {
            int data = mask;   // level M indicator bits are 0
            int rem = data;
            for (int i = 0; i < 10; i++) {
                rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537);
            }
            int bits = ((data << 10) | rem) ^ 0x5412;

            int n = this.size;
            for (int i = 0; i <= 5; i++) {
                this.set_fn (8, i, get_bit (bits, i));
            }
            this.set_fn (8, 7, get_bit (bits, 6));
            this.set_fn (8, 8, get_bit (bits, 7));
            this.set_fn (7, 8, get_bit (bits, 8));
            for (int i = 9; i < 15; i++) {
                this.set_fn (14 - i, 8, get_bit (bits, i));
            }
            for (int i = 0; i < 8; i++) {
                this.set_fn (n - 1 - i, 8, get_bit (bits, i));
            }
            for (int i = 8; i < 15; i++) {
                this.set_fn (8, n - 15 + i, get_bit (bits, i));
            }
            this.set_fn (8, n - 8, true);   // the always-dark module
        }

        private void draw_version (int version) {
            if (version < 7) {
                return;
            }
            int rem = version;
            for (int i = 0; i < 12; i++) {
                rem = (rem << 1) ^ (((rem >> 11) & 1) * 0x1F25);
            }
            int bits = (version << 12) | rem;
            int n = this.size;
            for (int i = 0; i < 18; i++) {
                bool bit = get_bit (bits, i);
                int a = n - 11 + i % 3;
                int b = i / 3;
                this.set_fn (a, b, bit);
                this.set_fn (b, a, bit);
            }
        }

        // Lays the interleaved codewords into the matrix in the standard upward
        // and downward zigzag, skipping function modules.
        private void draw_codewords (uint8[] data) {
            int n = this.size;
            int i = 0;
            for (int right = n - 1; right >= 1; right -= 2) {
                if (right == 6) {
                    right = 5;   // skip the vertical timing column
                }
                for (int vert = 0; vert < n; vert++) {
                    for (int j = 0; j < 2; j++) {
                        int x = right - j;
                        bool upward = ((right + 1) & 2) == 0;
                        int y = upward ? (n - 1 - vert) : vert;
                        if (!this.reserved[x, y] && i < data.length * 8) {
                            this.mod[x, y] = get_bit (data[i >> 3], 7 - (i & 7));
                            i++;
                        }
                    }
                }
            }
        }

        private void apply_best_mask (int version) {
            int best = 0;
            int best_penalty = int.MAX;
            for (int m = 0; m < 8; m++) {
                this.apply_mask (m);
                this.draw_format (m);
                int p = this.penalty ();
                if (p < best_penalty) {
                    best_penalty = p;
                    best = m;
                }
                this.apply_mask (m);   // undo (mask is its own inverse)
            }
            this.apply_mask (best);
            this.draw_format (best);
        }

        private void apply_mask (int mask) {
            for (int y = 0; y < this.size; y++) {
                for (int x = 0; x < this.size; x++) {
                    if (this.reserved[x, y]) {
                        continue;
                    }
                    bool invert = false;
                    switch (mask) {
                        case 0: invert = (x + y) % 2 == 0; break;
                        case 1: invert = y % 2 == 0; break;
                        case 2: invert = x % 3 == 0; break;
                        case 3: invert = (x + y) % 3 == 0; break;
                        case 4: invert = (x / 3 + y / 2) % 2 == 0; break;
                        case 5: invert = x * y % 2 + x * y % 3 == 0; break;
                        case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0; break;
                        case 7: invert = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
                    }
                    if (invert) {
                        this.mod[x, y] = !this.mod[x, y];
                    }
                }
            }
        }

        // ---- Mask penalty scoring (the four standard rules) ------------------

        private int penalty () {
            int n = this.size;
            int result = 0;

            // Rules 1 and 3, along rows then columns.
            for (int y = 0; y < n; y++) {
                bool run_color = false;
                int run_len = 0;
                int[] history = new int[7];
                for (int x = 0; x < n; x++) {
                    if (this.mod[x, y] == run_color) {
                        run_len++;
                        if (run_len == 5) {
                            result += 3;
                        } else if (run_len > 5) {
                            result += 1;
                        }
                    } else {
                        this.finder_add_history (run_len, history);
                        if (!run_color) {
                            result += this.finder_count (history) * 40;
                        }
                        run_color = this.mod[x, y];
                        run_len = 1;
                    }
                }
                result += this.finder_terminate (run_color, run_len, history)
                    * 40;
            }
            for (int x = 0; x < n; x++) {
                bool run_color = false;
                int run_len = 0;
                int[] history = new int[7];
                for (int y = 0; y < n; y++) {
                    if (this.mod[x, y] == run_color) {
                        run_len++;
                        if (run_len == 5) {
                            result += 3;
                        } else if (run_len > 5) {
                            result += 1;
                        }
                    } else {
                        this.finder_add_history (run_len, history);
                        if (!run_color) {
                            result += this.finder_count (history) * 40;
                        }
                        run_color = this.mod[x, y];
                        run_len = 1;
                    }
                }
                result += this.finder_terminate (run_color, run_len, history)
                    * 40;
            }

            // Rule 2: 2x2 blocks of one color.
            for (int y = 0; y < n - 1; y++) {
                for (int x = 0; x < n - 1; x++) {
                    bool c = this.mod[x, y];
                    if (c == this.mod[x + 1, y]
                        && c == this.mod[x, y + 1]
                        && c == this.mod[x + 1, y + 1]) {
                        result += 3;
                    }
                }
            }

            // Rule 4: deviation of the dark proportion from one half.
            int dark = 0;
            for (int y = 0; y < n; y++) {
                for (int x = 0; x < n; x++) {
                    if (this.mod[x, y]) {
                        dark++;
                    }
                }
            }
            int total = n * n;
            int diff = dark * 20 - total * 10;
            if (diff < 0) {
                diff = -diff;
            }
            int k = (diff + total - 1) / total - 1;
            result += k * 10;

            return result;
        }

        private void finder_add_history (int run_len, int[] history) {
            if (history[0] == 0) {
                run_len += this.size;   // the light border before the run
            }
            for (int i = history.length - 1; i > 0; i--) {
                history[i] = history[i - 1];
            }
            history[0] = run_len;
        }

        // Counts finder-like 1:1:3:1:1 patterns bordered by four light modules.
        private int finder_count (int[] h) {
            int c = h[1];
            bool core = c > 0 && h[2] == c && h[3] == c * 3 && h[4] == c
                && h[5] == c;
            return (core && h[0] >= c * 4 && h[6] >= c ? 1 : 0)
                + (core && h[6] >= c * 4 && h[0] >= c ? 1 : 0);
        }

        private int finder_terminate (bool run_color, int run_len,
            int[] history) {
            if (run_color) {
                this.finder_add_history (run_len, history);
                run_len = 0;
            }
            run_len += this.size;   // the light border after the run
            this.finder_add_history (run_len, history);
            return this.finder_count (history);
        }

        // Alignment pattern centers for level M, versions 1 to 12 (QR standard).
        private static int[] alignment_centers (int version) {
            switch (version) {
                case 2: return { 6, 18 };
                case 3: return { 6, 22 };
                case 4: return { 6, 26 };
                case 5: return { 6, 30 };
                case 6: return { 6, 34 };
                case 7: return { 6, 22, 38 };
                case 8: return { 6, 24, 42 };
                case 9: return { 6, 26, 46 };
                case 10: return { 6, 28, 50 };
                case 11: return { 6, 30, 54 };
                case 12: return { 6, 32, 58 };
                default: return {};
            }
        }
    }
}
