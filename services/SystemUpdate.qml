pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.I18n

// System updates through nexusos-update, the NexusOS updater (nexusos-base).
// A release is a dated Arch Linux Archive snapshot plus the nexusos
// repository built on it. A check runs when asked (UpdateMonitor asks a few
// times a day), and the log is only read while an upgrade runs. It also lists
// the btrfs snapshots of the system, rolls back to one of them
// (nexusos-rollback) and switches the update channel.
Singleton {
    id: root

    readonly property string updater: "/usr/bin/nexusos-update"
    readonly property string rollbackTool: "/usr/bin/nexusos-rollback"
    readonly property string logPath: `${Quickshell.env("XDG_RUNTIME_DIR")}/nexusos-update.log`

    // Installed snapshot (YYYY/MM/DD), read without privileges.
    readonly property string currentSnapshot: releaseFile.snapshot || mirrorlist.snapshot
    // "stable", "testing" or "custom", from /etc/nexusos/update.conf.
    readonly property string channel: {
        if (!updateConf.source)
            return "";
        const name = updateConf.source.replace(/\/+$/, "").split("/").pop();
        return name === "stable" || name === "testing" ? name : "custom";
    }

    // idle, checking, available, upToDate, upgrading, done, failed
    property string state: "idle"
    property string availableSnapshot
    property string message
    property string progress
    property date lastCheck
    // The running check was started by UpdateMonitor: a failure leaves the
    // state as it was instead of reporting an error nobody asked for.
    property bool background
    property string stateBeforeCheck
    // Snapshots of /, newest first: { number, date (UTC), type, boot, description, release }.
    property var snapshots: []
    // Snapshot booted from the boot menu, 0 for the normal system.
    property int bootedSnapshot: 0
    // "" (idle), running, done, failed
    property string rollbackState
    property int rollbackSnapshot
    property string rollbackMessage
    property bool changingChannel
    readonly property bool busy: state === "checking" || state === "upgrading" || rollbackState === "running" || changingChannel

    function check(): void {
        if (busy)
            return;
        background = false;
        startCheck();
    }

    // Not after an upgrade, whose "restart" state a check would hide.
    function checkInBackground(): void {
        if (busy || state === "done")
            return;
        background = true;
        startCheck();
    }

    function startCheck(): void {
        stateBeforeCheck = state;
        state = "checking";
        message = "";
        checkProc.running = true;
    }

    // Detached, so a shell restart in the middle of pacman cannot kill the
    // upgrade; the log file reports its progress and its exit status.
    function upgrade(): void {
        if (busy)
            return;
        state = "upgrading";
        message = "";
        progress = "";
        Quickshell.execDetached(["sh", "-c", `exec >"$1" 2>&1; pkexec ${updater} --yes; echo "nexus-shell: exit $?"`, "sh", logPath]);
    }

    function reloadSnapshots(): void {
        snapshotFile.reload();
    }

    // Lines: "current<TAB>N", then "N<TAB>date<TAB>type<TAB>boot<TAB>description".
    function readSnapshots(text: string): void {
        const list = [];
        let booted = 0;
        for (const line of text.split("\n")) {
            if (!line || line[0] === "#")
                continue;
            const f = line.split("\t");
            if (f[0] === "current") {
                booted = parseInt(f[1]) || 0;
            } else if (f.length >= 4 && parseInt(f[0]) > 0) {
                const description = f.slice(4).join("\t");
                list.push({
                    number: parseInt(f[0]),
                    date: f[1],
                    type: f[2],
                    boot: f[3] === "yes",
                    description,
                    release: match(description, /^nexusos-update ([0-9]{4}\/[0-9]{2}\/[0-9]{2})$/)
                });
            }
        }
        snapshots = list;
        bootedSnapshot = booted;
    }

    // Does not reboot: the snapshot becomes the system at the next restart.
    function rollback(number: int): void {
        if (busy)
            return;
        rollbackSnapshot = number;
        rollbackState = "running";
        rollbackMessage = "";
        rollbackProc.command = ["pkexec", rollbackTool, String(number), "--yes"];
        rollbackProc.running = true;
    }

    function reboot(): void {
        Quickshell.execDetached(["systemctl", "reboot"]);
    }

    function setChannel(name: string): void {
        if (busy || (name !== "stable" && name !== "testing") || name === channel)
            return;
        changingChannel = true;
        message = "";
        channelProc.command = ["pkexec", updater, "--channel", name];
        channelProc.running = true;
    }

    function match(text: string, pattern: var): string {
        return text.match(pattern)?.[1] ?? "";
    }

    function readLog(text: string): void {
        const lines = text.replace(/\s+$/, "").split("\n");
        const last = lines.pop() ?? "";
        const exit = last.match(/^nexus-shell: exit (\d+)$/);
        if (!exit) {
            progress = last;
            return;
        }

        const code = Number(exit[1]);
        if (code === 0) {
            state = "done";
            availableSnapshot = "";
            releaseFile.reload();
            mirrorlist.reload();
            reloadSnapshots();
        } else if (code === 126 || code === 127) {
            state = availableSnapshot ? "available" : "idle";
            message = Tr.tr("Authentication was cancelled.");
        } else {
            state = "failed";
            message = lines.pop() || Tr.tr("The update failed (exit %1).").arg(code);
        }
    }

    // An upgrade started before a shell restart is picked up again.
    Component.onCompleted: runningProc.running = true

    IpcHandler {
        function check(): void {
            root.check();
        }

        function upgrade(): void {
            root.upgrade();
        }

        // state, then the available snapshot and the last message, tab-separated
        function status(): string {
            return [root.state, root.availableSnapshot, root.message].join("\t");
        }

        // "current<TAB>N", then number, date, type and release or description per snapshot
        function snapshots(): string {
            const lines = [`current\t${root.bootedSnapshot}`];
            for (const s of root.snapshots)
                lines.push([s.number, s.date, s.type, s.release || s.description].join("\t"));
            return lines.join("\n");
        }

        function rollback(number: int): void {
            root.rollback(number);
        }

        function setChannel(name: string): void {
            root.setChannel(name);
        }

        target: "updates"
    }

    Process {
        id: runningProc

        command: ["pgrep", "-f", "nexusos-update --yes"]
        onExited: code => {
            if (code === 0)
                root.state = "upgrading";
        }
    }

    Process {
        id: checkProc

        // The check runs as the user (nexusos-base 0.5.0); only the upgrade needs pkexec.
        command: [root.updater, "--check"]
        stdout: StdioCollector {
            id: checkOut
        }
        stderr: StdioCollector {
            id: checkErr
        }
        onExited: code => {
            if (code !== 0 && code !== 2 && root.background) {
                root.state = root.stateBeforeCheck;
                return;
            }

            root.lastCheck = new Date();
            if (code === 0) {
                root.availableSnapshot = root.match(checkOut.text, /snapshot \S+ -> (\S+)/);
                root.state = "available";
            } else if (code === 2) {
                root.availableSnapshot = "";
                root.state = "upToDate";
            } else {
                root.state = "failed";
                root.message = checkErr.text.trim().split("\n").pop() || Tr.tr("The check failed (exit %1).").arg(code);
            }
        }
    }

    Process {
        id: rollbackProc

        stderr: StdioCollector {
            id: rollbackErr
        }
        onExited: code => {
            if (code === 0) {
                root.rollbackState = "done";
            } else if (code === 126 || code === 127) {
                root.rollbackState = "";
                root.rollbackMessage = Tr.tr("Authentication was cancelled.");
            } else {
                root.rollbackState = "failed";
                root.rollbackMessage = rollbackErr.text.trim().split("\n").pop() || Tr.tr("The rollback failed (exit %1).").arg(code);
            }
            root.reloadSnapshots();
        }
    }

    Process {
        id: channelProc

        stderr: StdioCollector {
            id: channelErr
        }
        onExited: code => {
            root.changingChannel = false;
            if (code === 0) {
                updateConf.reload();
                root.check();
            } else if (code === 126 || code === 127) {
                root.message = Tr.tr("Authentication was cancelled.");
            } else {
                root.message = channelErr.text.trim().split("\n").pop() || Tr.tr("Changing the channel failed (exit %1).").arg(code);
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.state === "upgrading"
        onTriggered: upgradeLog.reload()
    }

    FileView {
        id: upgradeLog

        path: root.state === "upgrading" ? root.logPath : ""
        printErrors: false
        onLoaded: {
            if (root.state === "upgrading")
                root.readLog(text());
        }
    }

    FileView {
        id: releaseFile

        property string snapshot

        path: "/var/lib/nexusos/repo/nexusos-release"
        printErrors: false
        onLoaded: snapshot = root.match(text(), /^snapshot=(\S+)$/m)
    }

    FileView {
        id: mirrorlist

        property string snapshot

        path: "/etc/pacman.d/mirrorlist"
        printErrors: false
        onLoaded: snapshot = root.match(text(), /^Server *= *https:\/\/archive\.archlinux\.org\/repos\/(\d{4}\/\d{2}\/\d{2})\//m)
    }

    FileView {
        id: snapshotFile

        path: "/var/lib/nexusos/snapshots"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.readSnapshots(text())
        onLoadFailed: root.readSnapshots("")
    }

    FileView {
        id: updateConf

        property string source

        path: "/etc/nexusos/update.conf"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        // nexusos-update takes the last source line.
        onLoaded: source = text().split("\n").map(l => root.match(l, /^source *= *(\S+)/)).filter(s => s).pop() ?? ""
    }
}
