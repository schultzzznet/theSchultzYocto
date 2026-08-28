SUMMARY = "theSchultzYocto fleet agent -- heartbeats device status to fleet-app"
DESCRIPTION = "A tiny stdlib-only Python service that POSTs os-release version, \
RAUC A/B slot and basic telemetry (temp, uptime, disk, undervoltage) to the \
fleet-app dashboard running in the cluster. Opt-in: add to an image with \
IMAGE_INSTALL:append = \" schultz-agent\". See docs/fleet-app.md."
HOMEPAGE = "https://github.com/schultzzznet/theSchultzYocto"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://schultz-agent \
           file://schultz-agent.service \
           file://schultz-agent.conf"

# wrynose: S = ${WORKDIR} was removed; use ${UNPACKDIR} for file:// sources.
S = "${UNPACKDIR}"

# The agent uses only stdlib (urllib/json/socket/subprocess). Pin the granular
# python3 packages -- full python3 pushes the ext4 rootfs over the 213 MB A/B
# slot (measured: 224 MB full vs 192 MB granular). netclient pulls in http.client
# + email; io provides socket. Proven on real hardware 2026-07-14.
RDEPENDS:${PN} = "python3-core python3-netclient python3-json python3-io"

inherit systemd

SYSTEMD_SERVICE:${PN} = "schultz-agent.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/schultz-agent ${D}${bindir}/schultz-agent

    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/schultz-agent.conf ${D}${sysconfdir}/schultz-agent.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/schultz-agent.service ${D}${systemd_system_unitdir}/schultz-agent.service
}

FILES:${PN} += "${systemd_system_unitdir}/schultz-agent.service"
CONFFILES:${PN} = "${sysconfdir}/schultz-agent.conf"
