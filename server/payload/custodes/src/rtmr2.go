package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
)

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
