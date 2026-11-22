package engine

import (
	"bufio"
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Client is the HTTP client extractors and downloads share: cookies,
// default headers, an optional proxy and rate limit.
type Client struct {
	HTTP      *http.Client
	Jar       http.CookieJar
	UserAgent string
	Headers   map[string]string
	// PlaylistLimit caps how many playlist entries extractors list.
	PlaylistLimit int

	limiter *limiter
}

// NewClient builds the client for one extraction and download from the
// options: cookies file, proxy, extra headers, user agent and rate limit.
//
// A missing cookies file is not an error; an unreadable one or a bad
// proxy URL is.
func NewClient(o Options) (*Client, error) {
	jar, _ := cookiejar.New(nil)
	if o.CookiesFile != "" {
		if err := LoadCookies(jar, o.CookiesFile); err != nil && !os.IsNotExist(err) {
			return nil, fmt.Errorf("reading cookies: %w", err)
		}
	}
	tr := &http.Transport{
		Proxy:               http.ProxyFromEnvironment,
		DialContext:         (&net.Dialer{Timeout: 20 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		ForceAttemptHTTP2:   true,
		MaxIdleConnsPerHost: 16,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 15 * time.Second,
		// Responses are decoded by decoded, but Go's transparent gzip
		// stays on for servers that send it unasked.
		DisableCompression: false,
	}
	// An explicit proxy replaces the environment's.
	if o.Proxy != "" {
		u, err := url.Parse(o.Proxy)
		if err != nil {
			return nil, fmt.Errorf("proxy: %w", err)
		}
		tr.Proxy = http.ProxyURL(u)
	}
	c := &Client{
		HTTP:          &http.Client{Transport: tr, Jar: jar},
		Jar:           jar,
		UserAgent:     o.UserAgent,
		Headers:       map[string]string{},
		PlaylistLimit: o.PlaylistLimit,
	}
	if c.UserAgent == "" {
		c.UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
	}
	for k, v := range o.Headers {
		c.Headers[k] = v
	}
	if o.Referer != "" {
		c.Headers["Referer"] = o.Referer
	}
	if o.RateLimit > 0 {
		c.limiter = newLimiter(o.RateLimit)
	}
	return c, nil
}

// Request is one HTTP request. JSON or Form become the body (POST); extra
// headers override the client's.
type Request struct {
	Method  string
	URL     string
	Headers map[string]string
	Body    []byte
	JSON    any
	Form    url.Values
}

// StatusError is a non-2xx response.
type StatusError struct {
	URL    string
	Status int
}

func (e *StatusError) Error() string {
	switch e.Status {
	case 401, 403:
		return "The site refused access (" + strconv.Itoa(e.Status) + "). It may need you to sign in, in Downbit's browser."
	case 404, 410:
		return "Not found (" + strconv.Itoa(e.Status) + "). The link may be wrong or the media removed."
	case 429:
		return "The site asks to slow down (429). Try again later."
	}
	return "The site answered " + strconv.Itoa(e.Status) + " " + http.StatusText(e.Status) + "."
}

// Do sends r with the client's headers, then the request's, then extra.
// Non-2xx responses are drained, closed and returned as *StatusError.
func (c *Client) Do(ctx context.Context, r Request, extra ...map[string]string) (*http.Response, error) {
	var body io.Reader
	var ct string

	if r.JSON != nil {
		b, err := json.Marshal(r.JSON)
		if err != nil {
			return nil, err
		}
		body, ct = bytes.NewReader(b), "application/json"
	} else if r.Form != nil {
		body, ct = strings.NewReader(r.Form.Encode()), "application/x-www-form-urlencoded"
	} else if r.Body != nil {
		body = bytes.NewReader(r.Body)
	}
	method := r.Method
	if method == "" {
		method = "GET"
		if body != nil {
			method = "POST"
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, r.URL, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", c.UserAgent)
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	if ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	for _, h := range append([]map[string]string{c.Headers, r.Headers}, extra...) {
		for k, v := range h {
			req.Header.Set(k, v)
		}
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		resp.Body.Close()
		return nil, &StatusError{URL: r.URL, Status: resp.StatusCode}
	}
	return resp, nil
}

// Bytes reads a whole response body, decoded, up to 64 MiB; larger
// bodies are cut off.
func (c *Client) Bytes(ctx context.Context, r Request) ([]byte, error) {
	resp, err := c.Do(ctx, r)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := decoded(resp)
	if err != nil {
		return nil, err
	}
	defer body.Close()
	return io.ReadAll(io.LimitReader(body, 64<<20))
}


// decoded undoes a Content-Encoding the transport left alone.
func decoded(resp *http.Response) (io.ReadCloser, error) {
	switch strings.ToLower(strings.TrimSpace(resp.Header.Get("Content-Encoding"))) {
	case "gzip", "x-gzip":
		return gzip.NewReader(resp.Body)
	case "deflate":
		// "deflate" is zlib-wrapped by the standard, raw by many
		// servers; a zlib header tells them apart.
		br := bufio.NewReader(resp.Body)
		if b, err := br.Peek(2); err == nil && b[0]&0x0f == 8 && (uint16(b[0])<<8|uint16(b[1]))%31 == 0 {
			return zlib.NewReader(br)
		}
		return flate.NewReader(br), nil
	}
	return io.NopCloser(resp.Body), nil
}

// Text fetches a URL as a string; h are extra headers.
func (c *Client) Text(ctx context.Context, u string, h ...map[string]string) (string, error) {
	var headers map[string]string
	if len(h) > 0 {
		headers = h[0]
	}
	b, err := c.Bytes(ctx, Request{URL: u, Headers: headers})
	return string(b), err
}

// JSON fetches r and decodes the JSON response into v.
func (c *Client) JSON(ctx context.Context, r Request, v any) error {
	b, err := c.Bytes(ctx, r)
	if err != nil {
		return err
	}

	if err := json.Unmarshal(b, v); err != nil {
		return fmt.Errorf("reading %s: %w", hostOf(r.URL), err)
	}
	return nil
}

// WithoutCookies is a copy of the client with an empty cookie jar.
func (c *Client) WithoutCookies() *Client {
	cc := *c
	h := *c.HTTP
	h.Jar = nil
	cc.HTTP = &h
	cc.Jar, _ = cookiejar.New(nil)
	return &cc
}

// Cookie returns the value of the named cookie the jar would send to raw.
func (c *Client) Cookie(raw, name string) string {
	u, err := url.Parse(raw)
	if err != nil || c.Jar == nil {
		return ""
	}
	for _, v := range c.Jar.Cookies(u) {
		if v.Name == name {
			return v.Value
		}
	}
	return ""
}

func hostOf(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	return u.Host
}

// LoadCookies reads a Netscape cookies.txt file into jar.
func LoadCookies(jar http.CookieJar, path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		httpOnly := false
		if strings.HasPrefix(line, "#HttpOnly_") {
			line, httpOnly = line[len("#HttpOnly_"):], true
		}
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 7 {
			continue
		}
		secure := f[3] == "TRUE"
		exp, _ := strconv.ParseInt(f[4], 10, 64)
		ck := &http.Cookie{Name: f[5], Value: f[6], Path: f[2], Secure: secure, HttpOnly: httpOnly}
		if exp > 0 {
			if time.Unix(exp, 0).Before(time.Now()) {
				continue
			}
			ck.Expires = time.Unix(exp, 0)
		}
		domain := strings.TrimPrefix(f[0], ".")
		if strings.HasPrefix(f[0], ".") || f[1] == "TRUE" {
			ck.Domain = domain
		}
		scheme := "http"
		if secure {
			scheme = "https"
		}
		jar.SetCookies(&url.URL{Scheme: scheme, Host: domain, Path: "/"}, []*http.Cookie{ck})
	}
	return sc.Err()
}

// limiter is a token bucket shared by all transfers of a client: rate
// bytes per second, with at most one second of burst.
type limiter struct {
	mu    sync.Mutex
	rate  float64
	avail float64
	last  time.Time
}

func newLimiter(rate int64) *limiter {
	return &limiter{rate: float64(rate), avail: float64(rate), last: time.Now()}
}

func (l *limiter) wait(ctx context.Context, n int) error { // sleeps while the bucket is in debt
	if l == nil {
		return nil
	}
	l.mu.Lock()
	now := time.Now()
	l.avail += now.Sub(l.last).Seconds() * l.rate
	if l.avail > l.rate {
		l.avail = l.rate
	}
	l.last = now
	l.avail -= float64(n)
	var d time.Duration
	if l.avail < 0 {
		d = time.Duration(-l.avail / l.rate * float64(time.Second))
	}
	l.mu.Unlock()
	if d <= 0 {
		return nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// retryable reports whether a failed request is worth repeating.
func retryable(err error) bool {
	if errors.Is(err, context.Canceled) {
		return false
	}
	var se *StatusError
	if errors.As(err, &se) {
		return se.Status == 429 || se.Status >= 500 || se.Status == 408
	}
	return true
}


// IsNetworkError reports whether err looks like a connection problem
// rather than an answer from the site.
func IsNetworkError(err error) bool {
	if errors.Is(err, context.Canceled) {
		return false
	}

	var se *StatusError
	if errors.As(err, &se) {
		return retryable(err)
	}
	var ne net.Error
	var ue *url.Error

	return errors.As(err, &ne) || errors.As(err, &ue) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.EPIPE) ||
		errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.EHOSTUNREACH) || errors.Is(err, syscall.ETIMEDOUT)
}

// IsStaleLink reports a 403 from YouTube's media servers: the signed
// links expired and the media must be extracted again.
func IsStaleLink(err error) bool {
	var se *StatusError
	if !errors.As(err, &se) || se.Status != 403 {
		return false
	}
	u, err := url.Parse(se.URL)
	return err == nil && strings.HasSuffix(u.Hostname(), ".googlevideo.com")
}

func resolve(base, ref string) string {
	b, err := url.Parse(base)
	if err != nil {
		return ref
	}
	r, err := url.Parse(strings.TrimSpace(ref))
	if err != nil {
		return ref
	}
	return b.ResolveReference(r).String()
}
