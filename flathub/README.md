# Flathub submission

This directory stages everything needed to publish LinTO on Flathub. Nothing
here is submitted automatically.

## Prerequisites (already satisfied in the repo)

- Stable application ID: `ai.linto.gnomelinto`, consistent across the desktop
  file, metainfo, GSettings schema, and resource prefix.
- AppStream metainfo at `data/ai.linto.gnomelinto.metainfo.xml.in` with a
  summary, description, developer, license, OARS content rating, an absolute
  https screenshot URL, and a dated release. It validates with
  `appstreamcli validate`.
- Desktop entry and a scalable app icon installed under the app ID.
- A Flatpak manifest whose modules build offline from pinned, hashed sources
  (libsrt and the GStreamer SRT plugin) plus the app itself.

## Release steps

1. Tag a release in this repository, for example:

   ```
   git tag v0.1.0
   git push origin v0.1.0
   ```

2. Get the tag's commit SHA:

   ```
   git rev-parse v0.1.0
   ```

3. Edit `flathub/ai.linto.gnomelinto.yaml` and set the `gnome-linto` module's
   `commit:` to that SHA (the `tag:` is already `v0.1.0`).

4. Verify the submission manifest builds from git, offline, in a clean checkout:

   ```
   flatpak-builder --user --install --force-clean --sandbox \
     build-dir flathub/ai.linto.gnomelinto.yaml
   flatpak run ai.linto.gnomelinto
   ```

5. Lint the manifest and metadata before opening the PR:

   ```
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
     manifest flathub/ai.linto.gnomelinto.yaml
   flatpak run --command=flatpak-builder-lint org.flatpak.Builder \
     appstream data/ai.linto.gnomelinto.metainfo.xml.in
   ```

## Submitting (do this manually when ready)

1. Fork https://github.com/flathub/flathub and create a branch named
   `ai.linto.gnomelinto`.
2. Add `ai.linto.gnomelinto.yaml` at the repository root (the contents of
   `flathub/ai.linto.gnomelinto.yaml` with the commit filled in).
3. Open a pull request against `flathub/flathub`. The Flathub bot builds it and
   a reviewer follows up.

## Notes

- The screenshot is referenced by raw URL
  (`data/screenshots/main.png` on the `main` branch). Keep that path valid, or
  update the URL in the metainfo if the branch or path changes.
- The runtime is `org.gnome.Platform` 49. Bump `runtime-version` here and in the
  development manifest together when moving to a newer GNOME runtime.
