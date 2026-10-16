"""The download buttons the README shows, read by gen_download_buttons.py.

Each entry names a button the generator knows and where it leads. The rows,
their order, the colours and the words are the generator's, the same in every
repository.
"""

REPO = "juicefs"

BUTTONS = {
    "unraid": "https://ca.unraid.net/apps/juicefs-14sugi10m394v9",
    "mos": "https://mos-official.net/apps.html?search=JuiceFS",
    "compose": "https://raw.githubusercontent.com/junkerderprovinz/juicefs/main/compose.yaml",
    # A release's "Source code (zip)" is the whole repository at that tag, and
    # GitHub gives the newest one no fixed address, so this leads to the release
    # that lists it.
    "source": "https://github.com/junkerderprovinz/juicefs/releases/latest",
}
