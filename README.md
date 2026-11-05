# omx-qualification-records

The distributed qualification records of plugin sets, as Debian and RPM packages.

[plugin-qualify](https://github.com/FreeMixer/plugin-qualify) measures every LV2 and CLAP plugin of a device
before the device hosts it. A Raspberry Pi 5 takes hours to measure a full Zynthian image. A device of the same
machine class and the same plugin set does not need to measure it again: this repository holds the records one
such device wrote, and publishes them as `omx-qualification-<host class>-<set>`, which `plugin-qualify-sync`
reads before it measures anything.

| package | host class | plugin set | records |
| --- | --- | --- | --- |
| `omx-qualification-rpi5-zynthian-vangelis` (deb) | `rpi5` (Raspberry Pi 5) | ZynthianOS Vangelis-2610.1 | 1886 |
| `omx-qualification-x86-64-fedora44` (rpm) | `x86-64` (set in `/etc/omx/qualify.conf`) | Fedora 44: the OpenMixer worker image's plugins (omx-plugins, the audinux CLAP set, LSP, caps, airwindows, dragonfly), less the plugins left out below | 666 |

Each package is architecture-independent (`Architecture: all`, `BuildArch: noarch`), depends on the plugin-qualify
that reads the layer (`plugin-qualify (>= 0.17.0~)`, `plugin-qualify >= 0.17.0`), and installs

```
/usr/share/omx/qualification/rpi5/zynthian-vangelis/
    <plugin>@<version>-<sha256 first 12>.<offer>.qualification.json   # the record
    <same name>.probe.json                                              # the probe output the record judged, byte for byte
    provenance.json                                                     # where the set comes from
```

Each record is held with its probe output. Both are the files the measuring device wrote, unchanged. The plugins
that could not be measured (`*.unmeasured.json`: 2 on the Zynthian device, 1 in the Fedora set) are not here: an
unmeasured record never applies. The Fedora set also leaves out the plugins whose refusal it does not trust (see its
provenance below): a device measures those itself.

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

On Fedora 44 x86_64:

```
dnf install https://www.openmixer.org/rpm/openmixer-release.noarch.rpm
dnf install omx-qualification-x86-64-fedora44
printf 'host_class x86-64\nclap_extra /usr/lib64/clap\n' >> /etc/omx/qualify.conf
plugin-qualify-sync --system
```

An x86_64 machine has no device tree, so it has no class of its own: plugin-qualify-sync reads no distributed record
until `host_class` names one. Fedora's CLAP packages (and the audinux ones) install into `/usr/lib64/clap`, which
the sync's default CLAP path (`~/.clap`, `/usr/lib/clap`) leaves out; `clap_extra` adds it, as on the machine that
measured the set. The CLAP records are found by their `.clap` path, so without it those plugins are neither measured
nor taken from the records.

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

The Fedora set is measured in a pod, not on a desk: `tools/fedora44/job.yaml` is a Job in the cluster's
`omx-worker` namespace, and `tools/fedora44/measure.sh` installs the channel's plugin-qualify, plugin-hostd and
omx-clap-host with the worker image's plugin set (platform `baked-versions.yml`) in `fedora:44`, starts a JACK
server of the pod's own (dummy driver, 48000/512) and runs `plugin-qualify-sync --system`. Copy `/out` out of the pod
and feed the qualification directory of its `var-lib-omx.tar.xz` to

```
tools/build-package.sh --from <qualification dir> --provenance provenance.json \
    --version <YYYYMMDDXX> --host-class x86-64 --set fedora44
```

For the set the RPM spec builds, the script replaces only `records/x86-64/fedora44/` and the spec's `Version`.

`tools/check-records.py` reads every set as plugin-qualify-sync will: the provenance names its set and class, every
record has its probe output beside it with the size and SHA-256 it names, and nothing else is shipped. The `check`
workflow runs it on every pull request, and the RPM's `%check` runs it on the installed tree.

## The host comparison

A set can also hold how its plugins fare under four hosts: our two (omx-clap-host, with the LV2 adapter, and
plugin-hostd) and the two references, mod-host and jalv. `plugin-qualify compare` runs every plugin through each host
with the same checks (it loads, it instantiates, it gives output under a tone or notes, it survives the load cycles and
the soak, its audio thread allocates, locks or makes a system call or not, its CPU and the latency the host reports) on
one private JACK server at one rate and quantum, and writes one `<plugin>-<format>-<hash>.comparison.json` per plugin
(`plugin-qualify.comparison-record/1`, a row per host, each with its version) and `comparison-summary.json`
(`plugin-qualify.comparison-summary/1`: per host the plugins it loads, runs clean, runs real-time safe and crashes on,
and the plugins where each host does better than the others). A check a host does not let us observe is
`not-observable`, never a failure; a host that is not installed is a `skipped` row with its reason.

On a machine of the set's class, with mod-host and jalv installed (`--publish` refuses to run without them, naming
what is missing):

```
plugin-qualify compare --all --publish --host-class <class> --set <set> --out <dir>
cp <dir>/*.comparison.json <dir>/comparison-summary.json records/<class>/<set>/
python3 tools/check-records.py records/<class>/<set>
```

`tools/check-records.py` holds a set's comparison to the rules: every record is one, a set with comparison records has
their summary, the summary is publishable, mod-host and jalv ran, and its counts are the ones its records give. The
packages ship the files; plugin-qualify-sync reads only the qualification records. The comparison is not bound to the
plugins' bytes as a record is, so a rebuild of the set from a device run drops it (`tools/build-package.sh` says so),
and the new set's comparison is added after. The site's plugin pages show it per machine class.

## Release

A tag `v*` runs `.github/workflows/release.yml`: it builds the package from `debian/`, runs lintian (warnings fail),
installs it in Debian trixie on arm64 with plugin-qualify from the channel and Debian's own arm64 lv2vocoder
(its bytes are the set's), asserts that `plugin-qualify-sync --system` takes plugins from the records
(`distributed: ... applied`), signs the apt index and publishes into the channel.

The same tag builds the RPM from `packaging/omx-qualification-records.spec` through FreeMixer/.github's
`build-rpm.yml` (one noarch build, signed and published into the channel's `rpm/` tree, attached to the same
GitHub release), then installs it in Fedora 44 with plugin-qualify and the omx-plugins version the set measured from
the channel, and asserts that `plugin-qualify-sync --system` takes them from the records. The spec's `Version` and
the top `debian/changelog` entry are the same number, and the tag must equal both (the `check` workflow holds them
together). A manual run (`workflow_dispatch`) does everything except publishing.

## Versions

A records package is versioned by the date its records are published: `YYYYMMDDXX`, the year, month and day
followed by the day's serial, `01` for the first release of the day. A number is never used twice, even for a
release that did not publish: the next one takes the next serial. No dots or other separators: `2026103001`.
The tag is `v` and the version (`v2026103001`). These numbers sort in time order for both dpkg and rpm, so a
device always upgrades to the newer set; the first release, `2026.10.29`, sorts below all of them.

A tagged commit with `debian/republish` does not build: it repacks a package the channel holds under the new
version, every installed file unchanged (see `.github/workflows/release.yml`). `2026103003` is the `2026.10.29`
package under the new scheme, so its files, `provenance.json` included, still name `2026.10.29`.

## Provenance of the Zynthian set

| | |
| --- | --- |
| Image | ZynthianOS Vangelis-2610.1, built 2026-10-15 from Raspberry Pi OS Trixie (aarch64) |
| Board | Raspberry Pi 5 Model B Rev 1.0, a real board |
| Measured | 2026-10-28, host profile `omx-clap-host` |
| zynthian-ui | `7ed5bcd61939422e1394f5d8b730e8532611c453` |
| zynthian-sys | `aa36238dcb36fc004eaa4e027184adc8e67e8e8b` |
| Packages | plugin-qualify 0.16.1, plugin-hostd 0.13.1, omx-clap-host 0.23.2, omx-plugins 0.15.1, omx-contract-data 3.4.0, omx-panel 0.6.0, distrho-plugin-ports-lv2 5:20210315 (the full list is in `provenance.json`) |

## Provenance of the Fedora set

| | |
| --- | --- |
| Image | `fedora:44` container (Fedora Linux 44, x86_64) with the worker image's plugin set, platform `baked-versions.yml` at `f8ad21305adea756dd0d9adf6693c69178b16a51` |
| Machine | AMD Ryzen 7 PRO 8700GE (8 cores, 16 threads), cluster node h2, a pod limited to 3 CPUs |
| Measured | 2026-11-01, host profile `omx-clap-host`, grid 48000/512 (the Zynthian set's cell) |
| Real time | none: the namespace's pod security (baseline) grants no `CAP_SYS_NICE` and `RLIMIT_RTPRIO` is 0, so the probe and the isolated step ran under `SCHED_OTHER`; every probe output says so (`run.realtime.class: none`) |
| Packages | plugin-qualify 0.18.5, plugin-hostd 0.15.8, omx-clap-host 0.26.2, omx-plugins 0.16.0, mod-host-protocol 0.10.6.f14a230-11.3.omx, jack-audio-connection-kit 1.9.22, lsp-plugins-clap 1.2.29, and 141 more plugin packages from the audinux COPR and Fedora (the full list is in `provenance.json`) |

The run measured 642 plugins (420 CLAP, 222 LV2): 628 qualified, 14 refused, 4 crashed, 1 unmeasured, in 1070
records. The package holds 666 of those records.

Left out, besides the unmeasured one: the 9 plugins the isolated step refused with `isolated.silent-output`
(Aeolus, Cardinal, MPaint, RetroTrax, NodalRed2x, OsTIrus, Spiro, Stochas, LSP's A/B tester). The isolated step
plays 3 seconds through plugin-hostd on a JACK server; here that server had no real-time priority and ran on a shared
node, and 187 of the step's 223 runs saw xruns. A refused record applies on a device and keeps the plugin off it, so a
refusal measured that way is not shipped: the device measures the plugin itself. The sync matches a CLAP binary as a
whole, so the whole binary of each is left out, which for `lsp-plugins.clap` is all 194 of its plugins (388 records):
a device measures the LSP CLAP bundle itself. `provenance.json` lists them under `leftOut`.

Kept: `isolated.non-finite-output` for ZamEQ2, and `isolated.not-added` for Cardinal's and Ildaeil's LV2 variants
and some offers of other CLAP plugins (Surge XT among them), where plugin-hostd answered `-509` to the pin: its own
refusal, not a figure the missing real-time priority could change. A machine that measures a plugin itself
overwrites the record.

Records measured under an emulated CPU are never accepted into this repository: a figure from an emulator is not
the machine class's. `provenance.json` names the board the records were measured on, and a record set without a
real board named there is refused at review.

## License

GPL-3.0-or-later, as plugin-qualify. See `LICENSE`.
