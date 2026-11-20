pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
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

    // Ordered to match channelValues
    readonly property list<MenuItem> channelItems: [
        MenuItem {
            text: Tr.tr("Stable")
            icon: "verified"
        },
        MenuItem {
            text: Tr.tr("Testing")
            icon: "science"
        }
    ]
    readonly property list<string> channelValues: ["stable", "testing"]
    // Rollback targets: the snapshots taken before a change, newest first
    readonly property var restorable: SystemUpdate.snapshots.filter(s => s.type !== "post").slice(0, 10)
    readonly property bool showBooted: SystemUpdate.bootedSnapshot > 0
    readonly property bool showDone: SystemUpdate.rollbackState === "done"
    readonly property bool showMessage: SystemUpdate.rollbackMessage !== ""

    function snapshotTime(date: string): string {
        const m = date.match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/);
        if (!m)
            return date;
        // The file holds UTC; show it in local time.
        const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])));
        return Qt.formatDateTime(d, Units.twelveHourClock ? "yyyy-MM-dd h:mm A" : "yyyy-MM-dd hh:mm");
    }

    title: Tr.tr("Updates")

    Component.onCompleted: SystemUpdate.reloadSnapshots()

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

        SelectRow {
            label: Tr.tr("Channel")
            subtext: Tr.tr("Testing gets every build that passes CI; stable only tested releases")
            menuItems: root.channelItems
            active: root.channelItems[root.channelValues.indexOf(SystemUpdate.channel)] ?? null
            fallbackText: SystemUpdate.channel === "custom" ? Tr.tr("Custom source") : "…"
            opacity: SystemUpdate.busy ? 0.5 : 1
            onSelected: item => {
                if (!SystemUpdate.busy)
                    SystemUpdate.setChannel(root.channelValues[root.channelItems.indexOf(item)]);
            }
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

        SectionHeader {
            text: Tr.tr("Restore a snapshot")
        }

        InfoRow {
            first: true
            icon: "info"
            label: Tr.tr("The snapshot becomes the system at the next restart; the current system is kept")
        }

        InfoRow {
            visible: root.showBooted
            icon: "history"
            label: Tr.tr("Running snapshot %1 from the boot menu (read-only)").arg(SystemUpdate.bootedSnapshot)
        }

        RowButton {
            visible: root.showBooted
            icon: "published_with_changes"
            text: Tr.tr("Keep this snapshot")
            disabled: SystemUpdate.busy
            onClicked: SystemUpdate.rollback(SystemUpdate.bootedSnapshot)
        }

        InfoRow {
            visible: root.showDone
            icon: "check_circle"
            iconColour: Colours.palette.m3primary
            label: Tr.tr("Snapshot %1 will be the system after a restart").arg(SystemUpdate.rollbackSnapshot)
        }

        RowButton {
            visible: root.showDone
            icon: "restart_alt"
            text: Tr.tr("Restart now")
            onClicked: SystemUpdate.reboot()
        }

        InfoRow {
            visible: root.showMessage
            icon: "error"
            iconColour: Colours.palette.m3error
            label: SystemUpdate.rollbackMessage
        }

        InfoRow {
            visible: root.restorable.length === 0
            last: true
            icon: "history"
            label: Tr.tr("No snapshot yet: one is taken before each update")
        }

        Repeater {
            id: snapshotList

            model: root.restorable

            RowButton {
                required property var modelData
                required property int index

                last: index === snapshotList.count - 1
                icon: "history"
                text: modelData.release ? Tr.tr("Before the update to %1").arg(modelData.release) : modelData.description || Tr.tr("Snapshot %1").arg(modelData.number)
                subtext: root.snapshotTime(modelData.date) + (modelData.boot ? "" : " · " + Tr.tr("no boot entry"))
                disabled: SystemUpdate.busy
                onClicked: SystemUpdate.rollback(modelData.number)
            }
        }
    }
}
