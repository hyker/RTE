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

	isRunning := errRunning == nil
	noResults := errRes != nil
	errorOutput := errErr == nil

	if errorOutput {

		response := map[string]interface{}{
			"jobID": payload.Identifier,
			"status":     "error",
		}
		if err := json.NewEncoder(w).Encode(response); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

	} else if isRunning {
		// w.Write([]byte("No results ready for request with identifier: " + payload.Identifier + "\n"))
		response := map[string]interface{}{
			"jobID": payload.Identifier,
			"status":     "pending",
		}
		if err := json.NewEncoder(w).Encode(response); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	} else if noResults {
		// http.Error(w, fmt.Sprintf("Error %v", errRes), http.StatusBadRequest)
		w.Write([]byte("No such request: " + payload.Identifier + "\n"))
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

		// sign the results
		blob := map[string]interface{}{
			// "jobID": payload.Identifier,
			"status":     "done",
			// "test": string(testSuite),
			"test": parsedTest,
			"results":    parsedOutput,
			"quote_data": quote["quote_data"],
		}

		jsonBlobData, err := json.Marshal(blob)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonBlobString := string(jsonBlobData)
		signString, err := signString(jsonBlobString)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		verifData := map[string]string{
    	"signature": signString,
			"toe_hash":	hashString(string(toe)),
		}

		

		// put signature with results and retutn them
		response := map[string]interface{}{
			// "jobID":               payload.Identifier,
			"status":                   "done",
			"test": parsedTest,
			// "test":               string(testSuite),
			"results":                  parsedOutput,
			"quote_data":               quote["quote_data"],
			"crypto_verification_data": verifData,
		}
		if err := json.NewEncoder(w).Encode(response); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		// w.Write([]byte("RESULTS_DUMMY"))
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
