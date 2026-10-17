"""What the UI tour flags in a window's accessibility tree (`ax tree`), for a reviewer to look at."""


def inside(inner, outer, slack=2):
    return (inner[0] >= outer[0] - slack and inner[1] >= outer[1] - slack
            and inner[0] + inner[2] <= outer[0] + outer[2] + slack and inner[1] + inner[3] <= outer[1] + outer[3] + slack)


def overlap(a, b):
    w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return max(0, w) * max(0, h)


CONTROLS = {"AXButton", "AXCheckBox", "AXPopUpButton", "AXRadioButton", "AXMenuButton", "AXTextField", "AXSlider",
            "AXSwitch", "AXSearchField", "AXComboBox"}
LEAVES = CONTROLS | {"AXStaticText", "AXImage"}
SCROLLED = {"AXScrollArea", "AXList", "AXOutline", "AXTable", "AXWebArea", "AXMenu", "AXMenuBarItem"}


def checks(tree):
    """What the tree says a reviewer should look at: controls without a label, elements outside their window,
    sibling leaves drawn over each other. Truncation is not in the tree (AX gives the whole string): see the picture."""
    found = []

    def walk(node, window, scrolled, path):
        role, box = node.get("role", ""), node.get("frame")
        label = node.get("title") or node.get("description") or node.get("help") or node.get("value")
        here = f"{path}/{role}" + (f"#{node['identifier']}" if node.get("identifier") else "")
        if role in CONTROLS and not label and node.get("subrole") not in ("AXCloseButton", "AXMinimizeButton",
                                                                         "AXZoomButton", "AXFullScreenButton"):
            found.append({"kind": "unlabelled", "where": here})
        if box and window and box[2] > 0 and box[3] > 0 and not scrolled and not inside(box, window):
            found.append({"kind": "outside-window", "where": here, "frame": box, "window": window,
                          "text": str(label or "")[:60]})
        kids = node.get("children", [])
        leaves = [k for k in kids if k.get("role") in LEAVES and k.get("frame") and k["frame"][2] * k["frame"][3] > 0]
        for i, a in enumerate(leaves):
            for b in leaves[i + 1:]:
                common = overlap(a["frame"], b["frame"])
                smaller = min(a["frame"][2] * a["frame"][3], b["frame"][2] * b["frame"][3])
                if smaller and common / smaller > 0.25:
                    found.append({"kind": "overlap", "where": here,
                                  "a": str(a.get("title") or a.get("value") or a.get("role"))[:40],
                                  "b": str(b.get("title") or b.get("value") or b.get("role"))[:40]})
        for kid in kids:
            walk(kid, window, scrolled or role in SCROLLED, here)

    for window in tree.get("windows", []):
        walk(window, window.get("frame") if window.get("role") == "AXWindow" else None, False, "")
    return found[:60]
