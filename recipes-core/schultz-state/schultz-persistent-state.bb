SUMMARY = "Keep per-device state on /data so the rootfs can be read-only"
DESCRIPTION = "ADR-0015: the image is identical on every device; anything that \
differs between two devices running the same release is state and belongs on \
the /data partition."
LICENSE = "CLOSED"

SRC_URI = "file://schultz-persistent-state.sh \
           file://schultz-persistent-state.service"

S = "${UNPACKDIR}"

inherit systemd

RDEPENDS:${PN} = "openssh-keygen"

SYSTEMD_SERVICE:${PN} = "schultz-persistent-state.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${UNPACKDIR}/schultz-persistent-state.sh \
        ${D}${libexecdir}/schultz-persistent-state

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/schultz-persistent-state.service \
        ${D}${systemd_system_unitdir}/

    # The bind mount hides whatever the image shipped in /etc/ssh, so sshd's
    # config is stashed where the script can copy it back in.
    install -d ${D}${datadir}/schultz-state/ssh

    install -d ${D}/data/state
}

FILES:${PN} = "\
    ${libexecdir}/schultz-persistent-state \
    ${systemd_system_unitdir}/schultz-persistent-state.service \
    ${datadir}/schultz-state \
    /data/state \
"
