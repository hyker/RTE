package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ============================================================================
// Types and Interfaces
// ============================================================================

// Tool represents a tool in the test suite
type Tool struct {
	ToolName   string      `json:"tool_name"`
	Parameters []Parameter `json:"parameters"`
}

// Parameter represents a tool parameter
type Parameter struct {
	ParamName string      `json:"param_name"`
	Optional  *string     `json:"optional,omitempty"` // omitempty enables serialization without this value by setting it to nil
	Value     interface{} `json:"value"`
}

// ToolRunner interface for tools to execute, allowing separate logic for each tool
type ToolRunner interface {
	Run(inputPath string) (string, error)
	Name() string
}

// ============================================================================
// Tool Runner Implementations
// ============================================================================

// CppCheckRunner runs cppcheck analysis
type CppCheckRunner struct {
	Tool
}

func NewCppCheckRunner(tool Tool) ToolRunner {
	return &CppCheckRunner{Tool: tool}
}

func (runner *CppCheckRunner) Run(inputPath string) (string, error) {
	args := []string{inputPath}
	params := parametersToStringArray(runner.Tool.Parameters)
	args = append(args, params...)
	cmd := exec.Command("cppcheck", args...)
	return runCmd(cmd)
}

func (c *CppCheckRunner) Name() string {
	return c.Tool.ToolName
}

// ChecksecRunner runs checksec analysis
type ChecksecRunner struct {
	Tool
}

func NewChecksecRunner(tool Tool) ToolRunner {
	return &ChecksecRunner{Tool: tool}
}

func (runner *ChecksecRunner) Run(inputPath string) (string, error) {
	// New checksec Go version uses: checksec file <filename> [flags]
	args := []string{"file", inputPath, "--output=csv"}
	params := parametersToStringArray(runner.Tool.Parameters)
	args = append(args, params...)
	cmd := exec.Command("/opt/custodes/tools/checksec/checksec", args...)
	return runCmd(cmd)
}

func (c *ChecksecRunner) Name() string {
	return c.Tool.ToolName
}

// DependencyCheckRunner runs OWASP dependency-check analysis
type DependencyCheckRunner struct {
	Tool
}

func NewDependencyCheckRunner(tool Tool) ToolRunner {
	return &DependencyCheckRunner{Tool: tool}
}

func (runner *DependencyCheckRunner) Run(inputPath string) (string, error) {
	// dependency-check needs proper file extensions to identify file types
	// Extract the file-type parameter to determine the extension
	fileType := "jar" // default to jar for backwards compatibility
	for _, param := range runner.Tool.Parameters {
		if param.ParamName == "--file-type=" {
			if fileTypeValue, ok := param.Value.(string); ok {
				fileType = fileTypeValue
			}
		}
	}

	// Create a copy with the appropriate extension so it can be analyzed
	filePath := inputPath + "." + fileType
	inputData, err := os.ReadFile(inputPath)
	if err != nil {
		return "", errors.New("failed to read input: " + err.Error())
	}
	err = os.WriteFile(filePath, inputData, 0644)
	if err != nil {
		return "", errors.New("failed to create file copy: " + err.Error())
	}
	defer os.Remove(filePath)

	// Extract format parameter to determine output filename
	format := "json" // default format
	for _, param := range runner.Tool.Parameters {
		if param.ParamName == "--format=" {
			if formatValue, ok := param.Value.(string); ok {
				format = strings.ToLower(formatValue)
			}
		}
	}

	outputDir := filepath.Dir(inputPath)
	args := []string{"--scan", filePath, "-o", outputDir, "--prettyPrint", "--data", "/var/tmp/custodes/dependency-check-data"}

	// Filter out --file-type parameter as it's only used internally
	// If --format is not provided, add it with default JSON value
	hasFormatParam := false
	var filteredParams []Parameter
	for _, param := range runner.Tool.Parameters {
		if param.ParamName == "--format=" {
			hasFormatParam = true
			filteredParams = append(filteredParams, param)
		} else if param.ParamName != "--file-type=" {
			filteredParams = append(filteredParams, param)
		}
	}

	// Add default format if not provided
	if !hasFormatParam {
		filteredParams = append(filteredParams, Parameter{
			ParamName: "--format=",
			Value:     "JSON",
		})
	}

	params := parametersToStringArray(filteredParams)
	args = append(args, params...)
	cmd := exec.Command("/opt/custodes/tools/dependency-check/bin/dependency-check.sh", args...)

	// Run the command
	_, err = runCmd(cmd)
	if err != nil {
		return "", err
	}

	// dependency-check writes to "dependency-check-report.<ext>" based on format
	reportFilename := "dependency-check-report." + format
	reportPath := filepath.Join(outputDir, reportFilename)
	reportContent, err := os.ReadFile(reportPath)
	if err != nil {
		return "", errors.New("failed to read report: " + err.Error())
	}

	// Clean up the generated file
	os.Remove(reportPath)

	// If format is JSON, return as-is. Otherwise, wrap in JSON structure
	if format == "json" {
		return string(reportContent), nil
	}

	// For non-JSON formats, wrap the content in a JSON object
	type ReportWrapper struct {
		Format  string `json:"format"`
		Content string `json:"content"`
	}
	wrapper := ReportWrapper{
		Format:  format,
		Content: string(reportContent),
	}
	wrappedJSON, err := json.Marshal(wrapper)
	if err != nil {
		return "", errors.New("failed to wrap report in JSON: " + err.Error())
	}

	return string(wrappedJSON), nil
}

func (c *DependencyCheckRunner) Name() string {
	return c.Tool.ToolName
}

// BinwalkRunner runs binwalk firmware analysis
type BinwalkRunner struct {
	Tool
}

func NewBinwalkRunner(tool Tool) ToolRunner {
	return &BinwalkRunner{Tool: tool}
}

func (runner *BinwalkRunner) Run(inputPath string) (string, error) {
	args := []string{inputPath}
	params := parametersToStringArray(runner.Tool.Parameters)
	args = append(args, params...)
	cmd := exec.Command("binwalk", args...)
	// binwalk v2 requires a writable user config dir (~/.config/binwalk/magic/).
	// On a read-only root (dm-verity) this doesn't exist and binwalk silently
	// produces no output. Point XDG_CONFIG_HOME at writable tmpfs instead.
	cmd.Env = append(os.Environ(), "XDG_CONFIG_HOME=/tmp/binwalk")
	return runCmd(cmd)
}

func (c *BinwalkRunner) Name() string {
	return c.Tool.ToolName
}

// AESKeyFinderRunner runs aeskeyfind analysis
type AESKeyFinderRunner struct {
	Tool
}

func NewAESKeyFinderRunner(tool Tool) ToolRunner {
	return &AESKeyFinderRunner{Tool: tool}
}

func (runner *AESKeyFinderRunner) Run(inputPath string) (string, error) {
	args := []string{}
	params := parametersToStringArray(runner.Tool.Parameters)
	args = append(args, params...)
	args = append(args, inputPath)
	cmd := exec.Command("/opt/custodes/tools/aeskeyfind/aeskeyfind", args...)
	return runCmd(cmd)
}

func (c *AESKeyFinderRunner) Name() string {
	return c.Tool.ToolName
}

// ============================================================================
// Utility Functions
// ============================================================================

// runCmd executes a command and returns combined stdout/stderr output
func runCmd(cmd *exec.Cmd) (string, error) {
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	stdString := string(stdout.Bytes())
	errString := string(stderr.Bytes())

	if err != nil {
		return "", errors.New(errString)
	}

	result := "stdout: " + stdString + " errout: " + errString
	resStringClean := strings.ReplaceAll(result, "\n", "")

	// Properly escape the string for JSON
	jsonBytes, err := json.Marshal(resStringClean)
	if err != nil {
		return "", fmt.Errorf("failed to marshal output: %w", err)
	}
	return string(jsonBytes), nil
}

// parametersToStringArray converts Parameters to command-line argument strings
func parametersToStringArray(params []Parameter) []string {
	var output []string
	for _, param := range params {
		entry := param.ParamName
		value, ok := param.Value.(string)
		if ok {
			entry = entry + value
		}
		output = append(output, entry)
	}
	return output
}

// ============================================================================
// Tool Configuration and Validation
// ============================================================================

var optionalTrue = "true"
var optionalFalse = "false"

// allowedTools returns the list of supported tools with their allowed parameters
func allowedTools() []Tool {
	tools := []Tool{}

	// cppcheck configuration
	cppcheck := Tool{
		ToolName:   "cppcheck",
		Parameters: []Parameter{},
	}
	cppcheckEnable := Parameter{
		ParamName: "--enable=",
		Optional:  &optionalTrue,
		Value:     []string{"warning", "style"},
	}
	cppcheckJ := Parameter{
		ParamName: "-j ",
		Optional:  &optionalTrue,
		Value:     []string{"1", "2", "3", "4", "5"},
	}
	cppcheckV := Parameter{
		ParamName: "-v",
		Optional:  &optionalTrue,
		Value:     nil,
	}
	cppcheck.Parameters = append(cppcheck.Parameters, cppcheckEnable, cppcheckJ, cppcheckV)

	// checksec configuration
	checksec := Tool{
		ToolName:   "checksec",
		Parameters: []Parameter{},
	}
	checksecNoBanner := Parameter{
		ParamName: "--no-banner",
		Optional:  &optionalTrue,
		Value:     nil,
	}
	checksecNoHeaders := Parameter{
		ParamName: "--no-headers",
		Optional:  &optionalTrue,
		Value:     nil,
	}
	checksec.Parameters = append(checksec.Parameters, checksecNoBanner, checksecNoHeaders)

	// dependency-check configuration
	dependencyCheck := Tool{
		ToolName:   "dependency-check",
		Parameters: []Parameter{},
	}
	depCheckFormat := Parameter{
		ParamName: "--format=",
		Optional:  &optionalTrue,
		Value:     []string{"HTML", "XML", "JSON", "CSV", "JUNIT", "SARIF"},
	}
	depCheckFileType := Parameter{
		ParamName: "--file-type=",
		Optional:  &optionalFalse,
		Value:     []string{"jar", "war", "ear", "zip", "sar", "apk", "nupkg", "tar", "gz", "tgz", "bz2", "tbz2", "rpm"},
	}
	dependencyCheck.Parameters = append(dependencyCheck.Parameters, depCheckFormat, depCheckFileType)

	// binwalk configuration
	binwalk := Tool{
		ToolName:   "binwalk",
		Parameters: []Parameter{},
	}
	binwalkEntropy := Parameter{
		ParamName: "-E",
		Optional:  &optionalTrue,
		Value:     nil,
	}
	binwalk.Parameters = append(binwalk.Parameters, binwalkEntropy)

	// aeskeyfind configuration
	aeskeyfind := Tool{
		ToolName:   "aeskeyfind",
		Parameters: []Parameter{},
	}
	aeskeyfindVerbose := Parameter{
		ParamName: "-v",
		Optional:  &optionalTrue,
		Value:     nil,
	}
	aeskeyfindQuiet := Parameter{
		ParamName: "-q",
		Optional:  &optionalTrue,
		Value:     nil,
	}
	aeskeyfindThreshold := Parameter{
		ParamName: "-t ",
		Optional:  &optionalTrue,
		Value:     []string{"0", "1", "2", "5", "10", "15", "20"},
	}
	aeskeyfind.Parameters = append(aeskeyfind.Parameters, aeskeyfindVerbose, aeskeyfindQuiet, aeskeyfindThreshold)

	tools = append(tools, cppcheck, checksec, dependencyCheck, binwalk, aeskeyfind)

	return tools
}

// toolIsAllowed validates if a tool and its parameters are allowed
func toolIsAllowed(toolCandidate Tool) bool {
	for _, toolAllowed := range allowedTools() {
		if toolAllowed.ToolName == toolCandidate.ToolName {
			// Validate that all provided parameters are allowed
			for _, parameterCandidate := range toolCandidate.Parameters {
				parameterFound := false

				for _, parameterAllowed := range toolAllowed.Parameters {
					if parameterCandidate.ParamName == parameterAllowed.ParamName {
						parameterFound = true

						if !isParameterValueValid(parameterCandidate, parameterAllowed) {
							return false
						}
						break
					}
				}

				if !parameterFound {
					return false
				}
			}

			// Validate that all required parameters are provided
			for _, parameterAllowed := range toolAllowed.Parameters {
				if parameterAllowed.Optional != nil && *parameterAllowed.Optional == "false" {
					// This is a required parameter, check if it's provided
					parameterProvided := false
					for _, parameterCandidate := range toolCandidate.Parameters {
						if parameterCandidate.ParamName == parameterAllowed.ParamName {
							parameterProvided = true
							break
						}
					}
					if !parameterProvided {
						return false
					}
				}
			}

			return true
		}
	}
	return false
}

// isParameterValueValid checks if a parameter value is in the allowed list
func isParameterValueValid(candidate, allowed Parameter) bool {
	if allowed.Value == nil {
		return candidate.Value == nil
	}

	switch allowedValues := allowed.Value.(type) {
	case []string:
		candidateStr, ok := candidate.Value.(string)
		if !ok {
			return false
		}
		for _, allowedValue := range allowedValues {
			if candidateStr == allowedValue {
				return true
			}
		}
		return false
	case string:
		candidateStr, ok := candidate.Value.(string)
		if !ok {
			return false
		}
		return candidateStr == allowedValues
	default:
		return false
	}
}

// ============================================================================
// HTTP Handlers
// ============================================================================

// toolsHandler returns the list of allowed tools
func toolsHandler(w http.ResponseWriter, r *http.Request) {
	response := allowedTools()
	if err := json.NewEncoder(w).Encode(response); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
}
