package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

func main() {
	region := os.Getenv("REGION")
	if region != "us" && region != "eu" {
		log.Fatal("REGION must be us or eu")
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/boards/", boardsHandler(region))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	addr := ":8080"
	if v := os.Getenv("LISTEN_ADDR"); v != "" {
		addr = v
	}
	log.Printf("boards region=%s on %s", region, addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func boardsHandler(region string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		acct := r.Header.Get("x-account-id")
		target := r.Header.Get("x-region-target")
		if acct == "" || target == "" {
			http.Error(w, "missing auth headers", http.StatusUnauthorized)
			return
		}
		if target != region {
			http.Error(w, "wrong region", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"region":  region,
			"account": acct,
			"message": "board data for " + acct + " served from " + region,
		})
	}
}
