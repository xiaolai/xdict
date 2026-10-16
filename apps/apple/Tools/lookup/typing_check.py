"""Typing into the search field, confirmed by reading the field back (`drive.py`).

The E2E Mac can drop a key event while another application or a person touches it; counting the keys the app saw
cannot tell that from the app's failure, and a run that stops there leaves every later check of the scenario
unreported. So the field is read back: a miss is typed once more over the selected field, holding the front first;
a second miss raises `Lost`, one sentence naming what the field held each time and who had the front.
"""


class Lost(Exception):
    pass


def type_and_confirm(text, *, hold, select_all, type_keys, read_field, front):
    """Types `text` into the focused search field; returns (field, tries). `hold()` brings the app forward,
    `select_all()` selects the field, `type_keys(text)` posts the keys, `read_field()` is the field's text, `front()`
    names who has the E2E Mac's front."""
    held = []
    for tries in (1, 2):
        hold()
        if tries == 2:
            select_all()
        type_keys(text)
        field = read_field()
        if field == text:
            return field, tries
        held.append(field)
    raise Lost(f"typing {text!r}: the search field held {held[0]!r}, then {held[1]!r} after typing it again with the "
               f"app forward; the E2E Mac's front is {front()!r}, so a key went elsewhere")
