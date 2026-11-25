package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestObjectStorageStreamOutlivesMetadataBudget(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "6")
		_, _ = w.Write([]byte("abc"))
		w.(http.Flusher).Flush()
		time.Sleep(120 * time.Millisecond)
		_, _ = w.Write([]byte("def"))
	}))
	defer upstream.Close()
	cfg := testStorageConfig(t, "s3")
	cfg.Endpoint = upstream.URL
	cfg.UploadTimeoutSeconds = 1
	store := newObjectStorage(cfg)
	store.client.Timeout = 40 * time.Millisecond
	object, err := store.openRemote(t.Context(), "cloud/test.amproj")
	if err != nil {
		t.Fatal(err)
	}
	defer object.Body.Close()
	data, err := io.ReadAll(object.Body)
	if err != nil || string(data) != "abcdef" || object.Size != 6 {
		t.Fatalf("stream was truncated by metadata timeout: size=%d data=%q err=%v", object.Size, data, err)
	}
	if store.client.Timeout != 40*time.Millisecond {
		t.Fatal("stream download changed shared metadata client timeout")
	}
}

func TestObjectStorageStreamHonorsCallerCancellation(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "6")
		_, _ = w.Write([]byte("abc"))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer upstream.Close()
	cfg := testStorageConfig(t, "s3")
	cfg.Endpoint = upstream.URL
	store := newObjectStorage(cfg)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	object, err := store.openRemote(ctx, "cloud/test.amproj")
	if err != nil {
		t.Fatal(err)
	}
	defer object.Body.Close()
	cancel()
	_, err = io.ReadAll(object.Body)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("caller cancellation not honored: %v", err)
	}
}

func TestObjectStorageStreamKeepsResponseHeaderDeadline(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer upstream.Close()
	cfg := testStorageConfig(t, "s3")
	cfg.Endpoint = upstream.URL
	cfg.RequestTimeoutSeconds = 1
	store := newObjectStorage(cfg)
	transport := store.client.Transport.(*http.Transport)
	if transport.ResponseHeaderTimeout != time.Second {
		t.Fatalf("header deadline not configured: %s", transport.ResponseHeaderTimeout)
	}
	transport.ResponseHeaderTimeout = 40 * time.Millisecond
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	started := time.Now()
	_, err := store.openRemote(ctx, "cloud/test.amproj")
	if err == nil || time.Since(started) >= 500*time.Millisecond {
		t.Fatalf("response header wait escaped short deadline: %v", err)
	}
}

func TestObjectStorageStreamKeepsFiniteTransferDeadline(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "6")
		_, _ = w.Write([]byte("abc"))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer upstream.Close()
	cfg := testStorageConfig(t, "s3")
	cfg.Endpoint = upstream.URL
	cfg.UploadTimeoutSeconds = 1
	store := newObjectStorage(cfg)
	object, err := store.openRemote(t.Context(), "cloud/test.amproj")
	if err != nil {
		t.Fatal(err)
	}
	defer object.Body.Close()
	_, err = io.ReadAll(object.Body)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("transfer timeout not honored: %v", err)
	}
}
