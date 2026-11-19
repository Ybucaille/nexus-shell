# nexus-shell

The desktop shell of [NexusOS](https://github.com/Ybucaille/NexusOS): bar,
launcher, notifications, lock screen, dashboard and settings, built with
[Quickshell](https://quickshell.outfoxxed.me) for Hyprland.

NexusOS is the only target. The shell is packaged and launched by the
distribution (`nexusos-desktop`), so it carries no installer, updater or
support for other distributions; system features go through NexusOS
components, such as `nexusos-update` for updates.

## Origin

nexus-shell starts from [caelestia-shell](https://github.com/caelestia-dots/shell)
2.5.0 by Soramane and its contributors. It is not a tracking fork: modules are
removed, reorganised and rewritten one by one for NexusOS, and upstream ideas
are picked case by case. Thanks to the Caelestia project for the base.

## Building

Dependencies are listed in the NexusOS package recipe (`pkgs/nexus-shell`).

```sh
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/
cmake --build build
sudo cmake --install build
```

## License

GPL-3.0-only, like the code it derives from ([LICENSE](LICENSE)).
