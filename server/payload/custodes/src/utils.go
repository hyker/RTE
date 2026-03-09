package main

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
)

func hashString(m string) string {
	hash := sha256.Sum256([]byte(m))
	base64Encoded := base64.StdEncoding.EncodeToString(hash[:])
	return base64Encoded
	//return string(hash[:])
}

type ECDSASignature struct {
	R, S *big.Int
}

func signString(m string) (string, error) {
	hash := sha256.Sum256([]byte(m))

	r, s, err := ecdsa.Sign(rand.Reader, signingKey, hash[:])
	if err != nil {
		log.Fatalf("Failed to sign message: %v", err)
		return "", err
	}

	signature, err := asn1.Marshal(ECDSASignature{R: r, S: s})
	if err != nil {
		log.Fatalf("Failed to marshal signature: %v", err)
		return "", err
	}

	return base64.StdEncoding.EncodeToString(signature), nil
}

const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

// GenerateRandomString generates a random string of the given length.
func GenerateRandomString(length int) (string, error) {
	result := make([]byte, length)
	for i := range result {
		num, err := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		if err != nil {
			return "", err
		}
		result[i] = charset[num.Int64()]
	}
	return string(result), nil
}

func writeToFile(fileName string, fileContent []byte) error {
	// Open a file
	file, err := os.OpenFile(fileName, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0643)
	if err != nil {
		fmt.Println("Error, in file handling (1)", err)
		return err
	}
	defer file.Close()

	// Write the content as bytes to the file
	_, err = file.Write(fileContent)
	if err != nil {
		fmt.Println("Error, in file handling (2)", err)
		return err
	}

	return nil
}

func readReq(w http.ResponseWriter, r *http.Request) []byte {
	if r.Method != "POST" {
		w.Write([]byte("Error, only POST requests supported."))
		return nil
	}

	// read body
	bodyBytes, err := io.ReadAll(r.Body)
	defer r.Body.Close()
	if err != nil {
		fmt.Println("Unable to read request body", err)
		http.Error(w, "Unable to read request body", http.StatusBadRequest)
		return nil
	}

	return bodyBytes
}
