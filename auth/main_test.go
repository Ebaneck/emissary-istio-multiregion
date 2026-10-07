package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestExtAuthUnauthorizedWithoutToken(t *testing.T) {
	s := &Server{jwtSecret: []byte("test-secret")}
	req := httptest.NewRequest(http.MethodGet, "/boards/", nil)
	rr := httptest.NewRecorder()
	s.handleExtAuth(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rr.Code)
	}
}

func TestExtAuthBypassesLogin(t *testing.T) {
	s := &Server{jwtSecret: []byte("test-secret")}
	req := httptest.NewRequest(http.MethodPost, "/login", nil)
	req.Header.Set("X-Original-URL", "http://x/login")
	rr := httptest.NewRecorder()
	s.handleExtAuth(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("got %d", rr.Code)
	}
}

func TestExtAuthSetsRegionHeaders(t *testing.T) {
	secret := []byte("test-secret")
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub":    "alice",
		"region": "us",
		"exp":    time.Now().Add(time.Hour).Unix(),
	})
	signed, err := tok.SignedString(secret)
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{jwtSecret: secret}
	req := httptest.NewRequest(http.MethodGet, "/boards/", nil)
	req.Header.Set("Authorization", "Bearer "+signed)
	rr := httptest.NewRecorder()
	s.handleExtAuth(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("got %d body=%s", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("x-region-target") != "us" {
		t.Fatalf("region header %q", rr.Header().Get("x-region-target"))
	}
	if rr.Header().Get("x-account-id") != "alice" {
		t.Fatalf("account header %q", rr.Header().Get("x-account-id"))
	}
}

func TestLoginIssuesToken(t *testing.T) {
	s := &Server{
		jwtSecret: []byte("test-secret"),
		lookup: func(email string) (*Account, error) {
			if email == "alice@example.com" {
				return &Account{ID: "alice", Region: "us"}, nil
			}
			return nil, errNotFound
		},
	}
	body, _ := json.Marshal(map[string]string{"email": "alice@example.com"})
	req := httptest.NewRequest(http.MethodPost, "/login", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	s.handleLogin(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("got %d %s", rr.Code, rr.Body.String())
	}
	var resp map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["token"] == "" {
		t.Fatal("empty token")
	}
}
