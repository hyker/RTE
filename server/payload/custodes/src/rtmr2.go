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

// Byte offsets of the TD Quote Body fields, absolute into the v4 quote
// (48-byte quote header followed by the 584-byte TD Report Body).
// See Intel_TDX_DCAP_Quoting_Library_API.pdf, A.3.2.
const (
	offTdAttributes = 168
	offXfam         = 176
	offMrTd         = 184
	offMrConfigId   = 232
	offRtmr0        = 376
	offRtmr1        = 424
	offRtmr2        = 472
	offRtmr3        = 520
	offReportData   = 568
	quoteBodyEnd    = 632
)

// getQuoteBytes runs the quote generator and parses its output into raw bytes.
// reportdata does not affect the RTMRs, so zeros are used.
func getQuoteBytes() ([]byte, error) {
	zeros := strings.Repeat("00", 64)
	output, err := exec.Command("/opt/tdx-quote-service/quote-generator", zeros).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("failed to get quote: %v", err)
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
		return nil, fmt.Errorf("TDX quote data not found")
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

	if len(quoteBytes) < quoteBodyEnd {
		return nil, fmt.Errorf("quote too short: got %d bytes, need at least %d", len(quoteBytes), quoteBodyEnd)
	}

	return quoteBytes, nil
}

// rtmr2Handler reports RTMR2 alone. Kept for compatibility: record-rtmr2.sh and
// the README both reference /rtmr2.
func rtmr2Handler(w http.ResponseWriter, r *http.Request) {
	quoteBytes, err := getQuoteBytes()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	rtmr2 := quoteBytes[offRtmr2:offRtmr3]

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"rtmr2": hex.EncodeToString(rtmr2)})
}

// measurementsHandler reports the registers the client pins, so the build pipeline
// can cover the whole boot chain rather than RTMR2 alone:
//
//	mrTd         TDVF firmware code                    — pinned, hard fail
//	rtmr0        TDVF config, boot vars, ACPI          — pinned, warning only
//	rtmr1        shim + grubx64.efi + GPT              — pinned, hard fail
//	rtmr2        cmdline / kernel / initrd             — pinned, hard fail
//	rtmr3        nothing should extend it              — must be all zeros
//	tdAttributes carries the TD debug bit              — must have debug clear
func measurementsHandler(w http.ResponseWriter, r *http.Request) {
	quoteBytes, err := getQuoteBytes()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	field := func(start, end int) string {
		return hex.EncodeToString(quoteBytes[start:end])
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"tdAttributes": field(offTdAttributes, offXfam),
		"mrTd":         field(offMrTd, offMrConfigId),
		"rtmr0":        field(offRtmr0, offRtmr1),
		"rtmr1":        field(offRtmr1, offRtmr2),
		"rtmr2":        field(offRtmr2, offRtmr3),
		"rtmr3":        field(offRtmr3, offReportData),
	})
}
