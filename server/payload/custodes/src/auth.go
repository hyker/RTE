package main

import "strings"

// allowedReferrerOrigin is the origin of the main platform — the page that opens
// this client via window.open(). It is injected at build time via -ldflags from
// ALLOWED_REFERRER_ORIGIN in server/build-config.sh (see the Makefile), so it is
// baked into the measured image rather than hardcoded here. An empty value
// disables the gate, which is the default for a plain `go build` (local testing
// and direct curl against /upload).
//
// This is a lightweight gate, and that is sufficient here: it only guards against
// freeloading — using the metered compute without going through the main platform.
// It is deliberately not a confidentiality control. Uploads are end-to-end
// encrypted to the attested enclave, so this check never protects user data, only
// access. A legitimate upload carries the platform's origin as its navigation
// referrer, forwarded by the browser client as the request's "referrer" field.
var allowedReferrerOrigin = ""

// refererAllowed reports whether the forwarded navigation referrer indicates the
// request originated from the main platform. document.referrer may be the bare
// origin (often with a trailing slash) or a full URL, so we accept the origin
// itself and anything under its path.
func refererAllowed(referrer string) bool {
	if allowedReferrerOrigin == "" {
		return true // gate disabled
	}
	return referrer == allowedReferrerOrigin ||
		strings.HasPrefix(referrer, allowedReferrerOrigin+"/")
}
