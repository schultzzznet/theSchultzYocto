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

S = "${WORKDIR}"

# Full python3 keeps the reference recipe bulletproof (urllib/json/subprocess all
# present). Size-conscious builds can pin the granular set instead:
#   RDEPENDS:${PN} = "python3-core python3-json python3-netclient python3-shell"
RDEPENDS:${PN} = "python3"

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
