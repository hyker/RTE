package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
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

// GetPublicKeyHex returns the public key X||Y coordinates as hex (64 bytes = 128 hex chars)
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

func rtmr2Handler(w http.ResponseWriter, r *http.Request) {
	// Get a quote to extract RTMR2 (reportdata doesn't affect RTMRs)
	zeros := strings.Repeat("00", 64)
	output, err := exec.Command("/opt/tdx-quote-service/quote-generator", zeros).CombinedOutput()
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to get quote: %v", err), http.StatusInternalServerError)
		return
	}

	// Parse the quote bytes
	lines := strings.Split(string(output), "\n")
	var quoteDataStr string
	for _, line := range lines {
		if strings.HasPrefix(line, "TDX quote data:") {
			quoteDataStr = strings.TrimPrefix(line, "TDX quote data: ")
			break
		}
	}

	if quoteDataStr == "" {
		http.Error(w, "TDX quote data not found", http.StatusInternalServerError)
		return
	}

	// Parse byte array string "[1, 2, 3, ...]"
	quoteDataStr = strings.TrimSpace(quoteDataStr)
	content := quoteDataStr[1 : len(quoteDataStr)-1]
	parts := strings.Split(content, ",")
	quoteBytes := make([]byte, len(parts))
	for i, part := range parts {
		num, _ := strconv.Atoi(strings.TrimSpace(part))
		quoteBytes[i] = byte(num)
	}

	// RTMR2 is at offset 472-520 in the quote (48-byte header + 424 offset in TD Report Body)
	const rtmr2Start = 472
	const rtmr2End = 520
	if len(quoteBytes) < rtmr2End {
		http.Error(w, "Quote too short to contain RTMR2", http.StatusInternalServerError)
		return
	}

	rtmr2 := quoteBytes[rtmr2Start:rtmr2End]

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"rtmr2": hex.EncodeToString(rtmr2)})
}
