# PodBay

The public copy of the PodBay short post, served at https://grassyhilltop.github.io/pod-bay/ .

* `index.html`: the post ("I'm sorry, Dave": RLVR-G for natural language manufacturing and physical AI).
* `sim/`: the PodBay simulator, the full 3D cell in the browser.
* `paper/`: the paper draft (PDF).
* `files/`: the notebook, the launcher and the guard code. The code repository and the adapter are private and
  available on request.
* `media/`: the figures and videos. `media/passkey_faceid.webp` is a cut-out of a picture from iPhone Life, "How to Set
  Up iCloud Passkeys" (https://www.iphonelife.com/content/how-to-set-icloud-passkeys), credited on the page.

The pages are static: no server, no cookies and no analytics. The only third-party requests are Google Fonts and
three.js from cdnjs. The operator-key demo makes a real passkey where the browser allows it and checks it in the
page; nothing is sent anywhere.

This repository is generated; edit the source and rebuild rather than editing these files.
