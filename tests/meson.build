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
