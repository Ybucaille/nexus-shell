import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.I18n
import qs.services
import qs.modules.nexus

// Checks for a new NexusOS release a little after login, then every six
// hours, and tells about each new release once, with a notification that
// opens the Updates page.
Scope {
    id: root

    // The release already announced, or seen in the Updates page.
    property string seen

    Connections {
        function onStateChanged(): void {
            if (SystemUpdate.state !== "available")
                return;
            const release = SystemUpdate.availableSnapshot || "available";
            if (release === root.seen)
                return;
            root.seen = release;
            if (SystemUpdate.background) {
                notifyProc.body = SystemUpdate.availableSnapshot ? Tr.tr("Snapshot %1 is ready to install.").arg(SystemUpdate.availableSnapshot) : Tr.tr("A new release is ready to install.");
                notifyProc.running = true;
            }
        }

        target: SystemUpdate
    }

    Timer {
        // Only on NexusOS, where the installed snapshot can be read.
        running: SystemUpdate.currentSnapshot !== ""
        repeat: true
        // The first check leaves the network time to come up after login.
        interval: SystemUpdate.lastCheck.getTime() ? 6 * 60 * 60 * 1000 : 2 * 60 * 1000
        onTriggered: SystemUpdate.checkInBackground()
    }

    Process {
        id: notifyProc

        property string body

        // notify-send prints the action when its button is clicked.
        command: ["notify-send", "-a", "NexusOS", "-i", "nexusos-logo", "-A", `open=${Tr.tr("Open")}`, "--wait", Tr.tr("Update available"), body]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "open")
                    WindowFactory.create(null, {
                        page: PageRegistry.indexOf("updates")
                    });
            }
        }
    }
}
