pragma Singleton

import Quickshell
import Caelestia.I18n

Singleton {
    property var _regexCache: ({})

    function percent(value: int): string {
        // TRANSLATORS: %1 = a number
        return Tr.tr("%1%").arg(value);
    }

    function percentOne(value: real): string {
        return percent(Math.round(value * 100));
    }

    function testRegexList(filterList: list<string>, target: string): bool {
        const regexChecker = /^\^.*\$$/;
        for (const filter of filterList) {
            if (regexChecker.test(filter)) {
                if (!(filter in _regexCache)) {
                    try {
                        _regexCache[filter] = new RegExp(filter);
                    } catch (e) {
                        console.warn("Strings: invalid regex filter:", filter, e);
                        _regexCache[filter] = null;
                    }
                }
                if (_regexCache[filter]?.test(target))
                    return true;
            } else {
                if (filter === target)
                    return true;
            }
        }
        return false;
    }
}
