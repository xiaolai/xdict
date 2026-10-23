"""Visibility postconditions for native controls, using the captured AX hierarchy."""


def visible(tree, identifier, role=None):
    def inside(frame, clips):
        if not frame or len(frame) != 4 or frame[2] <= 0 or frame[3] <= 0:
            return False
        x, y, width, height = frame
        return all(x >= cx - 1 and y >= cy - 1 and x + width <= cx + cw + 1
                   and y + height <= cy + ch + 1 for cx, cy, cw, ch in clips)

    def walk(node, clips):
        frame = node.get("frame")
        if node.get("role") == "AXSheet" and frame:
            clips = [frame]
        elif node.get("role") in ("AXWindow", "AXScrollArea", "AXClipView") and frame:
            clips = clips + [frame]
        if (node.get("identifier") == identifier and (role is None or node.get("role") == role)
                and clips and inside(frame, clips)):
            return True
        return any(walk(child, clips) for child in node.get("children", []) + node.get("windows", []))

    return walk(tree, [])


def fills_container(tree, identifier):
    """The answer scroller spans its native inspector/sheet column, without an unused horizontal strip."""
    def walk(node, parents):
        if node.get("identifier") == identifier and node.get("role") == "AXScrollArea":
            frame = node.get("frame")
            parent = next((p.get("frame") for p in reversed(parents)
                           if p.get("role") == "AXGroup" and p.get("frame")), None)
            return bool(frame and parent and abs(frame[0] - parent[0]) <= 1
                        and abs(frame[2] - parent[2]) <= 1)
        return any(walk(child, parents + [node])
                   for child in node.get("children", []) + node.get("windows", []))

    return walk(tree, [])
