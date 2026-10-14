#!/usr/bin/env python3
"""Bundle the interface preview and the full approved logo into one portable HTML file."""
import base64
from pathlib import Path

preview = Path(__file__).resolve().parent.parent / "preview"
html = (preview / "index.html").read_text()
html = html.replace('<link rel="stylesheet" href="style.css">',
                    '<style>\n' + (preview / "style.css").read_text() + '\n</style>')
# Store the original image bytes exactly once. App startup assigns the shared URI
# to the wordmark, favicon, navigation, and hero without duplicating it in this file.
logo_uri = "data:image/png;base64," + base64.b64encode((preview / "logo.png").read_bytes()).decode("ascii")
html = html.replace('src="logo.png"', 'data-bundled-logo')
html = html.replace('href="logo.png"', 'data-bundled-logo')
html = html.replace('<script src="model.js"></script>',
                    '<script>window.HARNESS_LOGO_SOURCE="' + logo_uri + '";</script>\n'
                    '<script>\n' + (preview / "model.js").read_text() + '\n</script>')
html = html.replace('<script src="app.js"></script>',
                    '<script>\n' + (preview / "app.js").read_text() + '\n</script>')
(preview / "harness-preview.html").write_text(html)
print("Built preview/harness-preview.html (full approved logo embedded once)")
