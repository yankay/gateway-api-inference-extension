// epp-bench: benchmark tool for measuring EPP scheduling latency via ext_proc gRPC.
//
// It sends chat completions requests directly to the EPP's ext_proc endpoint,
// measures the round-trip time from sending the last body chunk to receiving
// the first scheduling response (= EPP processing time ≈ TTFT contribution).
//
// Usage:
//
//	go run main.go -addr localhost:9002 -concurrency 50 -input-chars 4096 -total 500 -duration 60s
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	extprocv3 "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

var (
	addr        = flag.String("addr", "localhost:9002", "EPP ext_proc gRPC address")
	concurrency = flag.Int("concurrency", 50, "Number of concurrent workers")
	inputChars  = flag.Int("input-chars", 4096, "Approx characters in the user message (proxy for token count)")
	total       = flag.Int("total", 500, "Total number of requests to send (0 = use -duration only)")
	duration    = flag.Duration("duration", 60*time.Second, "How long to run (used when -total=0)")
	modelName   = flag.String("model", "bench-model", "Model name in the request")
	metricsAddr = flag.String("metrics", "http://localhost:9090/metrics", "EPP metrics endpoint to dump after run")
	chunkSize   = flag.Int("chunk-size", 16384, "Body chunk size in bytes sent per ext_proc RequestBody message")
	verbose     = flag.Bool("v", false, "Verbose: print per-request timings")
)

// buildChatCompletionsBody builds a minimal OpenAI chat completions JSON body.
// The user message is padded to approximately inputChars characters.
func buildChatCompletionsBody(model string, chars int) []byte {
	const padding = "The quick brown fox jumps over the lazy dog. "
	sb := strings.Builder{}
	for sb.Len() < chars {
		sb.WriteString(padding)
	}
	userContent := sb.String()[:chars]

	type msg struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	}
	type req struct {
		Model     string `json:"model"`
		Messages  []msg  `json:"messages"`
		MaxTokens int    `json:"max_tokens"`
		Stream    bool   `json:"stream"`
	}
	body := req{
		Model: model,
		Messages: []msg{
			{Role: "system", Content: "You are a helpful assistant."},
			{Role: "user", Content: userContent},
		},
		MaxTokens: 128,
		Stream:    false,
	}
	b, _ := json.Marshal(body)
	return b
}

// doRequest sends one full ext_proc exchange and returns the EPP processing duration.
//
// EPP ext_proc flow (from server.go analysis):
//   1. Client sends RequestHeaders  → EPP records, no response yet
//   2. Client sends RequestBody chunks (EndOfStream on last)
//      → EPP runs HandleRequest (parse+schedule)
//      → EPP sends reqHeaderResp  (HeadersResponse with x-went-to-* headers)
//      → EPP sends reqBodyResp    (BodyResponse forwarding the rewritten body)
//      → EPP then blocks on next Recv() waiting for ResponseHeaders from backend
//   3. We CloseSend() immediately after receiving reqBodyResp.
//      EPP's Recv() returns EOF → EPP goroutine exits cleanly.
//
// Timing: start = after last body chunk sent; stop = after reqBodyResp received.
// This measures: body buffering + JSON parse + PrepareData + Schedule + response build.
func doRequest(ctx context.Context, client extprocv3.ExternalProcessorClient, body []byte, model string) (time.Duration, error) {
	stream, err := client.Process(ctx)
	if err != nil {
		return 0, err
	}

	// --- Step 1: Send RequestHeaders ---
	hdrs := &extprocv3.ProcessingRequest{
		Request: &extprocv3.ProcessingRequest_RequestHeaders{
			RequestHeaders: &extprocv3.HttpHeaders{
				Headers: &corev3.HeaderMap{
					Headers: []*corev3.HeaderValue{
						{Key: ":method", RawValue: []byte("POST")},
						{Key: ":path", RawValue: []byte("/v1/chat/completions")},
						{Key: ":authority", RawValue: []byte(model)},
						{Key: ":scheme", RawValue: []byte("http")},
						{Key: "content-type", RawValue: []byte("application/json")},
						{Key: "content-length", RawValue: []byte(fmt.Sprintf("%d", len(body)))},
					},
				},
				EndOfStream: false,
			},
		},
	}
	if err := stream.Send(hdrs); err != nil {
		return 0, fmt.Errorf("send headers: %w", err)
	}

	// --- Step 2: Send RequestBody in chunks, start timer just before last chunk ---
	offset := 0
	cs := *chunkSize
	var start time.Time
	for offset < len(body) {
		end := offset + cs
		if end > len(body) {
			end = len(body)
		}
		eos := end == len(body)
		req := &extprocv3.ProcessingRequest{
			Request: &extprocv3.ProcessingRequest_RequestBody{
				RequestBody: &extprocv3.HttpBody{
					Body:        body[offset:end],
					EndOfStream: eos,
				},
			},
		}
		if eos {
			start = time.Now() // timer starts when we send the last (EOS) chunk
		}
		if err := stream.Send(req); err != nil {
			return 0, fmt.Errorf("send body chunk: %w", err)
		}
		offset = end
	}

	// --- Step 3: Recv responses from EPP ---
	// EPP sends: reqHeaderResp (HeadersResponse) then reqBodyResp (BodyResponse).
	// We drain until we see a BodyResponse, then stop.
	// After CloseSend(), EPP's next Recv() returns EOF and the goroutine exits.
	var elapsed time.Duration
	gotBody := false
	for !gotBody {
		resp, err := stream.Recv()
		if err == io.EOF {
			elapsed = time.Since(start)
			break
		}
		if err != nil {
			elapsed = time.Since(start)
			_ = stream.CloseSend()
			return elapsed, fmt.Errorf("recv: %w", err)
		}
		switch resp.Response.(type) {
		case *extprocv3.ProcessingResponse_RequestBody:
			elapsed = time.Since(start)
			gotBody = true
		case *extprocv3.ProcessingResponse_ImmediateResponse:
			// EPP rejected the request (e.g. no endpoints available)
			elapsed = time.Since(start)
			_ = stream.CloseSend()
			return elapsed, fmt.Errorf("ImmediateResponse (likely no endpoints): %T", resp.Response)
		}
		// RequestHeaders response: continue reading
	}
	_ = stream.CloseSend()
	return elapsed, nil
}

func main() {
	flag.Parse()

	body := buildChatCompletionsBody(*modelName, *inputChars)
	fmt.Printf("=== EPP Benchmark ===\n")
	fmt.Printf("addr=%s concurrency=%d input-chars=%d body-bytes=%d total=%d duration=%s\n",
		*addr, *concurrency, *inputChars, len(body), *total, *duration)
	fmt.Println()

	// Build connection pool (one conn per worker is simplest and avoids HTTP/2 mux overhead)
	conns := make([]*grpc.ClientConn, *concurrency)
	clients := make([]extprocv3.ExternalProcessorClient, *concurrency)
	for i := 0; i < *concurrency; i++ {
		conn, err := grpc.NewClient(*addr,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(64*1024*1024)),
		)
		if err != nil {
			fmt.Fprintf(os.Stderr, "dial: %v\n", err)
			os.Exit(1)
		}
		conns[i] = conn
		clients[i] = extprocv3.NewExternalProcessorClient(conn)
	}
	defer func() {
		for _, c := range conns {
			c.Close()
		}
	}()

	var (
		mu       sync.Mutex
		latencies []time.Duration
		errors   atomic.Int64
		done     atomic.Int64
	)

	ctx, cancel := context.WithTimeout(context.Background(), *duration+30*time.Second)
	defer cancel()

	var wg sync.WaitGroup
	requestCh := make(chan struct{}, *concurrency*2)

	// Producer
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer close(requestCh)
		deadline := time.Now().Add(*duration)
		count := 0
		for {
			if *total > 0 && count >= *total {
				break
			}
			if *total == 0 && time.Now().After(deadline) {
				break
			}
			requestCh <- struct{}{}
			count++
		}
	}()

	// Workers
	for i := 0; i < *concurrency; i++ {
		workerIdx := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			rng := rand.New(rand.NewSource(int64(workerIdx)))
			_ = rng
			client := clients[workerIdx]
			for range requestCh {
				lat, err := doRequest(ctx, client, body, *modelName)
				n := done.Add(1)
				if err != nil {
					errors.Add(1)
					if *verbose {
						fmt.Printf("[%d] ERROR: %v\n", n, err)
					}
					continue
				}
				if *verbose {
					fmt.Printf("[%d] %.2fms\n", n, float64(lat.Microseconds())/1000.0)
				}
				mu.Lock()
				latencies = append(latencies, lat)
				mu.Unlock()
			}
		}()
	}

	// Progress printer
	ticker := time.NewTicker(5 * time.Second)
	go func() {
		for range ticker.C {
			fmt.Printf("  progress: %d done, %d errors\n", done.Load(), errors.Load())
		}
	}()

	wg.Wait()
	ticker.Stop()

	// --- Report ---
	total_ok := int64(len(latencies))
	total_err := errors.Load()
	fmt.Printf("\n=== Results ===\n")
	fmt.Printf("Successful:  %d\n", total_ok)
	fmt.Printf("Errors:      %d\n", total_err)

	if total_ok == 0 {
		fmt.Println("No successful requests.")
		return
	}

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	sum := time.Duration(0)
	for _, l := range latencies {
		sum += l
	}
	mean := sum / time.Duration(total_ok)

	pct := func(p float64) time.Duration {
		idx := int(float64(total_ok-1) * p / 100.0)
		return latencies[idx]
	}

	fmt.Printf("\n--- EPP Processing Time (body-sent → first-response) ---\n")
	fmt.Printf("Mean:        %.2fms\n", ms(mean))
	fmt.Printf("P50:         %.2fms\n", ms(pct(50)))
	fmt.Printf("P90:         %.2fms\n", ms(pct(90)))
	fmt.Printf("P95:         %.2fms\n", ms(pct(95)))
	fmt.Printf("P99:         %.2fms\n", ms(pct(99)))
	fmt.Printf("P99.9:       %.2fms\n", ms(pct(99.9)))
	fmt.Printf("Min:         %.2fms\n", ms(latencies[0]))
	fmt.Printf("Max:         %.2fms\n", ms(latencies[total_ok-1]))

	// --- Fetch and print key metrics from EPP ---
	fmt.Printf("\n--- EPP Prometheus Metrics (key histograms) ---\n")
	resp, err := http.Get(*metricsAddr)
	if err == nil {
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		lines := strings.Split(string(body), "\n")
		keywords := []string{
			"inference_extension_scheduler_e2e_duration_seconds_sum",
			"inference_extension_scheduler_e2e_duration_seconds_count",
			"inference_extension_plugin_duration_seconds_sum",
			"inference_extension_plugin_duration_seconds_count",
			"inference_objective_request_duration_seconds_sum",
			"inference_objective_request_duration_seconds_count",
		}
		for _, line := range lines {
			for _, kw := range keywords {
				if strings.HasPrefix(line, kw) {
					fmt.Println(line)
				}
			}
		}
	} else {
		fmt.Printf("(could not fetch metrics: %v)\n", err)
	}
}

func ms(d time.Duration) float64 {
	return float64(d.Microseconds()) / 1000.0
}
