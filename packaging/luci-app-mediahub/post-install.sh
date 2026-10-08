#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "${IPKG_INSTROOT}" ] && exit 0

chmod 755 /usr/bin/mediahub-cms.py /usr/bin/mediahub-alist-setup.sh \
	/usr/bin/mediahub-install.sh /usr/bin/alist-run \
	/etc/init.d/mediahub-cms /etc/init.d/alist 2>/dev/null || true

if [ -f /mnt/data/ffmpeg/ffmpeg ]; then
	chmod 755 /mnt/data/ffmpeg/ffmpeg /mnt/data/ffmpeg/ffprobe 2>/dev/null || true
fi

if [ -x /etc/uci-defaults/mediahub-setup ]; then
	sh /etc/uci-defaults/mediahub-setup >/tmp/mediahub-setup.log 2>&1 || true
	rm -f /etc/uci-defaults/mediahub-setup
else
	/etc/init.d/alist restart 2>/dev/null || true
	/etc/init.d/mediahub-cms restart 2>/dev/null || true
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
