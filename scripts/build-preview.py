#!/usr/bin/env python3
"""Bundle the local interface study into one portable HTML artifact."""
from pathlib import Path

preview = Path(__file__).resolve().parent.parent / "preview"
html = (preview / "index.html").read_text()
html = html.replace('<link rel="stylesheet" href="style.css">',
                    '<style>\n' + (preview / "style.css").read_text() + '\n</style>')
html = html.replace('<script src="app.js"></script>',
                    '<script>\n' + (preview / "app.js").read_text() + '\n</script>')
(preview / "harness-preview.html").write_text(html)
print("Built preview/harness-preview.html")
