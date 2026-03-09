.PHONY: build clean

build:
	cd src && CGO_ENABLED=0 go build -o custodes -ldflags="-s -w" .
	mv src/custodes custodes

clean:
	rm -f custodes
	rm -f src/custodes
