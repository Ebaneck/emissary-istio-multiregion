package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/redis/go-redis/v9"
)

var errNotFound = errors.New("not found")

type Account struct {
	ID     string `json:"id"`
	Region string `json:"region"`
}

type Server struct {
	jwtSecret []byte
	lookup    func(email string) (*Account, error)
	rdb       *redis.Client
}

func main() {
	secret := []byte(envOr("JWT_SECRET", "cano-dev-secret"))
	rdb := redis.NewClient(&redis.Options{Addr: envOr("REDIS_ADDR", "127.0.0.1:6379")})
	s := &Server{
		jwtSecret: secret,
		rdb:       rdb,
		lookup: func(email string) (*Account, error) {
			val, err := rdb.Get(context.Background(), "account:email:"+email).Result()
			if err == redis.Nil {
				return nil, errNotFound
			}
			if err != nil {
				return nil, err
			}
			var a Account
			if err := json.Unmarshal([]byte(val), &a); err != nil {
				return nil, err
			}
			return &a, nil
		},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/login", s.handleLogin)
	mux.HandleFunc("/extauth", s.handleExtAuth)
	mux.HandleFunc("/extauth/", s.handleExtAuth)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	addr := envOr("LISTEN_ADDR", ":8080")
	log.Printf("auth listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	var in struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Email == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	acct, err := s.lookup(in.Email)
	if errors.Is(err, errNotFound) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if err != nil {
		http.Error(w, "redis", http.StatusServiceUnavailable)
		return
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub":    acct.ID,
		"region": acct.Region,
		"exp":    time.Now().Add(2 * time.Hour).Unix(),
	})
	signed, err := tok.SignedString(s.jwtSecret)
	if err != nil {
		http.Error(w, "token", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"token": signed, "region": acct.Region})
}

func (s *Server) handleExtAuth(w http.ResponseWriter, r *http.Request) {
	path := originalPath(r)
	path = strings.TrimPrefix(path, "/extauth")
	if path == "" {
		path = "/"
	}
	if path == "/login" || strings.HasPrefix(path, "/login?") {
		w.WriteHeader(http.StatusOK)
		return
	}
	if path == "/healthz" {
		w.WriteHeader(http.StatusOK)
		return
	}
	authz := r.Header.Get("Authorization")
	if !strings.HasPrefix(authz, "Bearer ") {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	raw := strings.TrimPrefix(authz, "Bearer ")
	parsed, err := jwt.Parse(raw, func(t *jwt.Token) (interface{}, error) {
		if t.Method != jwt.SigningMethodHS256 {
			return nil, fmt.Errorf("alg")
		}
		return s.jwtSecret, nil
	})
	if err != nil || !parsed.Valid {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	sub, _ := claims["sub"].(string)
	region, _ := claims["region"].(string)
	if sub == "" || (region != "us" && region != "eu") {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	w.Header().Set("x-region-target", region)
	w.Header().Set("x-account-id", sub)
	w.WriteHeader(http.StatusOK)
}

func originalPath(r *http.Request) string {
	path := r.URL.Path
	if p := r.Header.Get("X-Original-URL"); p != "" {
		if i := strings.Index(p, "://"); i >= 0 {
			rest := p[i+3:]
			if j := strings.Index(rest, "/"); j >= 0 {
				path = rest[j:]
			}
		} else if strings.HasPrefix(p, "/") {
			path = p
		}
	}
	if p := r.Header.Get(":path"); p != "" {
		path = p
	}
	// Emissary AuthService often forwards path as X-Forwarded-Proto companion headers
	if p := r.Header.Get("X-Envoy-Original-Path"); p != "" {
		path = p
	}
	return path
}
