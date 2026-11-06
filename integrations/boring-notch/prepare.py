#!/usr/bin/env python3
"""Apply the small receiver to an exact upstream checkout; never edit an app bundle."""
import pathlib
import subprocess
import sys

PINNED_COMMIT = "16b0f11f51c79d42e27c10d77fd9e53c11410fdb"


def main():
    checkout = pathlib.Path(sys.argv[1]).resolve()
    integration = pathlib.Path(__file__).resolve().parent
    root = integration.parent.parent
    revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if revision != PINNED_COMMIT:
        raise SystemExit("Use the documented Boring Notch v2.7.3 commit; refusing an untested source version.")
    path = checkout / "boringNotch/ContentView.swift"
    original = subprocess.check_output(["git", "-C", str(checkout), "show", "HEAD:boringNotch/ContentView.swift"], text=True)
    marker = "// BEGIN FihFlow receiver"
    current = path.read_text()
    replacements = [
        ("    @ObservedObject var musicManager = MusicManager.shared", "    @ObservedObject var fihFlow = FihFlowActivity.shared\n    @ObservedObject var musicManager = MusicManager.shared"),
        ("        var chinWidth: CGFloat = vm.closedNotchSize.width", "        if fihFlow.isActive && vm.notchState == .closed { return vm.closedNotchSize.width + 144 }\n        var chinWidth: CGFloat = vm.closedNotchSize.width"),
        ("                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show", "                    if fihFlow.isActive {\n                        FihFlowNotchActivityView(activity: fihFlow, notchWidth: vm.closedNotchSize.width, height: vm.effectiveClosedNotchHeight)\n                    } else if coordinator.expandingView.type == .battery && coordinator.expandingView.show"),
        ("                      if coordinator.sneakPeek.show {", "                      if coordinator.sneakPeek.show && !fihFlow.isActive {"),
    ]
    patched = original
    for before, after in replacements:
        if patched.count(before) != 1:
            raise SystemExit("Upstream layout does not match the tested integration.")
        patched = patched.replace(before, after)
    patched += "\n" + marker + "\n"
    patched += (root / "Sources/NotchActivityProtocol.swift").read_text()
    patched += "\n" + (integration / "FihFlowActivity.swift").read_text()
    if current != original and current != patched:
        raise SystemExit("ContentView.swift has changes; use a clean pinned checkout rather than overwriting them.")
    path.write_text(patched)
    print("Prepared Boring Notch with the FihFlow receiver.")


if __name__ == "__main__":
    main()
