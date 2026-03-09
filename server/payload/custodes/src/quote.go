package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
)

func quoteHandler(w http.ResponseWriter, r *http.Request) {
	quote, err := getQuote()
	if err != nil {
		http.Error(w, fmt.Sprintf("Error %v", err), http.StatusBadRequest)
		return
	}

	if err := json.NewEncoder(w).Encode(quote); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
}

func getQuote() (map[string]string, error) {
	reportData := GetPublicKeyHex()
	output, err := exec.Command("/opt/tdx-quote-service/quote-generator", reportData).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("failed to execute quote generator: %w", err)
	}

	// Parse output line by line to find the TDX quote data line
	lines := strings.Split(string(output), "\n")
	var quoteDataStr string
	for _, line := range lines {
		if strings.HasPrefix(line, "TDX quote data:") {
			// Extract the array part after "TDX quote data: "
			quoteDataStr = strings.TrimPrefix(line, "TDX quote data: ")
			break
		}
	}

	if quoteDataStr == "" {
		return nil, fmt.Errorf("TDX quote data not found in output")
	}

	b64Quote, err := quoteBase64Encode(quoteDataStr)
	if err != nil {
		return nil, err
	}

	response := map[string]string{
		"quote_data": b64Quote,
	}

	return response, nil
}

func quoteBase64Encode(stringArray string) (string, error) {
	stringArray = strings.TrimSpace(stringArray)
	if len(stringArray) < 2 || stringArray[0] != '[' || stringArray[len(stringArray)-1] != ']' {
		return "", errors.New("invalid input: expected array format like [1,2,3]")
	}

	content := stringArray[1 : len(stringArray)-1]
	if content == "" {
		return base64.StdEncoding.EncodeToString([]byte{}), nil
	}

	parts := strings.Split(content, ",")
	bytes := make([]byte, 0, len(parts))

	for _, part := range parts {
		num, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil {
			return "", fmt.Errorf("invalid input: could not convert to integer: %v", err)
		}

		if num < 0 || num > 255 {
			return "", errors.New("all integers must be in the range 0-255")
		}

		bytes = append(bytes, byte(num))
	}

	base64Encoded := base64.StdEncoding.EncodeToString(bytes)
	return base64Encoded, nil
}
