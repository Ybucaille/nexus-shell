pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    readonly property string status: {
        switch (SystemUpdate.state) {
        case "checking":
            return Tr.tr("Checking for a new release...");
        case "available":
            return SystemUpdate.availableSnapshot ? Tr.tr("Snapshot %1 is available").arg(SystemUpdate.availableSnapshot) : Tr.tr("A new release is available");
        case "upToDate":
            return Tr.tr("NexusOS is up to date");
        case "upgrading":
            return Tr.tr("Updating...");
        case "done":
            return Tr.tr("Updated: restart to use the new system");
        case "failed":
            return Tr.tr("The update did not go through");
        default:
            return Tr.tr("Not checked yet");
        }
    }

    title: Tr.tr("Updates")

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        InfoRow {
            first: true
            icon: SystemUpdate.state === "available" ? "system_update" : SystemUpdate.state === "failed" ? "error" : "verified"
            iconColour: SystemUpdate.state === "failed" ? Colours.palette.m3error : SystemUpdate.state === "available" ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
            label: root.status
            value: SystemUpdate.state === "upgrading" ? SystemUpdate.progress : SystemUpdate.message
        }

        InfoRow {
            label: Tr.tr("Installed snapshot")
            value: SystemUpdate.currentSnapshot || "…"
        }

        InfoRow {
            label: Tr.tr("Channel")
            value: SystemUpdate.channel === "stable" ? Tr.tr("Stable") : SystemUpdate.channel === "testing" ? Tr.tr("Testing") : SystemUpdate.channel === "custom" ? Tr.tr("Custom source") : "…"
        }

        RowButton {
            icon: "refresh"
            text: Tr.tr("Check for updates")
            subtext: SystemUpdate.lastCheck.getTime() ? Tr.tr("Last checked at %1").arg(Qt.formatTime(SystemUpdate.lastCheck, Units.twelveHourClock ? "h:mm A" : "hh:mm")) : ""
            last: SystemUpdate.state !== "available"
            disabled: SystemUpdate.busy
            onClicked: SystemUpdate.check()
        }

        RowButton {
            visible: SystemUpdate.state === "available"
            last: true
            icon: "download"
            text: Tr.tr("Update now")
            subtext: Tr.tr("A snapshot of the system is taken first, so it can be restored from the boot menu")
            disabled: SystemUpdate.busy
            onClicked: SystemUpdate.upgrade()
        }
    }
}
