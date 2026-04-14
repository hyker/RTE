package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

type ResultRequestPayload struct {
	Identifier string `json:"jobID"`
}

func resultHandler(w http.ResponseWriter, r *http.Request) {
	bodyBytes := readReq(w, r)

	var payload ResultRequestPayload

	if err := json.Unmarshal(bodyBytes, &payload); err != nil {
		http.Error(w, fmt.Sprintf("Error parsing JSON: %v", err), http.StatusBadRequest)
		return
	}


	toeDir := "/var/tmp/custodes/toes"
	filePath, err := validateAndCleanPath(payload.Identifier, toeDir)
	if err != nil {
		http.Error(w, fmt.Sprintf("Error %v", err), http.StatusBadRequest)
	}

	_, errRunning := os.Stat(filePath + ".running")
	_, errRes := os.Stat(filePath + ".output")
	_, errErr := os.Stat(filePath + ".failed")
	_, errExpired := os.Stat(filePath + ".expired")

	isRunning := errRunning == nil
	noResults := errRes != nil
	errorOutput := errErr == nil
	isExpired := errExpired == nil

	if isExpired {
		response := map[string]interface{}{
			"jobID":  payload.Identifier,
			"status": "error",
			"reason": "expired",
		}
		json.NewEncoder(w).Encode(response)
		return

	} else if errorOutput {
		response := map[string]interface{}{
			"jobID":  payload.Identifier,
			"status": "error",
			"reason": "processing_failed",
		}
		json.NewEncoder(w).Encode(response)
		cleanupTOE(filePath, false)
		return

	} else if isRunning {
		response := map[string]interface{}{
			"jobID":  payload.Identifier,
			"status": "pending",
		}
		if err := json.NewEncoder(w).Encode(response); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	} else if noResults {
		response := map[string]interface{}{
			"jobID":  payload.Identifier,
			"status": "error",
			"reason": "not_found",
		}
		json.NewEncoder(w).Encode(response)
		return
	} else { // send results
		// read file
		output, err := os.ReadFile(filePath + ".output")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		testSuite, err := os.ReadFile(filePath + ".suite")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		toe, err := os.ReadFile(filePath + ".input")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		var parsedTest Tool
		if err := json.Unmarshal(testSuite, &parsedTest); err != nil {
			http.Error(w, fmt.Sprintf("Error parsing JSON: %v", err), http.StatusBadRequest)
			return
		}



		var parsedOutput interface{}

		if err := json.Unmarshal(output, &parsedOutput); err != nil {
			http.Error(w, fmt.Sprintf("Error parsing JSON: %v", err), http.StatusBadRequest)
			return
		}

		// quote := "DEBUG_QUOTE"
		quote, err := getQuote()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		// The signature is computed over signed_data (a string) rather than
		// over a JSON object, because JSON object key order is unspecified:
		// any verifier that re-serializes a parsed object could produce a
		// different byte string and fail verification. Including signed_data
		// verbatim in the response lets verifiers sign-check the exact bytes.
		// quote_data is intentionally not signed — it self-authenticates via
		// Intel's certificate chain.
		toeHash := hashString(string(toe))
		blob := map[string]interface{}{
			"toe_hash": toeHash,
			"test":     parsedTest,
			"results":  parsedOutput,
		}

		jsonBlobData, err := json.Marshal(blob)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		signedData := string(jsonBlobData)
		signature, err := signString(signedData)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		verifData := map[string]string{
			"signed_data": signedData,
			"signature":   signature,
			"toe_hash":    toeHash,
		}

		

		// NOTE: test, results, and toe_hash are duplicated here — they are
		// already inside signed_data (authoritative, verifiable) and also
		// appear as top-level parsed fields. The duplication exists because
		// the production client reads the top-level fields directly, and we
		// cannot risk breaking it with a shape change. A future cleanup
		// should drop the top-level copies and have the client parse
		// signed_data as the single source of truth after verification.
		response := map[string]interface{}{
			"status":                   "done",
			"test":                     parsedTest,
			"results":                  parsedOutput,
			"quote_data":               quote["quote_data"],
			"crypto_verification_data": verifData,
		}
		if err := json.NewEncoder(w).Encode(response); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		cleanupTOE(filePath, false)
	}
}

func validateAndCleanPath(userPath string, baseDir string) (string, error) {
	// Clean the path to resolve .. and . components
	cleanPath := filepath.Clean(userPath)

	// Convert to absolute path
	absPath, err := filepath.Abs(filepath.Join(baseDir, cleanPath))
	if err != nil {
		return "", fmt.Errorf("invalid path: %v", err)
	}

	// Ensure the final path starts with the base directory
	absBaseDir, err := filepath.Abs(baseDir)
	if err != nil {
		return "", fmt.Errorf("invalid base directory: %v", err)
	}

	if !strings.HasPrefix(absPath, absBaseDir) {
		return "", fmt.Errorf("access denied: path escapes base directory")
	}

	return absPath, nil
}
