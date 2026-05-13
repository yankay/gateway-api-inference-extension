package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var (
	url         = flag.String("url", "http://localhost:30080/v1/completions", "OpenAI completions endpoint")
	host        = flag.String("host", "bench.local", "Host header")
	model       = flag.String("model", "bench-model", "model name")
	concurrency = flag.Int("concurrency", 100, "concurrent requests")
	total       = flag.Int("total", 450, "total requests")
	inputChars  = flag.Int("input-chars", 220000, "prompt size in characters")
	outputLen   = flag.Int("output-len", 128, "max_tokens")
	timeout     = flag.Duration("timeout", 60*time.Second, "per-request timeout")
	stream      = flag.Bool("stream", true, "use streaming responses and measure first byte/chunk")
	metricsURL  = flag.String("metrics", "http://localhost:9090/metrics", "EPP metrics URL")
)

type result struct {
	Latency time.Duration
	TTFT    time.Duration
	Err     error
}

func main() {
	flag.Parse()
	body := buildBody(*model, *inputChars, *outputLen, *stream)
	fmt.Printf("=== HTTP Benchmark ===\n")
	fmt.Printf("url=%s host=%s concurrency=%d total=%d input-chars=%d body-bytes=%d stream=%v\n\n", *url, *host, *concurrency, *total, *inputChars, len(body), *stream)

	client := &http.Client{
		Transport: &http.Transport{
			MaxIdleConns:        *concurrency * 2,
			MaxIdleConnsPerHost: *concurrency * 2,
			MaxConnsPerHost:     *concurrency * 2,
			IdleConnTimeout:     90 * time.Second,
		},
	}

	jobs := make(chan int, *concurrency)
	results := make(chan result, *total)
	var done atomic.Int64

	var wg sync.WaitGroup
	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(int64(worker)))
			_ = rng
			for range jobs {
				ctx, cancel := context.WithTimeout(context.Background(), *timeout)
				res := doRequest(ctx, client, body)
				cancel()
				results <- res
				n := done.Add(1)
				if n%50 == 0 {
					fmt.Printf("  progress: %d/%d\n", n, *total)
				}
			}
		}(i)
	}

	startAll := time.Now()
	go func() {
		for i := 0; i < *total; i++ {
			jobs <- i
		}
		close(jobs)
		wg.Wait()
		close(results)
	}()

	var lats []time.Duration
	var ttfts []time.Duration
	errs := 0
	errorSamples := make(map[string]int)
	for r := range results {
		if r.Err != nil {
			errs++
			if len(errorSamples) < 5 {
				errorSamples[r.Err.Error()]++
			}
			continue
		}
		lats = append(lats, r.Latency)
		ttfts = append(ttfts, r.TTFT)
	}
	durAll := time.Since(startAll)

	fmt.Printf("\n=== Results ===\n")
	fmt.Printf("Successful: %d\n", len(lats))
	fmt.Printf("Errors:     %d\n", errs)
	if len(errorSamples) > 0 {
		fmt.Printf("Error samples:\n")
		for msg, n := range errorSamples {
			fmt.Printf("  [%d] %s\n", n, msg)
		}
	}
	fmt.Printf("Duration:   %.2fs\n", durAll.Seconds())
	if durAll > 0 {
		fmt.Printf("Throughput: %.2f req/s\n", float64(len(lats))/durAll.Seconds())
	}
	printStats("TTFT / first response byte", ttfts)
	printStats("Total request latency", lats)

	fetchKeyMetrics()
}

func buildBody(model string, inputChars, outputLen int, stream bool) []byte {
	const unit = "The quick brown fox jumps over the lazy dog. "
	var sb strings.Builder
	for sb.Len() < inputChars {
		sb.WriteString(unit)
	}
	prompt := sb.String()[:inputChars]
	obj := map[string]any{
		"model":      model,
		"prompt":     prompt,
		"max_tokens": outputLen,
		"stream":     stream,
	}
	b, _ := json.Marshal(obj)
	return b
}

func doRequest(ctx context.Context, client *http.Client, body []byte) result {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, *url, bytes.NewReader(body))
	if err != nil {
		return result{Err: err}
	}
	req.Host = *host
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if *stream {
		req.Header.Set("Accept", "text/event-stream")
	}

	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return result{Err: err}
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return result{Err: fmt.Errorf("status %d: %s", resp.StatusCode, string(b))}
	}

	buf := make([]byte, 1)
	_, err = resp.Body.Read(buf)
	ttft := time.Since(start)
	if err != nil && err != io.EOF {
		return result{TTFT: ttft, Err: err}
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return result{TTFT: ttft, Latency: time.Since(start)}
}

func printStats(name string, xs []time.Duration) {
	if len(xs) == 0 {
		fmt.Printf("\n--- %s ---\n(no data)\n", name)
		return
	}
	sort.Slice(xs, func(i, j int) bool { return xs[i] < xs[j] })
	var sum time.Duration
	for _, x := range xs {
		sum += x
	}
	pct := func(p float64) time.Duration {
		idx := int(float64(len(xs)-1) * p / 100)
		return xs[idx]
	}
	fmt.Printf("\n--- %s ---\n", name)
	fmt.Printf("Mean:  %.2fms\n", ms(sum/time.Duration(len(xs))))
	fmt.Printf("P50:   %.2fms\n", ms(pct(50)))
	fmt.Printf("P90:   %.2fms\n", ms(pct(90)))
	fmt.Printf("P95:   %.2fms\n", ms(pct(95)))
	fmt.Printf("P99:   %.2fms\n", ms(pct(99)))
	fmt.Printf("Min:   %.2fms\n", ms(xs[0]))
	fmt.Printf("Max:   %.2fms\n", ms(xs[len(xs)-1]))
}

func fetchKeyMetrics() {
	resp, err := http.Get(*metricsURL)
	if err != nil {
		fmt.Printf("\nmetrics fetch failed: %v\n", err)
		return
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	fmt.Printf("\n--- Key EPP Metrics ---\n")
	keys := []string{
		"inference_objective_request_duration_seconds_sum",
		"inference_objective_request_duration_seconds_count",
		"inference_extension_scheduler_e2e_duration_seconds_sum",
		"inference_extension_scheduler_e2e_duration_seconds_count",
		"inference_extension_plugin_duration_seconds_sum",
		"inference_extension_plugin_duration_seconds_count",
	}
	for _, line := range strings.Split(string(b), "\n") {
		for _, key := range keys {
			if strings.HasPrefix(line, key) {
				fmt.Println(line)
			}
		}
	}
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }
