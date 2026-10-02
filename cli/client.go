package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"time"
)

type clientError struct{ msg string }

func (e clientError) Error() string { return e.msg }

type portlyClient struct {
	port int
	http *http.Client
	base string
}

func newClient(port int) *portlyClient {
	if port == 0 {
		if cfg, ok := readConfig(configFile()); ok && cfg.APIPort != 0 {
			port = cfg.APIPort
		} else {
			port = defaultAPIPort
		}
	}
	return &portlyClient{
		port: port,
		http: &http.Client{Timeout: 20 * time.Second},
		base: "http://127.0.0.1:" + strconv.Itoa(port),
	}
}

func (c *portlyClient) reachable(timeout time.Duration) bool {
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get(c.base + "/ping")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == 200
}

func (c *portlyClient) launchDaemonIfNeeded() error {
	if c.reachable(time.Second) {
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return clientError{msg: "Portly is not running and could not be launched."}
	}
	args := []string{"daemon"}
	if c.port != 0 {
		args = append(args, "--api-port", strconv.Itoa(c.port))
	}
	cmd := exec.Command(exe, args...)
	_ = ensureDirs()
	if log, err := os.OpenFile(daemonLogFile(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
		cmd.Stdout = log
		cmd.Stderr = log
	}
	if err := startDetached(cmd); err != nil {
		return clientError{msg: "Portly is not running and could not be launched. " + err.Error()}
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if c.reachable(600 * time.Millisecond) {
			return nil
		}
		time.Sleep(400 * time.Millisecond)
	}
	return clientError{msg: "Portly is not running and could not be launched."}
}

func (c *portlyClient) request(method, path string, body any, dest any, autoLaunch bool) error {
	if autoLaunch {
		if err := c.launchDaemonIfNeeded(); err != nil {
			return err
		}
	}
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, c.base+"/"+path, reader)
	if err != nil {
		return clientError{msg: "Cannot reach Portly: " + err.Error()}
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return clientError{msg: "Cannot reach Portly: " + err.Error()}
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return clientError{msg: "Cannot reach Portly: " + err.Error()}
	}
	var env struct {
		OK    bool            `json:"ok"`
		Data  json.RawMessage `json:"data"`
		Error *string         `json:"error"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		return clientError{msg: "Portly returned a response that could not be parsed."}
	}
	if !env.OK || env.Data == nil {
		msg := "unknown error"
		if env.Error != nil {
			msg = *env.Error
		}
		return clientError{msg: msg}
	}
	if dest == nil {
		return nil
	}
	return json.Unmarshal(env.Data, dest)
}

func (c *portlyClient) get(path string, dest any) error {
	return c.request(http.MethodGet, path, nil, dest, true)
}

func (c *portlyClient) post(path string, body, dest any) error {
	return c.request(http.MethodPost, path, body, dest, true)
}

func emit(value any, asJSON bool, human func() string) {
	if asJSON {
		data, err := encodeJSON(value)
		if err != nil {
			fail(err.Error())
		}
		fmt.Println(string(data))
		return
	}
	fmt.Println(human())
}

func fail(message string) {
	fmt.Fprintln(os.Stderr, "Error: "+message)
	os.Exit(1)
}
