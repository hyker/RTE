package main

import (
	"crypto/tls"
	"log"
	"net/http"
	"os"
)

func init() {
	os.MkdirAll("/var/tmp/custodes/toes", 0755)
	os.MkdirAll("/var/tmp/custodes/dependency-check-data", 0755)
}

func main() {
	tlsCert, err := tls.LoadX509KeyPair(
		"/run/custodes/tls/cert.pem",
		"/run/custodes/tls/key.pem",
	)
	if err != nil {
		log.Fatalf("Failed to load TLS cert: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/quote", quoteHandler)
	mux.HandleFunc("/rtmr2", rtmr2Handler)
	mux.HandleFunc("/tools", toolsHandler)
	mux.HandleFunc("/upload", uploadHandler)
	mux.HandleFunc("/result", resultHandler)

	handler := corsMiddleware(mux)

	server := &http.Server{
		Addr:    ":9000",
		Handler: handler,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{tlsCert},
		},
	}
	startSweeper("/var/tmp/custodes/toes")

	log.Printf("Starting HTTPS server on :9000")
	log.Fatal(server.ListenAndServeTLS("", ""))
}


// CORS middleware to add necessary headers
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Set CORS headers
		w.Header().Set("Access-Control-Allow-Origin", "*") // Allow all origins, or specify your domain
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With")
		w.Header().Set("Access-Control-Max-Age", "3600")
		w.Header().Set("Access-Control-Allow-Private-Network", "true")

		// Handle preflight OPTIONS request
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}

		// Call the next handler
		next.ServeHTTP(w, r)
	})
}
