package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
)

type TOE struct {
	Format           string `json:"format"`
	Base64EncodedTOE string `json:"base64_encoded_toe"`
}

// RequestPayload represents the complete JSON structure
type UploadRequestPayload struct {
	TOE       TOE   `json:"toe"`
	Test 			Tool 	`json:"test"`
}

// var allowedTools = []string{"cppcheck"}
func uploadHandler(w http.ResponseWriter, r *http.Request) {
	// working directory
	toeDir := "/var/tmp/custodes/toes"
	bodyBytes := readReq(w, r)

	var payload UploadRequestPayload

	if err := json.Unmarshal(bodyBytes, &payload); err != nil {
		http.Error(w, fmt.Sprintf("Error parsing JSON: %v", err), http.StatusBadRequest)
		return
	}

	if !toolIsAllowed(payload.Test) {
		http.Error(w, fmt.Sprintf("Tool or parameter not allowed."), http.StatusBadRequest)
		return
	}

	// read and store ToE
	decoded, err := base64.StdEncoding.DecodeString(payload.TOE.Base64EncodedTOE)
	if err != nil {
		fmt.Println("Error decoding string:", err)
		return
	}

	reqId, err := storeRequest(decoded, toeDir)
	if err != nil {
		w.Write([]byte("Error:" + err.Error()))
		return
	}

	var runner ToolRunner 

	switch payload.Test.ToolName {
		case "cppcheck":
			runner = NewCppCheckRunner(payload.Test)
		case "checksec":
			runner = NewChecksecRunner(payload.Test)
		case "dependency-check":
			runner = NewDependencyCheckRunner(payload.Test)
		default:
			w.Write([]byte("No such tool exsists"))
			return
	}


	go func() {
			ProcessRequest(runner, reqId, toeDir)
			// TODO, handle errors from tools
			// if err := ProcessRequest(runner, reqId, toeDir); err != nil {
			// http.Error(w, fmt.Sprintf("Error processing %s: %v", toolReq.ToolName, err), http.StatusInternalServerError)
			// return
	}()

	
	// }
	w.Write([]byte("{\"jobID\": \"" + reqId + "\"}\n"))
}

func ProcessRequest(tool ToolRunner, reqId string, toeDir string) error {
	path := filepath.Join(toeDir, reqId)

	// Create running file
	if err := writeToFile(path+".running", []byte("")); err != nil {
		return fmt.Errorf("failed to create running file: %w", err)
	}

	jsonData, err := json.Marshal(tool)
	if err != nil {
		return fmt.Errorf("failed to decode json: %w", err)
	}
	if err := writeToFile(path+".suite", jsonData); err != nil {
		return fmt.Errorf("failed to create running file: %w", err)
	}

	// Run the tool
	output, err := tool.Run(path + ".input")
	if err != nil {
		//write error file
		if err = writeToFile(path+".failed", jsonData); err != nil {
			return fmt.Errorf("failed to run tool: %w", err)
		}
	} else {
		//write output
			if err := writeToFile(path+".output", []byte(output)); err != nil {
				return fmt.Errorf("failed to write output: %w", err)
			}
	}

	// Clean up running file
	if err := os.Remove(path + ".running"); err != nil {
		return fmt.Errorf("failed to remove running file: %w", err)
	}

	return nil
}

func storeRequest(fileContent []byte, toeDir string) (string, error) {
	// make sure that there is a directory to save the request in
	err := os.MkdirAll(toeDir, 0744)
	if err != nil {
		fmt.Println("Error with tmp toe dir", err)
		return "", err
	}

	// Generate random file name
	randString, err := GenerateRandomString(16)
	if err != nil {
		fmt.Println("Error, in file handling (1)", err)
		return "", err
	}

	tmpFileName := filepath.Join(toeDir, randString+".input")

	err = writeToFile(tmpFileName, fileContent)
	if err != nil {
		fmt.Println("Error, in file handling (1)", err)
		return "", err
	}

	return randString, nil
}
