package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBoardsSameRegion(t *testing.T) {
	h := boardsHandler("us")
	req := httptest.NewRequest(http.MethodGet, "/boards/", nil)
	req.Header.Set("x-account-id", "alice")
	req.Header.Set("x-region-target", "us")
	rr := httptest.NewRecorder()
	h(rr, req)
	if rr.Code != 200 {
		t.Fatalf("%d", rr.Code)
	}
	var body map[string]string
	_ = json.Unmarshal(rr.Body.Bytes(), &body)
	if body["region"] != "us" || body["account"] != "alice" {
		t.Fatalf("%v", body)
	}
}

func TestBoardsCrossRegionForbidden(t *testing.T) {
	h := boardsHandler("us")
	req := httptest.NewRequest(http.MethodGet, "/boards/", nil)
	req.Header.Set("x-account-id", "bruno")
	req.Header.Set("x-region-target", "eu")
	rr := httptest.NewRecorder()
	h(rr, req)
	if rr.Code != http.StatusForbidden {
		t.Fatalf("%d", rr.Code)
	}
}
