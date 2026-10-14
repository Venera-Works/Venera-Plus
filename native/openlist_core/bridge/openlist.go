// Package openlistcore embeds exactly the six supported OpenList drivers.
package openlistcore

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"regexp"
	"strings"
	"sync"
	"time"

	_ "github.com/OpenListTeam/OpenList/v4/drivers/115_open"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/123_open"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/baidu_netdisk"
	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/google_drive"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/onedrive"
	_ "github.com/OpenListTeam/OpenList/v4/drivers/quark_open"
	"github.com/OpenListTeam/OpenList/v4/internal/conf"
	"github.com/OpenListTeam/OpenList/v4/internal/db"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/errs"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/OpenListTeam/OpenList/v4/internal/stream"
	"github.com/OpenListTeam/OpenList/v4/pkg/http_range"
	"github.com/OpenListTeam/OpenList/v4/pkg/utils"
	"github.com/glebarez/sqlite"
	log "github.com/sirupsen/logrus"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
	"gorm.io/gorm/schema"
)

const accountPrefix = "venera-account:"

var allowedDrivers = map[string]struct{}{
	"BaiduNetdisk": {}, "QuarkOpen": {}, "115 Open": {}, "123 Open": {},
	"Onedrive": {}, "GoogleDrive": {},
}

type request struct {
	Method    string          `json:"method"`
	Arguments json.RawMessage `json:"arguments"`
}
type response struct {
	Data  any       `json:"data,omitempty"`
	Error *rpcError `json:"error,omitempty"`
}
type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
type fileArguments struct {
	AccountID string            `json:"accountId"`
	Path      string            `json:"path"`
	Headers   map[string]string `json:"headers"`
	Content   string            `json:"content"`
	LocalPath string            `json:"localPath"`
	TaskID    string            `json:"taskId"`
	Refresh   bool              `json:"refresh"`
}
type taskState struct {
	mu         sync.RWMutex
	cancel     context.CancelFunc
	accountID  string
	done       bool
	completed  int64
	total      int64
	message    string
	err        string
	doneSignal chan struct{}
}
type core struct {
	mu             sync.Mutex
	initialized    bool
	closing        bool
	dataDir        string
	tasksMu        sync.RWMutex
	tasks          map[string]*taskState
	pendingCancels map[string]struct{}
	active         sync.WaitGroup
}

var instance = &core{tasks: map[string]*taskState{}, pendingCancels: map[string]struct{}{}}
var sensitiveValue = regexp.MustCompile(`(?i)((?:access|refresh)[_-]?token|client[_-]?secret|sign[_-]?key|password)([=:])[^\s,;]+`)

// Invoke is the only RPC entry point. It does not log request data.
func Invoke(raw string) (result string) {
	defer func() {
		if recover() != nil {
			result = encode(nil, &rpcError{Code: "internal", Message: "OpenList core operation failed"})
		}
	}()
	var req request
	if err := json.Unmarshal([]byte(raw), &req); err != nil {
		return encode(nil, &rpcError{Code: "invalid_request", Message: "invalid JSON request"})
	}
	if req.Method != "initialize" && req.Method != "close" && !isTaskOperation(req.Method) {
		release, err := instance.acquire()
		if err != nil {
			return encode(nil, errorResponse(err))
		}
		defer release()
	}
	data, err := instance.call(req)
	if err != nil {
		return encode(nil, errorResponse(err))
	}
	return encode(data, nil)
}

func encode(data any, err *rpcError) string {
	value, marshalErr := json.Marshal(response{Data: data, Error: err})
	if marshalErr != nil {
		return `{"error":{"code":"internal","message":"response encoding failed"}}`
	}
	return string(value)
}
func errorResponse(err error) *rpcError {
	code := "operation_failed"
	if errs.IsNotFoundError(err) {
		code = "not_found"
	} else if strings.Contains(strings.ToLower(err.Error()), "status code: 401") || strings.Contains(strings.ToLower(err.Error()), "unauthorized") {
		code = "unauthorized"
	}
	return &rpcError{Code: code, Message: sensitiveValue.ReplaceAllString(err.Error(), "$1$2<redacted>")}
}

func isTaskOperation(method string) bool {
	return method == "cancel" || method == "cancelAll" || method == "cancelAccount" || method == "releaseTask" || method == "taskStatus"
}

func (c *core) call(req request) (any, error) {
	switch req.Method {
	case "initialize":
		var args struct {
			DataDir string `json:"dataDir"`
			Proxy   string `json:"proxy"`
		}
		if err := json.Unmarshal(req.Arguments, &args); err != nil {
			return nil, err
		}
		return c.initialize(args.DataDir, args.Proxy)
	case "close":
		return nil, c.close()
	case "accounts":
		return c.accounts()
	case "saveAccount":
		if !c.ready() {
			return nil, fmt.Errorf("OpenList core is not initialized")
		}
		var args struct {
			ID       string          `json:"id"`
			Driver   string          `json:"driver"`
			Name     string          `json:"name"`
			Addition json.RawMessage `json:"addition"`
		}
		if err := json.Unmarshal(req.Arguments, &args); err != nil {
			return nil, err
		}
		return c.saveAccount(args.ID, args.Driver, args.Name, args.Addition)
	case "deleteAccount":
		if !c.ready() {
			return nil, fmt.Errorf("OpenList core is not initialized")
		}
		var args struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(req.Arguments, &args); err != nil {
			return nil, err
		}
		return nil, c.deleteAccount(args.ID)
	case "cancel", "cancelAll", "cancelAccount", "releaseTask", "taskStatus":
		var args struct {
			TaskID    string `json:"taskId"`
			AccountID string `json:"accountId"`
		}
		if err := json.Unmarshal(req.Arguments, &args); err != nil {
			return nil, err
		}
		return c.taskOperation(req.Method, args.TaskID, args.AccountID)
	default:
		if !c.ready() {
			return nil, fmt.Errorf("OpenList core is not initialized")
		}
		return c.fileOperation(req.Method, req.Arguments)
	}
}

func (c *core) initialize(dataDir, proxy string) (any, error) {
	if strings.TrimSpace(dataDir) == "" {
		return nil, fmt.Errorf("dataDir is required")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closing {
		return nil, fmt.Errorf("OpenList core is closing")
	}
	if c.initialized {
		if c.dataDir == dataDir {
			if conf.Conf.ProxyAddress != strings.TrimSpace(proxy) {
				if base.HttpClient != nil {
					base.HttpClient.CloseIdleConnections()
				}
				conf.Conf.ProxyAddress = strings.TrimSpace(proxy)
				base.InitClient()
			}
			return map[string]any{"ready": true}, nil
		}
		return nil, fmt.Errorf("OpenList core is already initialized for another data directory")
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, err
	}
	conf.Conf = conf.DefaultConfig(dataDir)
	conf.Embedded = true
	conf.Conf.ProxyAddress = strings.TrimSpace(proxy)
	conf.Conf.Log.Enable = false
	log.SetOutput(io.Discard)
	database, err := gorm.Open(sqlite.Open(path.Join(dataDir, "openlist.db")+"?_journal=WAL"), &gorm.Config{
		Logger:         logger.Default.LogMode(logger.Silent),
		NamingStrategy: schema.NamingStrategy{TablePrefix: conf.Conf.Database.TablePrefix},
	})
	if err != nil {
		return nil, fmt.Errorf("open embedded database: %w", err)
	}
	if err := db.InitWithError(database); err != nil {
		if sqlDB, sqlErr := database.DB(); sqlErr == nil {
			_ = sqlDB.Close()
		}
		return nil, fmt.Errorf("initialize embedded database: %w", err)
	}
	base.InitClient()
	storages, err := db.GetEnabledStorages()
	if err != nil {
		db.Close()
		return nil, err
	}
	for _, storage := range storages {
		if strings.HasPrefix(storage.Remark, accountPrefix) {
			if _, ok := allowedDrivers[storage.Driver]; ok {
				_ = op.LoadStorage(context.Background(), storage)
			}
		}
	}
	c.dataDir, c.initialized = dataDir, true
	return map[string]any{"ready": true, "drivers": []string{"BaiduNetdisk", "QuarkOpen", "115 Open", "123 Open", "Onedrive", "GoogleDrive"}}, nil
}

func (c *core) close() error {
	c.mu.Lock()
	if !c.initialized {
		c.mu.Unlock()
		return nil
	}
	if c.closing {
		c.mu.Unlock()
		return nil
	}
	c.closing = true
	c.mu.Unlock()
	c.cancelTasks("", true)
	c.active.Wait()
	c.mu.Lock()
	defer c.mu.Unlock()
	op.ResetEmbeddedStorages(context.Background())
	if base.HttpClient != nil {
		base.HttpClient.CloseIdleConnections()
	}
	if base.RestyClient != nil {
		base.RestyClient.GetClient().CloseIdleConnections()
	}
	if base.NoRedirectClient != nil {
		base.NoRedirectClient.GetClient().CloseIdleConnections()
	}
	db.Close()
	c.initialized, c.closing, c.dataDir = false, false, ""
	return nil
}
func (c *core) ready() bool { c.mu.Lock(); defer c.mu.Unlock(); return c.initialized && !c.closing }
func (c *core) acquire() (func(), error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.initialized || c.closing {
		return nil, fmt.Errorf("OpenList core is not initialized")
	}
	c.active.Add(1)
	return c.active.Done, nil
}
func accountMount(id string) string {
	return "/venera/" + base64.RawURLEncoding.EncodeToString([]byte(id))
}
func accountRemark(id, name string) string { return accountPrefix + id + "\n" + name }
func accountID(storage model.Storage) string {
	return strings.Split(strings.TrimPrefix(storage.Remark, accountPrefix), "\n")[0]
}
func accountName(storage model.Storage) string {
	values := strings.SplitN(strings.TrimPrefix(storage.Remark, accountPrefix), "\n", 2)
	if len(values) == 2 {
		return values[1]
	}
	return ""
}

func (c *core) allAccounts() ([]model.Storage, error) {
	storages, _, err := db.GetStorages(1, 10000)
	if err != nil {
		return nil, err
	}
	result := make([]model.Storage, 0, len(storages))
	for _, storage := range storages {
		if strings.HasPrefix(storage.Remark, accountPrefix) {
			result = append(result, storage)
		}
	}
	return result, nil
}
func (c *core) findAccount(id string) (*model.Storage, error) {
	storages, err := c.allAccounts()
	if err != nil {
		return nil, err
	}
	for index := range storages {
		if accountID(storages[index]) == id {
			return &storages[index], nil
		}
	}
	return nil, fmt.Errorf("account not found")
}

func (c *core) accounts() (any, error) {
	if !c.ready() {
		return nil, fmt.Errorf("OpenList core is not initialized")
	}
	storages, err := c.allAccounts()
	if err != nil {
		return nil, err
	}
	result := make([]map[string]any, 0, len(storages))
	for _, storage := range storages {
		var addition any
		_ = json.Unmarshal([]byte(storage.Addition), &addition)
		result = append(result, map[string]any{"id": accountID(storage), "driver": storage.Driver, "name": accountName(storage), "addition": addition, "status": storage.Status, "disabled": storage.Disabled})
	}
	return map[string]any{"accounts": result}, nil
}

func (c *core) saveAccount(id, driverName, name string, addition json.RawMessage) (any, error) {
	if !c.ready() {
		return nil, fmt.Errorf("OpenList core is not initialized")
	}
	if strings.TrimSpace(id) == "" || strings.TrimSpace(name) == "" {
		return nil, fmt.Errorf("account id and name are required")
	}
	if _, ok := allowedDrivers[driverName]; !ok {
		return nil, fmt.Errorf("unsupported driver")
	}
	if !json.Valid(addition) || string(addition) == "null" {
		return nil, fmt.Errorf("invalid account addition")
	}
	normalized, err := normalizeAddition(driverName, addition)
	if err != nil {
		return nil, err
	}
	if old, findErr := c.findAccount(id); findErr == nil {
		if old.Driver != driverName {
			return nil, fmt.Errorf("account driver cannot be changed")
		}
		c.cancelTasks(id, false)
		c.waitTasks(id)
		old.Remark, old.Addition, old.Disabled = accountRemark(id, name), normalized, false
		if err := op.UpdateStorage(context.Background(), *old); err != nil {
			return nil, err
		}
	} else {
		storage := model.Storage{MountPath: accountMount(id), Driver: driverName, Remark: accountRemark(id, name), Addition: normalized, CacheExpiration: 1}
		if _, err := op.CreateStorage(context.Background(), storage); err != nil {
			return nil, err
		}
	}
	storage, err := c.findAccount(id)
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": id, "driver": storage.Driver, "name": accountName(*storage), "status": storage.Status}, nil
}

func normalizeAddition(driverName string, raw json.RawMessage) (string, error) {
	var values map[string]any
	if err := json.Unmarshal(raw, &values); err != nil {
		return "", err
	}
	if values == nil {
		return "", fmt.Errorf("account addition must be an object")
	}
	defaults := map[string]map[string]any{
		"BaiduNetdisk": {"root_folder_path": "/", "download_api": "official", "use_online_api": true, "api_url_address": "https://api.oplist.org/baiduyun/renewapi", "upload_thread": "3"},
		"QuarkOpen":    {"root_folder_id": "0", "use_online_api": true, "api_url_address": "https://api.oplist.org/quarkyun/renewapi"},
		"115 Open":     {"root_folder_id": "0", "limit_rate": 1.0, "page_size": 200},
		"123 Open":     {"root_folder_id": "0", "use_online_api": true, "api_url_address": "https://api.oplist.org/123cloud/renewapi", "UploadThread": 3},
		"Onedrive":     {"root_folder_path": "/", "region": "global", "use_online_api": true, "api_url_address": "https://api.oplist.org/onedrive/renewapi", "chunk_size": 5},
		"GoogleDrive":  {"root_folder_id": "root", "use_online_api": true, "api_url_address": "https://api.oplist.org/googleui/renewapi", "chunk_size": 5},
	}
	for key, value := range defaults[driverName] {
		if _, ok := values[key]; !ok {
			values[key] = value
		}
	}
	encoded, err := json.Marshal(values)
	return string(encoded), err
}

func (c *core) deleteAccount(id string) error {
	if !c.ready() {
		return fmt.Errorf("OpenList core is not initialized")
	}
	c.cancelTasks(id, false)
	c.waitTasks(id)
	storage, err := c.findAccount(id)
	if err != nil {
		return err
	}
	return op.DeleteStorageById(context.Background(), storage.ID)
}
func (c *core) storage(id string) (driver.Driver, error) {
	storage, err := c.findAccount(id)
	if err != nil {
		return nil, err
	}
	return op.GetStorageByMountPath(storage.MountPath)
}
func remotePath(value string) string {
	if value == "" {
		return "/"
	}
	return path.Clean("/" + strings.TrimPrefix(value, "/"))
}
func requestHeaders(values map[string]string) http.Header {
	result := make(http.Header, len(values))
	for key, value := range values {
		result.Set(key, value)
	}
	return result
}

func (c *core) fileOperation(method string, raw json.RawMessage) (any, error) {
	var args fileArguments
	if len(raw) == 0 {
		raw = []byte("{}")
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return nil, err
	}
	storage, err := c.storage(args.AccountID)
	if err != nil {
		return nil, err
	}
	if method == "upload" || method == "download" {
		return c.startTransfer(method, args, storage)
	}
	ctx, cancel := c.contextFor(args.TaskID, args.AccountID)
	defer func() {
		cancel()
		if args.TaskID != "" {
			c.finishTask(args.TaskID, "")
		}
	}()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	p := remotePath(args.Path)
	switch method {
	case "test":
		_, err := op.List(ctx, storage, "/", model.ListArgs{Refresh: true})
		return map[string]any{"connected": err == nil}, err
	case "list":
		entries, err := op.List(ctx, storage, p, model.ListArgs{Refresh: args.Refresh})
		if err != nil {
			return nil, err
		}
		result := make([]map[string]any, 0, len(entries))
		for _, entry := range entries {
			result = append(result, fileData(path.Join(p, entry.GetName()), entry))
		}
		return map[string]any{"entries": result}, nil
	case "stat":
		entry, err := op.Get(ctx, storage, p)
		if err != nil {
			return nil, err
		}
		return fileData(p, entry), nil
	case "link":
		op.InvalidateEmbeddedPath(storage, p)
		link, _, err := op.Link(ctx, storage, p, model.LinkArgs{Header: requestHeaders(args.Headers)})
		if err != nil {
			return nil, err
		}
		defer link.Close()
		return map[string]any{"url": link.URL, "headers": flatHeaders(link.Header)}, nil
	case "readText":
		data, err := readRemote(ctx, storage, p, requestHeaders(args.Headers))
		if err != nil {
			return nil, err
		}
		return map[string]any{"content": string(data)}, nil
	case "writeText":
		return nil, writeRemote(ctx, storage, p, []byte(args.Content), nil)
	case "mkdir":
		return nil, op.MakeDir(ctx, storage, p)
	case "delete":
		return nil, op.Remove(ctx, storage, p)
	default:
		return nil, fmt.Errorf("unknown method")
	}
}

func fileData(fullPath string, entry model.Obj) map[string]any {
	return map[string]any{"name": entry.GetName(), "path": remotePath(fullPath), "isDirectory": entry.IsDir(), "size": entry.GetSize(), "modifiedAt": entry.ModTime().UnixMilli(), "eTag": ""}
}
func flatHeaders(headers http.Header) map[string]string {
	result := make(map[string]string, len(headers))
	for key, values := range headers {
		result[key] = strings.Join(values, ",")
	}
	return result
}

func readRemote(ctx context.Context, storage driver.Driver, p string, headers http.Header) ([]byte, error) {
	op.InvalidateEmbeddedPath(storage, p)
	link, entry, err := op.Link(ctx, storage, p, model.LinkArgs{Header: headers})
	if err != nil {
		return nil, err
	}
	defer link.Close()
	reader, err := stream.GetRangeReaderFromLink(entry.GetSize(), link)
	if err != nil {
		return nil, err
	}
	body, err := reader.RangeRead(ctx, http_range.Range{Start: 0, Length: -1})
	if err != nil {
		return nil, err
	}
	defer body.Close()
	return io.ReadAll(body)
}

func writeRemote(ctx context.Context, storage driver.Driver, remote string, content []byte, progress func(float64)) error {
	file := &stream.FileStream{Ctx: ctx, Obj: &model.Object{Name: path.Base(remote), Size: int64(len(content)), Modified: time.Now()}, Reader: bytes.NewReader(content), Closers: utils.Closers{}}
	return op.Put(ctx, storage, path.Dir(remote), file, progress)
}

func (c *core) startTransfer(kind string, args fileArguments, storage driver.Driver) (any, error) {
	if args.TaskID == "" || args.LocalPath == "" {
		return nil, fmt.Errorf("taskId and localPath are required")
	}
	ctx, _ := c.contextFor(args.TaskID, args.AccountID)
	c.tasksMu.RLock()
	task := c.tasks[args.TaskID]
	c.tasksMu.RUnlock()
	p := remotePath(args.Path)
	c.active.Add(1)
	go func() {
		defer c.active.Done()
		defer func() {
			if recovered := recover(); recovered != nil {
				c.finishTask(args.TaskID, "OpenList transfer failed")
			}
		}()
		err := ctx.Err()
		if err == nil && kind == "upload" {
			err = uploadFile(ctx, storage, p, args.LocalPath, task)
		} else if err == nil {
			err = downloadFile(ctx, storage, p, args.LocalPath, requestHeaders(args.Headers), task)
		}
		task.mu.Lock()
		if err != nil {
			task.err = sensitiveValue.ReplaceAllString(err.Error(), "$1$2<redacted>")
			task.message = "failed"
		} else {
			task.message = "completed"
			if task.total > 0 {
				task.completed = task.total
			}
		}
		task.mu.Unlock()
		c.finishTask(args.TaskID, "")
	}()
	return map[string]any{"taskId": args.TaskID}, nil
}

func uploadFile(ctx context.Context, storage driver.Driver, remote, local string, task *taskState) error {
	file, err := os.Open(local)
	if err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return err
	}
	task.setProgress(0, info.Size())
	streamFile := &stream.FileStream{Ctx: ctx, Obj: &model.Object{Name: path.Base(remote), Size: info.Size(), Modified: info.ModTime()}, Reader: file, Closers: utils.Closers{file}}
	return op.Put(ctx, storage, path.Dir(remote), streamFile, func(percent float64) { task.setProgress(int64(percent*float64(info.Size())/100), info.Size()) })
}

func downloadFile(ctx context.Context, storage driver.Driver, remote, local string, headers http.Header, task *taskState) error {
	op.InvalidateEmbeddedPath(storage, remote)
	link, entry, err := op.Link(ctx, storage, remote, model.LinkArgs{Header: headers})
	if err != nil {
		return err
	}
	defer link.Close()
	reader, err := stream.GetRangeReaderFromLink(entry.GetSize(), link)
	if err != nil {
		return err
	}
	body, err := reader.RangeRead(ctx, http_range.Range{Start: 0, Length: -1})
	if err != nil {
		return err
	}
	defer body.Close()
	output, err := os.Create(local)
	if err != nil {
		return err
	}
	defer output.Close()
	task.setProgress(0, entry.GetSize())
	buffer := make([]byte, 128*1024)
	var copied int64
	for {
		count, readErr := body.Read(buffer)
		if count > 0 {
			written, writeErr := output.Write(buffer[:count])
			copied += int64(written)
			task.setProgress(copied, entry.GetSize())
			if writeErr != nil {
				return writeErr
			}
		}
		if readErr == io.EOF {
			return nil
		}
		if readErr != nil {
			return readErr
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
	}
}

func (task *taskState) setProgress(completed, total int64) {
	task.mu.Lock()
	task.completed, task.total = completed, total
	task.mu.Unlock()
}

func (c *core) contextFor(taskID, accountID string) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	if taskID == "" {
		return ctx, cancel
	}
	c.tasksMu.Lock()
	defer c.tasksMu.Unlock()
	if c.tasks == nil {
		c.tasks = map[string]*taskState{}
	}
	if old := c.tasks[taskID]; old != nil {
		old.cancel()
	}
	c.tasks[taskID] = &taskState{cancel: cancel, accountID: accountID, message: "running", doneSignal: make(chan struct{})}
	if _, cancelled := c.pendingCancels[taskID]; cancelled {
		delete(c.pendingCancels, taskID)
		cancel()
	}
	return ctx, cancel
}

func (c *core) taskOperation(method, taskID, accountID string) (any, error) {
	if method == "cancelAll" {
		c.cancelTasks("", true)
		return nil, nil
	}
	if method == "cancelAccount" {
		c.cancelTasks(accountID, false)
		return nil, nil
	}
	switch method {
	case "cancel":
		if taskID == "" {
			return nil, fmt.Errorf("taskId is required")
		}
		c.tasksMu.Lock()
		task := c.tasks[taskID]
		if task == nil {
			if c.pendingCancels == nil {
				c.pendingCancels = map[string]struct{}{}
			}
			c.pendingCancels[taskID] = struct{}{}
			c.tasksMu.Unlock()
			return nil, nil
		}
		c.tasksMu.Unlock()
		task.cancel()
		return nil, nil
	case "releaseTask":
		c.tasksMu.Lock()
		task := c.tasks[taskID]
		if task == nil {
			delete(c.pendingCancels, taskID)
			c.tasksMu.Unlock()
			return nil, nil
		}
		c.tasksMu.Unlock()
		task.mu.RLock()
		done := task.done
		task.mu.RUnlock()
		if !done {
			return nil, fmt.Errorf("task is still running")
		}
		c.tasksMu.Lock()
		delete(c.tasks, taskID)
		c.tasksMu.Unlock()
		return nil, nil
	case "taskStatus":
		c.tasksMu.RLock()
		task := c.tasks[taskID]
		c.tasksMu.RUnlock()
		if task == nil {
			return nil, fmt.Errorf("task not found")
		}
		task.mu.RLock()
		result := map[string]any{"done": task.done, "completed": task.completed, "total": task.total, "message": task.message}
		if task.err != "" {
			result["error"] = map[string]string{"code": "operation_failed", "message": task.err}
		}
		task.mu.RUnlock()
		return result, nil
	}
	return nil, fmt.Errorf("unknown task operation")
}

func (c *core) cancelTasks(accountID string, all bool) {
	c.tasksMu.RLock()
	defer c.tasksMu.RUnlock()
	for _, task := range c.tasks {
		if all || task.accountID == accountID {
			task.cancel()
		}
	}
}

func (c *core) finishTask(taskID, message string) {
	c.tasksMu.RLock()
	task := c.tasks[taskID]
	c.tasksMu.RUnlock()
	if task == nil {
		return
	}
	task.mu.Lock()
	if message != "" {
		task.err, task.message = message, "failed"
	}
	if !task.done {
		task.done = true
		close(task.doneSignal)
	}
	task.mu.Unlock()
}

func (c *core) waitTasks(accountID string) {
	c.tasksMu.RLock()
	var signals []<-chan struct{}
	for _, task := range c.tasks {
		if task.accountID == accountID {
			signals = append(signals, task.doneSignal)
		}
	}
	c.tasksMu.RUnlock()
	for _, signal := range signals {
		<-signal
	}
}
