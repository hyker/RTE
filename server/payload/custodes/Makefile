.PHONY: build clean

# ALLOWED_REFERRER_ORIGIN is the main-platform origin for the anti-freeloading
# gate (see src/auth.go). It is injected into the binary at build time and read
# from the environment, so build-base.sh can pass the value from build-config.sh.
# Empty (the default) disables the gate.
ALLOWED_REFERRER_ORIGIN ?=

build:
	cd src && CGO_ENABLED=0 go build -o custodes \
		-ldflags="-s -w -X 'main.allowedReferrerOrigin=$(ALLOWED_REFERRER_ORIGIN)'" .
	mv src/custodes custodes

clean:
	rm -f custodes
	rm -f src/custodes
