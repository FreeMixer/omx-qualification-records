#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
#
# The run behind records/x86-64/fedora44: in a fedora:44 container (job.yaml, a Job in the cluster's omx-worker
# namespace), the OpenMixer channel's plugin-qualify, plugin-hostd and omx-clap-host, the worker image's plugin set
# (platform k8s/omx-worker/images/openmixer/baked-versions.yml: omx-plugins clap and lv2, rpms lv2-plugins and
# clap-plugins, handed over as PLUGINS), and plugin-qualify-sync --system against a dummy-driver JACK server of the
# pod's own. Everything it leaves is in /out: the sync's log, the package list, the CPU, the real-time limits and a
# tarball of /var/lib/omx, whose qualification/ goes to tools/build-package.sh --from.
#
#   HOST_CLASS x86-64   GRID 48000/512 (the cell the Zynthian set was measured at)   MEMORY_LIMIT 6G   PLUGINS ...
set -uo pipefail
out=/out; mkdir -p $out; exec > >(tee -a $out/job.log) 2>&1
echo "start $(date -u +%FT%TZ) on $NODE_NAME"
set -e
dnf -y -q install https://www.openmixer.org/rpm/openmixer-release.noarch.rpm
gpg --show-keys --with-subkey-fingerprints /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer | grep -qi 6AF1C62F
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-openmixer
cat > /etc/yum.repos.d/copr-audinux.repo <<R
[copr-ycollet-audinux]
name=audinux
baseurl=https://download.copr.fedorainfracloud.org/results/ycollet/audinux/fedora-\$releasever-\$basearch/
gpgkey=https://download.copr.fedorainfracloud.org/results/ycollet/audinux/pubkey.gpg
gpgcheck=1
repo_gpgcheck=0
enabled=1
# the channel's mod-host build (11.3.omx, socket_set_bind_address) is the one plugin-hostd links; the COPR's sorts above it
exclude=mod-host mod-host-protocol mod-host-protocol-devel
R
# pipewire's libjack replaces jackd's libjackserver through ld.so.conf, and every jackd (the pod's and the sync's
# private ones) then refuses the dummy driver ("not a master"): every adapter run fails with ERR_JACK_CLIENT_CREATION
echo 'excludepkgs=pipewire-jack-audio-connection-kit*' >> /etc/dnf/dnf.conf
dnf -y -q makecache
dnf -y install plugin-qualify omx-clap-host plugin-hostd jack-audio-connection-kit lilv-devel util-linux procps-ng tar xz \
  omx-plugins-clap omx-plugins-lv2
dnf -y install --skip-unavailable --skip-broken $PLUGINS
bash /script/channel-check.sh || exit 1
plugin-hostd --version
! rpm -q pipewire-jack-audio-connection-kit-libs
python3 -c 'import lilv; print("lilv", lilv.World)'
timeout 10 jackd -n omxprobe -d dummy -r 48000 -p 512 & sleep 3; JACK_DEFAULT_SERVER=omxprobe jack_wait -c || true; kill %1 2>/dev/null; wait
set +e
dnf repoquery --installed --qf '%{name} %{evr} %{from_repo}\n' | sort > $out/installed.txt
# the packages that own a plugin directory's entries: the set's package list for provenance.json
rpm -qf --qf '%{NAME}\t%{EPOCH}:%{VERSION}-%{RELEASE}\n' $(find /usr/lib/clap /usr/lib64/clap /usr/lib64/lv2 /usr/lib/lv2 -mindepth 1 -maxdepth 1 2>/dev/null) | sed 's/(none)://' | sort -u > $out/plugin-packages.tsv
for p in $PLUGINS; do rpm -q $p >/dev/null || echo "$p"; done > $out/not-installed.txt
echo "not installed: $(wc -l < $out/not-installed.txt)"
cat /etc/os-release > $out/os-release
uname -a > $out/uname; lscpu > $out/lscpu; nproc >> $out/lscpu
echo "ulimit -r $(ulimit -r) -l $(ulimit -l)" | tee $out/rt.txt
chrt -f 10 true && echo "SCHED_FIFO: yes" | tee -a $out/rt.txt || echo "SCHED_FIFO: refused" | tee -a $out/rt.txt
grep Cap /proc/self/status >> $out/rt.txt
rpm -q plugin-qualify plugin-hostd omx-clap-host omx-clap-core mod-host-protocol omx-plugins-clap omx-plugins-lv2 jack-audio-connection-kit > $out/versions.txt; plugin-hostd --version >> $out/versions.txt 2>&1; omx-clap-host --version >> $out/versions.txt 2>&1
cat $out/versions.txt
mkdir -p /etc/omx
# clap_extra: Fedora's and the COPR's CLAP packages install into /usr/lib64/clap, which the sync's default CLAP path
# (~/.clap, /usr/lib/clap) leaves out
cat > /etc/omx/qualify.conf <<C
host_class $HOST_CLASS
hostd_port 0
grid $GRID
memory_limit $MEMORY_LIMIT
clap_extra /usr/lib64/clap
C
# the JACK server a device runs: the admission under omx-clap-host adds each LV2 plugin as a client of the default
# server. Private to this pod, dummy driver, the cell the grid measures; started again whenever it ends, since an
# admission without a server answers ERR_JACK_CLIENT_CREATION for a plugin that never ran
( while :; do echo "jackd start $(date -u +%FT%T.%NZ)"; jackd -r -d dummy -r 48000 -p 512; echo "jackd exit $? $(date -u +%FT%T.%NZ)"; sleep 1; done ) > $out/jackd.log 2>&1 &
sup=$!
sleep 3
# a plugin whose admission or isolated step found no JACK server (resp -201, isolated.no-host) is dropped from the
# state and measured again by the next pass; what still fails after three passes stays as measured
for pass in 1 2 3; do
  echo "pass $pass start $(date -u +%FT%TZ)"
  plugin-qualify-sync --system > $out/sync-$pass.log 2>&1
  echo "pass $pass exit $?"
  tail -2 $out/sync-$pass.log
  bad=$(python3 - "$pass" <<'P'
import json,sys
st='/var/lib/omx/qualify-sync.json'; d=json.load(open(st))
bad=[k for k,e in d['entries'].items() if any('resp-201' in str(p.get('code','')) or 'no-host' in str(p.get('code','')) for p in e.get('plugins',[]))]
for k in bad: del d['entries'][k]
json.dump(d,open(st,'w'))
open('/out/redo-%s.txt'%sys.argv[1],'w').write(''.join(k+'\n' for k in bad))
print(len(bad))
P
)
  echo "pass $pass: $bad plugins to measure again"
  [ "$bad" -eq 0 ] && break
done
echo "jackd exits: $(grep -c 'jackd exit' $out/jackd.log)"
kill $sup; pkill -x jackd
tar -C /var/lib -cJf $out/var-lib-omx.tar.xz omx
echo "$(date -u +%FT%TZ)" > $out/done
echo "done; waiting to be copied"
sleep 36000
