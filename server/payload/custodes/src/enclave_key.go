package main

import (
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/hex"
	"log"
)

var signingKey *ecdsa.PrivateKey

func init() {
	var err error
	signingKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatalf("Failed to generate enclave signing keypair: %v", err)
	}
	log.Printf("Generated P256 enclave signing keypair")
}

// GetPublicKeyHex returns the public key X||Y coordinates as hex (64 bytes = 128 hex chars).
// Format: raw P-256 coordinates, zero-padded to 32 bytes each, no 0x04 prefix.
// Used to fit the 64-byte TDX quote reportdata field.
func GetPublicKeyHex() string {
	x := signingKey.PublicKey.X.Bytes()
	y := signingKey.PublicKey.Y.Bytes()
	coords := make([]byte, 64)
	copy(coords[32-len(x):32], x)
	copy(coords[64-len(y):64], y)
	return hex.EncodeToString(coords)
}

// GetECDHPrivateKey returns the enclave signing key as an *ecdh.PrivateKey for use in
// ECDH key agreement (e.g. decrypting ECIES-encrypted upload payloads).
//
// TODO: the same P-256 key is currently used for both ECDSA result-signing and ECDH
// upload decryption. These should be separated into distinct per-purpose keys in a
// future iteration to follow cryptographic separation-of-concerns principles.
func GetECDHPrivateKey() (*ecdh.PrivateKey, error) {
	return signingKey.ECDH()
}
