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

private void test_silence () {
    assert (Linto.LevelMeter.linear_from_db (-100.0) == 0.0);
}

private void test_floor () {
    assert (Linto.LevelMeter.linear_from_db (-90.0) == 0.0);
}

private void test_full_scale () {
    assert (Linto.LevelMeter.linear_from_db (0.0) == 1.0);
}

private void test_clamps_positive () {
    assert (Linto.LevelMeter.linear_from_db (6.0) == 1.0);
}

private void test_minus_six_db () {
    // -6 dBFS is approximately half amplitude (~0.501).
    double v = Linto.LevelMeter.linear_from_db (-6.0);
    assert (v > 0.49 && v < 0.51);
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/level/silence", test_silence);
    Test.add_func ("/level/floor", test_floor);
    Test.add_func ("/level/full-scale", test_full_scale);
    Test.add_func ("/level/clamps-positive", test_clamps_positive);
    Test.add_func ("/level/minus-six-db", test_minus_six_db);
    return Test.run ();
}
