gnome_linto_sources = [
  'config.vapi',
  'netinfo.vapi',
  'netinfo.c',
  'main.vala',
  'application.vala',
  'window.vala',
  'preferences.vala',
  'address-book.vala',
  'address-editor.vala',
  'csv-parser.vala',
  'csv-import.vala',
  'stream-controller.vala',
  'debug-dialog.vala',
  'debug-log.vala',
  'control-server.vala',
  'stream-url.vala',
  'stats-store.vala',
  'bandwidth.vala',
  'level-meter.vala',
  'audio-monitor.vala',
  'streamer.vala',
]

gnome_linto_deps = [
  gtk_dep,
  adw_dep,
  gio_dep,
  gst_dep,
  gst_app_dep,
  soup_dep,
  m_dep,
  config_dep,
]

executable('gnome-linto',
  gnome_linto_sources,
  resources,
  dependencies: gnome_linto_deps,
  vala_args: [
    '--target-glib=2.80',
  ],
  c_args: [
    '-DGETTEXT_PACKAGE="@0@"'.format(meson.project_name()),
  ],
  include_directories: include_directories('.'),
  install: true,
)

# Pure-logic sources exposed for unit testing.
stream_url_vala = files('stream-url.vala')
level_meter_vala = files('level-meter.vala')
