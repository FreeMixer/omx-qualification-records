# omx-qualification-records

The distributed qualification records of a plugin set, as a Debian package.

[plugin-qualify](https://github.com/FreeMixer/plugin-qualify) measures every LV2 and CLAP plugin of a device
before the device hosts it. A Raspberry Pi 5 takes hours to measure a full Zynthian image. A device of the same
machine class and the same plugin set does not need to measure it again: this repository holds the records one
such device wrote, and publishes them as `omx-qualification-<host class>-<set>`, which `plugin-qualify-sync`
reads before it measures anything.

| package | host class | plugin set | records |
| --- | --- | --- | --- |
| `omx-qualification-rpi5-zynthian-vangelis` | `rpi5` (Raspberry Pi 5) | ZynthianOS Vangelis-2610.1 | 1886 |

The package is `Architecture: all`, depends on `plugin-qualify (>= 0.17.0~)`, and installs

```
/usr/share/omx/qualification/rpi5/zynthian-vangelis/
    <plugin>@<version>-<sha256 first 12>.<offer>.qualification.json   # the record
    <same name>.probe.json                                              # the probe output the record judged, byte for byte
    provenance.json                                                     # where the set comes from
```

Each record is held with its probe output. Both are the files the measuring device wrote, unchanged. The 2
plugins of that device that could not be measured (`*.unmeasured.json`) are not here: an unmeasured record never
applies.

## The matching rule

A record is found by the plugin's name (an LV2 uri, a CLAP path). The name only finds it. It applies to a plugin
on the device when, and only when:

- every file of the record's `binary.files` is installed at that path relative to the plugin's root, with that
  SHA-256, computed on the device at the time of the sync;
- the probe output beside the record is intact (its SHA-256 is the one the record names) and one this plugin-qualify
  reads;
- the record holds a verdict for the sync's `host_profile` that ended `qualified`, `refused`, `crashed` or `hung`.

Anything else is measured on the device as before, and the sync says so (`distributed: <uri>: binary differs`).
A package version that ships different bytes, a plugin the user added, or a plugin built for another
architecture therefore never takes a measurement that is not its own.

## Use on a device

```
apt install omx-qualification-rpi5-zynthian-vangelis      # from the OpenMixer channel
plugin-qualify-sync --system
```

```
plugin-qualify-sync: distributed: http://distrho.sf.net/plugins/3BandEQ: applied (zynthian-vangelis)
```

The host class is the board's own, read from the device tree (`rpi5` on a Raspberry Pi 5), or `host_class` in
`/etc/omx/qualify.conf`. A plugin taken from the records is not measured; the sync copies the record into the
device's `qualification_dir` with this set's `provenance` added, and treats it afterwards like one it measured
(skipped while its files are unchanged, measured when they change). `--no-distributed` keeps the layer out of a
run; `--force` measures everything.

The channel is `https://www.openmixer.org/deb/debian/trixie/`; add it with the `openmixer-release` package.

## Rebuild from a device run

On the device (same class, a new image or new plugin versions), run `plugin-qualify-sync --system --force`, or
`plugin-qualify --all --isolate --out <dir>`, then copy its `qualification_dir` here and:

```
tools/build-package.sh --from <qualification dir> --provenance provenance.json \
    --version <YYYY.MM.DD> --host-class rpi5 --set zynthian-vangelis
git diff --stat
```

`plugin-qualify-records-package` (plugin-qualify 0.17.0) judges which records go in, builds the package, and the
script replaces `records/`, `debian/control`, `debian/install` and the top `debian/changelog` entry with what it
holds. `provenance.json` is a JSON file of what the tool cannot know: the image, the board, the package versions
and the source revisions of the device; the tool adds the schema, the set, the host class, the package and the
date. Commit, then tag `v<version>`: the tag must equal the `debian/changelog` version.

`tools/build-package.sh` without arguments builds the package of `records/` with the tool, to compare with what
`debian/` builds.

## Release

A tag `v*` runs `.github/workflows/release.yml`: it builds the package from `debian/`, runs lintian (warnings fail),
installs it in Debian trixie on arm64 with plugin-qualify from the channel and the Debian package of the LV2
plugins of the set, asserts that `plugin-qualify-sync --system` takes plugins from the records
(`distributed: ... applied`), signs the apt index and publishes into the channel. A manual run (`workflow_dispatch`)
does everything except publishing.

## Provenance of this set

| | |
| --- | --- |
| Image | ZynthianOS Vangelis-2610.1, built 2026-10-15 from Raspberry Pi OS Trixie (aarch64) |
| Board | Raspberry Pi 5 Model B Rev 1.0, a real board |
| Measured | 2026-10-28, host profile `omx-clap-host` |
| zynthian-ui | `7ed5bcd61939422e1394f5d8b730e8532611c453` |
| zynthian-sys | `aa36238dcb36fc004eaa4e027184adc8e67e8e8b` |
| Packages | plugin-qualify 0.16.1, plugin-hostd 0.13.1, omx-clap-host 0.23.2, omx-plugins 0.15.1, omx-contract-data 3.4.0, omx-panel 0.6.0, distrho-plugin-ports-lv2 5:20210315 (the full list is in `provenance.json`) |

Records measured under an emulated CPU are never accepted into this repository: a figure from an emulator is not
the machine class's. `provenance.json` names the board the records were measured on, and a record set without a
real board named there is refused at review.

## License

GPL-3.0-or-later, as plugin-qualify. See `LICENSE`.
