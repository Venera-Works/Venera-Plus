package openlistcore

import (
	"context"
	"encoding/json"
	"testing"
)

func TestCancelBeforeTaskRegistration(t *testing.T) {
	core := &core{tasks: map[string]*taskState{}, pendingCancels: map[string]struct{}{}}
	if _, err := core.taskOperation("cancel", "cancelled-before-start", "account-a"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := core.contextFor("cancelled-before-start", "account-a")
	defer cancel()
	if ctx.Err() != context.Canceled {
		t.Fatalf("early cancellation was not applied: %v", ctx.Err())
	}
	other, cancelOther := core.contextFor("unrelated-task", "account-a")
	defer cancelOther()
	if other.Err() != nil {
		t.Fatalf("early cancellation affected another task: %v", other.Err())
	}
	core.finishTask("cancelled-before-start", "")
	if _, err := core.taskOperation("releaseTask", "cancelled-before-start", ""); err != nil {
		t.Fatal(err)
	}

	if _, err := core.taskOperation("cancel", "released-before-start", "account-a"); err != nil {
		t.Fatal(err)
	}
	if _, err := core.taskOperation("releaseTask", "released-before-start", ""); err != nil {
		t.Fatal(err)
	}
	fresh, cancelFresh := core.contextFor("released-before-start", "account-a")
	defer cancelFresh()
	if fresh.Err() != nil {
		t.Fatalf("release did not clear pending cancellation: %v", fresh.Err())
	}
	core.finishTask("unrelated-task", "")
	core.finishTask("released-before-start", "")
	if _, err := core.taskOperation("releaseTask", "unrelated-task", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := core.taskOperation("releaseTask", "released-before-start", ""); err != nil {
		t.Fatal(err)
	}

	core.tasksMu.RLock()
	pending := len(core.pendingCancels)
	tasks := len(core.tasks)
	core.tasksMu.RUnlock()
	if pending != 0 {
		t.Fatalf("pending cancellations leaked: %d", pending)
	}
	if tasks != 0 {
		t.Fatalf("released tasks leaked: %d", tasks)
	}
}

func TestNormalizeAdditionKeepsValuesAndAddsDefaults(t *testing.T) {
	addition, err := normalizeAddition("QuarkOpen", json.RawMessage(`{"app_id":"app","sign_key":"secret"}`))
	if err != nil {
		t.Fatal(err)
	}
	var values map[string]any
	if err := json.Unmarshal([]byte(addition), &values); err != nil {
		t.Fatal(err)
	}
	if values["app_id"] != "app" || values["sign_key"] != "secret" {
		t.Fatalf("authorization values changed: %#v", values)
	}
	if values["root_folder_id"] != "0" || values["use_online_api"] != true {
		t.Fatalf("missing Quark defaults: %#v", values)
	}
}

func TestInvokeInitializeCloseAndReopen(t *testing.T) {
	directory := t.TempDir()
	initializeRequest := func(dataDir string) string {
		arguments, err := json.Marshal(map[string]string{"dataDir": dataDir, "proxy": ""})
		if err != nil {
			t.Fatal(err)
		}
		raw, err := json.Marshal(request{Method: "initialize", Arguments: arguments})
		if err != nil {
			t.Fatal(err)
		}
		return string(raw)
	}
	assertRequestRoundTrip := func(dataDir string) {
		var decoded request
		if err := json.Unmarshal([]byte(initializeRequest(dataDir)), &decoded); err != nil {
			t.Fatal(err)
		}
		var arguments struct {
			DataDir string `json:"dataDir"`
		}
		if err := json.Unmarshal(decoded.Arguments, &arguments); err != nil {
			t.Fatal(err)
		}
		if arguments.DataDir != dataDir {
			t.Fatalf("data directory changed during JSON encoding: %q", arguments.DataDir)
		}
	}
	assertRequestRoundTrip(`C:\\OpenList\\quoted"directory`)
	initialize := func() map[string]any {
		raw := Invoke(initializeRequest(directory))
		var response response
		if err := json.Unmarshal([]byte(raw), &response); err != nil {
			t.Fatal(err)
		}
		if response.Error != nil {
			t.Fatalf("initialize failed: %#v", response.Error)
		}
		return response.Data.(map[string]any)
	}
	if initialize()["ready"] != true {
		t.Fatal("initialize did not report ready")
	}
	if raw := Invoke(`{"method":"accounts","arguments":{}}`); raw == "" {
		t.Fatal("accounts returned no response")
	}
	if raw := Invoke(`{"method":"close","arguments":{}}`); raw == "" {
		t.Fatal("close returned no response")
	}
	if initialize()["ready"] != true {
		t.Fatal("reopen did not report ready")
	}
	Invoke(`{"method":"close","arguments":{}}`)
}
