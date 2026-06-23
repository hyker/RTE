LE_DOMAIN="custodesrte.xyz"
LE_EMAIL="joakim.brorsson@hyker.se"

# Origin of the main platform that opens the RTE client via window.open(). The
# /upload handler accepts only requests whose forwarded navigation referrer
# matches this origin — a lightweight anti-freeloading gate, not a
# confidentiality control (uploads are end-to-end encrypted to the enclave).
# Injected into the custodes binary at build time (see the custodes Makefile).
# Leave empty to disable the gate.
ALLOWED_REFERRER_ORIGIN="https://custodes.maggioli-research.gr"
