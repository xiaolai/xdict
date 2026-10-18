"""What `hands select` selected, held to what was asked. A host that selected something else (Chrome's triple-click
fallback took the fixture's first line for the phrase, E2E 2026-10-18) is refused with its own reason, so the check
fails as "could not select", never by handing the wrong text on to XDict and blaming the panel.
"""


def refused(needle, answer):
    """None when the host selected exactly `needle`; else the sentence saying what it selected instead, and how."""
    selected = answer.get("selected")
    if selected == needle:
        return None
    return f"selected {selected!r} ({answer.get('dialect')}), not {needle!r}"
