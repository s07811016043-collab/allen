// 搜索与文案生成效果度量台 —— 桌面启动器
// 双击运行：在本机 127.0.0.1 启动内置 Web 服务并自动打开默认浏览器。
// 所有网页资源编译内嵌于本可执行文件，无任何外部依赖与网络请求。
package main

import (
	"embed"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"syscall"
	"time"
)

//go:embed all:web
var webFS embed.FS

// 依次尝试的首选端口；全被占用时退回随机端口
var preferredPorts = []int{8471, 8472, 8473, 0}

func openBrowser(url string) error {
	switch runtime.GOOS {
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		return exec.Command("open", url).Start()
	default:
		return exec.Command("xdg-open", url).Start()
	}
}

func listen() (net.Listener, error) {
	var lastErr error
	for _, p := range preferredPorts {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
		if err == nil {
			return ln, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

func main() {
	site, err := fs.Sub(webFS, "web")
	if err != nil {
		fmt.Println("内嵌资源加载失败:", err)
		os.Exit(1)
	}

	ln, err := listen()
	if err != nil {
		fmt.Println("无法监听本机端口:", err)
		fmt.Println("按回车退出…")
		fmt.Scanln()
		os.Exit(1)
	}
	url := fmt.Sprintf("http://%s/", ln.Addr().String())

	mux := http.NewServeMux()
	fileServer := http.FileServer(http.FS(site))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// 仅允许本机访问（防止局域网内他人访问评测数据）
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if host != "127.0.0.1" && host != "::1" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		fileServer.ServeHTTP(w, r)
	})

	fmt.Println("┌──────────────────────────────────────────────┐")
	fmt.Println("│   搜索与文案生成效果度量台 · 本地服务已启动    │")
	fmt.Println("└──────────────────────────────────────────────┘")
	fmt.Println("  地址:", url)
	fmt.Println("  · 浏览器将自动打开；若未打开请手动访问上述地址")
	fmt.Println("  · 数据仅在本机处理，服务只监听 127.0.0.1")
	fmt.Println("  · 关闭本窗口（或按 Ctrl+C）即停止服务")

	go func() {
		time.Sleep(400 * time.Millisecond)
		if err := openBrowser(url); err != nil {
			fmt.Println("  ! 自动打开浏览器失败，请手动访问:", url)
		}
	}()

	// Ctrl+C / 关闭窗口时干净退出
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		fmt.Println("\n服务已停止，再见。")
		os.Exit(0)
	}()

	if err := http.Serve(ln, mux); err != nil {
		fmt.Println("服务异常退出:", err)
		os.Exit(1)
	}
}
