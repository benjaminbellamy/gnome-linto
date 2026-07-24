test_c_args = [
  '-DGETTEXT_PACKAGE="@0@"'.format(meson.project_name()),
]

stream_url_test = executable('stream-url-test',
  ['stream-url-test.vala', stream_url_vala],
  dependencies: [gio_dep],
  c_args: test_c_args,
)
test('stream-url', stream_url_test)

level_meter_test = executable('level-meter-test',
  ['level-meter-test.vala', level_meter_vala],
  dependencies: [gio_dep, gst_dep, m_dep],
  c_args: test_c_args,
)
test('level-meter', level_meter_test)

qr_code_test = executable('qr-code-test',
  ['qr-code-test.vala', qr_code_vala],
  dependencies: [gio_dep],
  c_args: test_c_args,
)
test('qr-code', qr_code_test)

csv_parser_test = executable('csv-parser-test',
  ['csv-parser-test.vala', csv_parser_vala, stream_url_vala],
  dependencies: [gio_dep],
  c_args: test_c_args,
)
test('csv-parser', csv_parser_test)

vad_test = executable('vad-test',
  ['vad-test.vala', vad_vala],
  dependencies: [gio_dep, m_dep],
  c_args: test_c_args,
)
test('vad', vad_test)
